/**
 * Main window: AdwNavigationSplitView sidebar/content layout (spec §6).
 *
 *  Header: app title + profile dropdown label + running status.
 *  Sidebar: ProfileView.
 *  Content: DeviceView (input/gains/virtual mic) + PluginView (chain).
 *
 * Owns the Engine. Pumps engine commands + polls meters from a ~25 Hz
 * glib timeout (GTK thread only — never from RT).
 */
module ui.window;

import adw.application;
import adw.application_window;
import adw.header_bar;
import adw.navigation_page;
import adw.navigation_split_view;
import adw.toolbar_view;
import gdk.types : ModifierType;
import gtk.box;
import gtk.css_provider : CssProvider;
import gtk.event_controller_key;
import gtk.scrolled_window;
import gtk.label;
import gtk.types : Orientation;
import gtk.types : PolicyType;
import gtk.widget : Widget;
import gtk.window : Window;

import audio.engine : Engine;
import audio.pipewire : AudioDevice;
import audio.profile : Profile, listProfiles, saveProfile;
import config.config : AppConfig, loadConfig, saveConfig;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import omarchy.integration : ThemeWatcher;
import omarchy.theme : StyleMode, styleModeFromName, styleModeName, loadPalette, generateCss;
import ui.device_view : DeviceView;
import ui.plugin_view : PluginView;
import ui.profile_view : ProfileView;
import ui.shortcuts : VimAction, KeyPress, mapKey;

class MainWindow : ApplicationWindow
{
private:
    Engine _engine;
    AppConfig _cfg;
    ProfileView _profiles;
    DeviceView _devices;
    PluginView _chain;
    Label _statusLabel;
    Label _profileLabel;
    Profile[] _allProfiles;
    string _activeId;
    ThemeWatcher _themeWatcher;
    EventControllerKey _keys;
    // Debounced profile persistence for slider drags etc.
    bool _profileDirty;
    uint _ticks;
    // Keyboard focus model: which list j/k operate on.
    int _paneIndex;
    // Open modal-ish dialog (Add Plugin), if any.
    Window _dialog;
    // Single CssProvider for layout + optional Omarchy palette CSS.
    CssProvider _cssProvider;

public:
    this(Application app, Engine engine)
    {
        super(app);
        _engine = engine;
        _cfg = loadConfig();

        setTitle("Omarchy Voice Studio");
        setDefaultSize(960, 640);

        // Header bar. NOTE: AdwApplicationWindow does not support
        // gtk_window_set_titlebar(); the header goes into a ToolbarView.
        auto header = new HeaderBar();
        _profileLabel = new Label("Profile: —");
        header.setTitleWidget(_profileLabel);
        _statusLabel = new Label("○ Stopped");
        header.packEnd(_statusLabel);

        // Split view. Both panes scroll: small windows must always reach
        // every control (chain grows with per-plugin widgets).
        auto split = new NavigationSplitView();

        auto sideBox = new Box(Orientation.Vertical, 0);
        _profiles = new ProfileView(
            (id) => selectProfile(id),
            () => createProfile(),
            (id) => deleteProfile(id),
        );
        sideBox.append(_profiles);
        auto sideScroll = new ScrolledWindow();
        sideScroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sideScroll.setChild(sideBox);
        auto sidePage = new NavigationPage(sideScroll, "Profiles");
        split.setSidebar(sidePage);

        auto contentBox = new Box(Orientation.Vertical, 12);
        contentBox.setMarginTop(12);
        contentBox.setMarginBottom(12);
        contentBox.setMarginStart(12);
        contentBox.setMarginEnd(12);

        _devices = new DeviceView(
            (node) => selectInput(node),
            (db) => _engine.setInputGain(db),
            (db) => _engine.setOutputGain(db),
            (on) => toggleDenoise(on),
        );
        contentBox.append(_devices);

        _chain = new PluginView(
            (idx) => toggleSlot(idx),
            (from, to) => moveSlot(from, to),
            (idx) => removeSlot(idx),
            () => openAddPluginDialog(),
            (slot, ctrl, val) => onPluginControl(slot, ctrl, val),
        );
        contentBox.append(_chain);

        auto contentScroll = new ScrolledWindow();
        contentScroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
        contentScroll.setChild(contentBox);
        auto contentPage = new NavigationPage(contentScroll, "Current Profile");
        split.setContent(contentPage);

        auto toolbar = new ToolbarView();
        toolbar.addTopBar(header);
        toolbar.setContent(split);
        setContent(toolbar);

        // Vim-style keys (never hijack text editing).
        _keys = new EventControllerKey();
        _keys.connectKeyPressed((uint keyval, uint keycode, ModifierType state) {
            Widget focus = getFocus();
            bool inEditable = isEditableFocus(focus);
            auto act = mapKey(KeyPress(keyval, cast(uint) state), inEditable);
            return handleAction(act);
        });
        addController(_keys);

        refreshProfiles();
        refreshDevices();

        _cssProvider = new CssProvider();
        applyStyleMode();
        // Live Omarchy reload only matters in omarchy mode; the watcher
        // stays cheap otherwise.
        _themeWatcher = new ThemeWatcher(null, (css) {
            if (styleModeFromName(_cfg.styleMode) == StyleMode.omarchy)
                reloadOmarchyCss();
        });

        // ~25 Hz UI tick: pump engine + meters + theme watch.
        timeoutAdd(PRIORITY_DEFAULT, 40, () {
            tick();
            return true; // keep source
        });
    }

    void onShown()
    {
        present();
        // Start backend after window shows so failures surface in status.
        if (_cfg.autoStartBackend && !_engine.running)
        {
            if (!_engine.startBackend())
                _devices.setRunning(false, _engine.lastError);
            else
                _devices.setRunning(true, "");
            updateStatus();
        }
    }

private:
    void tick()
    {
        try
        {
            _ticks++;
            _engine.pumpCommands();
            _engine.pollBackend();
            auto m = _engine.meterSnapshot();
            _devices.setMeters(m.inputPeak, m.inputClip, m.outputPeak, m.outputClip);
            updateStatus();
            _themeWatcher.poll();
            // Debounced autosave (dragging a slider must not fsync per motion).
            if (_profileDirty && _ticks % 200 == 0)
                flushProfile();
            // Periodic device rescan for hotplug (cheap snapshot, suspended
            // rebuild keeps selection stable).
            if (_ticks % 200 == 100)
            {
                try
                    refreshDevices();
                catch (Exception)
                {
                }
            }
        }
        catch (Exception)
        {
        }
    }

    void flushProfile()
    {
        if (!_profileDirty || !_engine.hasProfile)
            return;
        try
        {
            saveProfile(_engine.currentProfile());
            _profileDirty = false;
        }
        catch (Exception e)
        {
            _statusLabel.setText("Save failed: " ~ e.msg);
        }
    }

    void updateStatus()
    {
        if (_engine.running)
            _statusLabel.setText("● Running");
        else
            _statusLabel.setText("○ Stopped");
    }

    void refreshProfiles()
    {
        _allProfiles = listProfiles();
        if (_allProfiles.length == 0)
            seedFactoryProfiles();
        if (_activeId.length == 0)
            _activeId = _cfg.activeProfileId.length ? _cfg.activeProfileId : "broadcast";
        _profiles.setProfiles(_allProfiles, _activeId);
        // Activate current if engine has none yet.
        if (!_engine.hasProfile)
            foreach (ref p; _allProfiles)
                if (p.id == _activeId)
                {
                    _engine.applyProfile(p);
                    _chain.setSlots(chainDisplay());
                    break;
                }
        updateProfileLabel();
        refreshDenoiseUi();
        refreshGainsUi();
    }

    /// First-run factory presets (only when no profiles exist at all;
    /// never overwrites user profiles). See docs/usage.md for the rationale.
    void seedFactoryProfiles()
    {
        import audio.profile : PluginEntry;

        PluginEntry entry(string uri, double[string] controls)
        {
            PluginEntry e;
            e.uri = uri;
            e.enabled = true;
            e.controls = controls;
            return e;
        }

        enum string FIL4M = "http://gareus.org/oss/lv2/fil4#mono";
        enum string DPLM = "http://gareus.org/oss/lv2/dpl#mono";
        enum string ZGATE = "urn:zamaudio:ZamGate";
        enum string ZCOMP = "urn:zamaudio:ZamComp";

        // Clean pass-through starting point.
        Profile broadcast;
        broadcast.id = "broadcast";
        broadcast.name = "Broadcast";
        broadcast.channelMode = "mono";

        // Spoken word: HPF + low-mud cut + gentle presence, light
        // compression, peak protection. Mono, denoise on.
        Profile podcast;
        podcast.id = "podcast";
        podcast.name = "Podcast";
        podcast.channelMode = "mono";
        podcast.denoise = true;
        podcast.plugins = [
            entry(FIL4M, [
                "HighPass": 1.0, "HPfreq": 80.0,
                "LSgain": -2.5,
                "freq1": 250.0, "gain1": -3.0,
                "freq3": 3000.0, "gain3": 2.0,
            ]),
            entry(ZCOMP, [
                "att": 10.0, "rel": 120.0, "rat": 3.0,
                "thr": -18.0, "mak": 3.0,
            ]),
            entry(DPLM, ["threshold": -1.0, "release": 0.1]),
        ];

        // Gaming/Discord: fast gate against keyboard clacks, light EQ for
        // intelligibility, limiter so shouts never clip. Mono, denoise on.
        Profile discord;
        discord.id = "discord";
        discord.name = "Discord Gaming";
        discord.channelMode = "mono";
        discord.denoise = true;
        discord.plugins = [
            entry(ZGATE, [
                "att": 5.0, "rel": 150.0, "thr": -40.0,
                "close": -50.0, "mode": 0.0,
            ]),
            entry(FIL4M, [
                "HighPass": 1.0, "HPfreq": 90.0,
                "freq3": 3200.0, "gain3": 1.5,
            ]),
            entry(DPLM, ["threshold": -1.5, "release": 0.08]),
        ];

        foreach (ref p; [broadcast, podcast, discord])
        {
            try
            {
                saveProfile(p);
            }
            catch (Exception)
            {
            }
        }
        _allProfiles = listProfiles();
    }

    /// Display model for the chain view (names, validity, notes, controls).
    /// Empty when no profile is active — the view clears itself.
    Engine.SlotDisplay[] chainDisplay()
    {
        if (!_engine.hasProfile)
            return null;
        try
        {
            return _engine.slotDisplay();
        }
        catch (Exception)
        {
            return null;
        }
    }

    void updateProfileLabel()
    {
        string name = _activeId;
        foreach (ref p; _allProfiles)
            if (p.id == _activeId)
            {
                name = p.name;
                break;
            }
        _profileLabel.setText("Profile: " ~ name);
    }

    void selectProfile(string id)
    {
        // Idempotent: programmatic re-selection of the active profile
        // (e.g. ListBox selectRow() re-emitting row-selected) must be a
        // no-op, never a rebuild cycle.
        if (id == _activeId && _engine.hasProfile && _engine.currentProfile.id == id)
            return;
        foreach (ref p; _allProfiles)
            if (p.id == id)
            {
                if (_engine.applyProfile(p))
                {
                    _activeId = id;
                    _cfg.activeProfileId = id;
                    try
                    {
                        saveConfig(_cfg);
                    }
                    catch (Exception)
                    {
                    }
                    // Backend reconcile (channels/target) happens inside
                    // applyProfile; surface any backend error it recorded.
                    if (!_engine.running && _engine.lastError.length > 0)
                        _statusLabel.setText(_engine.lastError);
                    _profiles.setProfiles(_allProfiles, _activeId);
                    _chain.setSlots(chainDisplay());
                    _devices.setRunning(_engine.running, _engine.lastError);
                    updateProfileLabel();
                    refreshDenoiseUi();
                    refreshGainsUi();
                }
                else
                {
                    _statusLabel.setText("Profile failed: " ~ _engine.lastError);
                }
                return;
            }
    }

    void createProfile()
    {
        Profile p;
        p.name = "New Profile";
        p.id = uniqueProfileId(p.name);
        p.channelMode = "mono";
        try
        {
            saveProfile(p);
        }
        catch (Exception e)
        {
            _statusLabel.setText("Cannot create: " ~ e.msg);
            return;
        }
        refreshProfiles();
        selectProfile(p.id);
    }

    void deleteProfile(string id)
    {
        import std.file : remove, exists;
        import std.path : buildPath;
        import audio.profile : profilesDir;

        if (_allProfiles.length <= 1)
        {
            _statusLabel.setText("Cannot delete the last profile");
            return;
        }
        try
        {
            string f = buildPath(profilesDir(), id ~ ".json");
            if (exists(f))
                remove(f);
        }
        catch (Exception e)
        {
            _statusLabel.setText("Cannot delete: " ~ e.msg);
            return;
        }
        if (_activeId == id)
        {
            _activeId = "";
            // Point the saved active profile at a surviving one so the
            // next refresh doesn't resurrect the deleted id.
            _cfg.activeProfileId = "";
            foreach (ref p; _allProfiles)
                if (p.id != id)
                {
                    _cfg.activeProfileId = p.id;
                    break;
                }
            try
            {
                saveConfig(_cfg);
            }
            catch (Exception)
            {
            }
        }
        refreshProfiles();
    }

    void refreshDevices()
    {
        AudioDevice[] devs = _engine.sources();
        string active = _engine.hasProfile ? _engine.currentProfile().input.nodeName : "";
        _devices.setDevices(devs, active);
    }

    void selectInput(string nodeName)
    {
        if (!_engine.hasProfile)
            return;
        // Enrich node name with serial/display name (persisted, spec §8.4;
        // numeric node IDs are never persisted).
        import audio.profile : DeviceRef;

        DeviceRef dev;
        dev.nodeName = nodeName;
        foreach (ref d; _engine.sources())
            if (d.nodeName == nodeName)
            {
                dev.displayName = d.displayName;
                dev.serial = d.serial;
                break;
            }
        if (!_engine.switchInput(dev))
            _statusLabel.setText("Input switch failed: " ~ _engine.lastError);
        else
        {
            try
            {
                saveProfile(_engine.currentProfile());
            }
            catch (Exception)
            {
            }
            refreshDevices();
            _devices.setRunning(_engine.running, _engine.lastError);
            updateStatus();
        }
    }
    void toggleDenoise(bool on)
    {
        if (!_engine.setDenoise(on))
        {
            _statusLabel.setText("Noise suppression unavailable");
            refreshDenoiseUi();
            return;
        }
        try
        {
            saveProfile(_engine.currentProfile());
        }
        catch (Exception e)
        {
            _statusLabel.setText("Save failed: " ~ e.msg);
        }
        refreshDenoiseUi();
    }

    void refreshGainsUi()
    {
        if (!_engine.hasProfile)
            return;
        auto cur = _engine.currentProfile();
        _devices.setGains(cur.inputGainDb, cur.outputGainDb);
    }

    void refreshDenoiseUi()
    {
        if (!_engine.hasProfile)
        {
            _devices.setDenoise(false, "");
            return;
        }
        _devices.setDenoise(_engine.currentProfile().denoise, _engine.denoiseInfo());
    }

    void toggleSlot(uint idx)
    {
        _engine.persistSlotEnabled(idx, !_slotEnabled(idx));
        _profileDirty = true;
        _chain.setSlots(chainDisplay());
    }

    bool _slotEnabled(uint idx)
    {
        if (!_engine.hasProfile)
            return false;
        auto cur = _engine.currentProfile();
        if (idx < cur.plugins.length)
            return cur.plugins[idx].enabled;
        return false;
    }

    void moveSlot(int from, int to)
    {
        if (!_engine.hasProfile)
            return;
        auto cur = _engine.currentProfile();
        if (from < 0 || to < 0 || from >= cast(int) cur.plugins.length || to >= cast(int) cur.plugins.length)
            return;
        auto tmp = cur.plugins[from];
        cur.plugins[from] = cur.plugins[to];
        cur.plugins[to] = tmp;
        if (_engine.applyProfile(cur))
        {
            try
            {
                saveProfile(cur);
            }
            catch (Exception)
            {
            }
            _chain.setSlots(chainDisplay());
        }
    }

    void removeSlot(uint idx)
    {
        if (!_engine.hasProfile)
            return;
        auto cur = _engine.currentProfile();
        if (idx >= cur.plugins.length)
            return;
        cur.plugins = cur.plugins[0 .. idx] ~ cur.plugins[idx + 1 .. $];
        if (_engine.applyProfile(cur))
        {
            try
            {
                saveProfile(cur);
            }
            catch (Exception)
            {
            }
            _chain.setSlots(chainDisplay());
        }
    }

    void openAddPluginDialog()
    {
        if (!_engine.hasProfile)
            return;
        import ui.add_plugin_dialog : AddPluginDialog;

        auto dlg = new AddPluginDialog(this, (uri) => addPluginByUri(uri));
        trackDialog(dlg);
        dlg.present();
    }

    void openHelpDialog()
    {
        import ui.help_dialog : HelpDialog;

        auto dlg = new HelpDialog(this);
        trackDialog(dlg);
        dlg.present();
    }

    void openSettingsDialog()
    {
        import omarchy.theme : styleModeFromName;
        import ui.settings_dialog : SettingsDialog;

        StyleMode cur;
        try
        {
            cur = styleModeFromName(_cfg.styleMode);
        }
        catch (Exception)
        {
            cur = StyleMode.system;
        }
        import std.format : format;

        string status = format("Backend: %s%s", _engine.running ? "running" : "stopped",
            _engine.running ? format("  (node %d)", _engine.backendNodeId) : "");
        auto dlg = new SettingsDialog(this, cur, _cfg.autoStartBackend, status,
            (mode) {
                _cfg.styleMode = styleModeName(mode);
                try
                {
                    saveConfig(_cfg);
                }
                catch (Exception)
                {
                }
                applyStyleMode();
            },
            (on) {
                _cfg.autoStartBackend = on;
                try
                {
                    saveConfig(_cfg);
                }
                catch (Exception)
                {
                }
            });
        trackDialog(dlg);
        dlg.present();
    }

    void openSaveAsDialog()
    {
        if (!_engine.hasProfile)
            return;
        import ui.save_as_dialog : SaveAsDialog;

        auto dlg = new SaveAsDialog(this, _engine.currentProfile().name ~ " copy",
            (name) => saveProfileAs(name));
        trackDialog(dlg);
        dlg.present();
    }

    /// Duplicate the current profile under a new name (spec Ctrl+Shift+S).
    void saveProfileAs(string name)
    {
        if (!_engine.hasProfile)
            return;
        auto cur = _engine.currentProfile();
        cur.name = name;
        cur.id = uniqueProfileId(name);
        try
        {
            saveProfile(cur);
        }
        catch (Exception e)
        {
            _statusLabel.setText("Save failed: " ~ e.msg);
            return;
        }
        _activeId = cur.id;
        _cfg.activeProfileId = cur.id;
        try
        {
            saveConfig(_cfg);
        }
        catch (Exception)
        {
        }
        refreshProfiles();
        _statusLabel.setText("Saved as " ~ name);
    }

    string uniqueProfileId(string name)
    {
        import std.array : array;
        import std.conv : to;
        import std.uni : toLower;
        import std.string : strip;

        string slug;
        foreach (dchar c; name.strip().toLower())
        {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
                slug ~= c;
            else if (slug.length > 0 && slug[$ - 1] != '-')
                slug ~= '-';
        }
        while (slug.length > 0 && slug[$ - 1] == '-')
            slug = slug[0 .. $ - 1];
        if (slug.length == 0)
            slug = "profile";
        string id = slug;
        uint n = 2;
        bool taken()
        {
            foreach (ref p; _allProfiles)
                if (p.id == id)
                    return true;
            return false;
        }
        while (taken())
            id = slug ~ "-" ~ (n++).to!string;
        return id;
    }

    void trackDialog(Window dlg)
    {
        _dialog = dlg;
        dlg.connectCloseRequest(() {
            if (_dialog is dlg)
                _dialog = null;
            return false; // let the close proceed
        });
    }

    void addPluginByUri(string uri)
    {
        import audio.lv2 : Lv2PluginInfo;

        auto cur = _engine.currentProfile();
        foreach (ref e; cur.plugins)
            if (e.uri == uri)
            {
                _statusLabel.setText("Plugin already in chain");
                return;
            }
        // Validate support before mutating (explicit error, no silence).
        try
        {
            auto info = _engine.inspectPlugin(uri);
            if (!info.supportedForMvp())
            {
                _statusLabel.setText("Unsupported plugin: " ~ info.name);
                return;
            }
        }
        catch (Exception e)
        {
            _statusLabel.setText("Cannot add plugin: " ~ e.msg);
            return;
        }
        import audio.profile : PluginEntry;

        PluginEntry e;
        e.uri = uri;
        e.enabled = true;
        cur.plugins ~= e;
        if (_engine.applyProfile(cur))
        {
            try
            {
                saveProfile(cur);
            }
            catch (Exception ex)
            {
                _statusLabel.setText("Save failed: " ~ ex.msg);
            }
            _chain.setSlots(chainDisplay());
            _statusLabel.setText("Plugin added");
        }
        else
            _statusLabel.setText("Add failed: " ~ _engine.lastError);
    }

    /// Plugin information for the selected slot (spec: open plugin info).
    void showPluginInfo()
    {
        int s = _chain.selectedSlot();
        if (s < 0 || !_engine.hasProfile)
        {
            _statusLabel.setText("No plugin selected");
            return;
        }
        try
        {
            auto disp = _engine.slotDisplay();
            if (s >= cast(int) disp.length)
                return;
            auto d = disp[s];
            string vendor;
            try
                vendor = _engine.inspectPlugin(d.uri).vendor;
            catch (Exception)
            {
            }
            import std.format : format;

            _statusLabel.setText(format("%s%s — %s (%d controls)%s", d.name,
                vendor.length ? " by " ~ vendor : "", d.uri,
                cast(int) d.controls.length,
                d.note.length ? " " ~ d.note : ""));
        }
        catch (Exception e)
        {
            _statusLabel.setText("Info unavailable: " ~ e.msg);
        }
    }

    void onPluginControl(uint slot, uint control, float value)    {
        string symbol;
        try
        {
            auto disp = _engine.slotDisplay();
            if (slot < disp.length && control < disp[slot].controls.length)
                symbol = disp[slot].controls[control].symbol;
        }
        catch (Exception)
        {
        }
        _engine.setControlPersist(slot, control, symbol, value);
        _profileDirty = true;
    }

    /// Apply the configured style mode (`t` cycles, persisted).
    /// system: desktop Adwaita untouched (layout CSS only).
    /// omarchy: live Omarchy palette overlay. dark/light: forced scheme.
    void applyStyleMode()
    {
        import adw.style_manager : StyleManager;
        import adw.types : ColorScheme;
        import gdk.display : Display;
        import gtk.style_context : StyleContext;
        import omarchy.theme : StyleMode, styleModeFromName, loadPalette,
            generateCss, layoutCss;

        StyleMode mode;
        try
        {
            mode = styleModeFromName(_cfg.styleMode);
        }
        catch (Exception)
        {
            mode = StyleMode.system;
        }
        try
        {
            auto sm = StyleManager.getDefault();
            final switch (mode)
            {
            case StyleMode.system:
                sm.setColorScheme(ColorScheme.Default);
                break;
            case StyleMode.omarchy:
            {
                auto pal = loadPalette();
                sm.setColorScheme(pal.mode == "light" ? ColorScheme.ForceLight : ColorScheme.ForceDark);
                break;
            }
            case StyleMode.dark:
                sm.setColorScheme(ColorScheme.ForceDark);
                break;
            case StyleMode.light:
                sm.setColorScheme(ColorScheme.ForceLight);
                break;
            }
        }
        catch (Exception)
        {
        }
        reloadCss(mode);
    }

    void reloadOmarchyCss()
    {
        import omarchy.theme : StyleMode, styleModeFromName;

        try
        {
            reloadCss(styleModeFromName(_cfg.styleMode));
        }
        catch (Exception)
        {
        }
    }

    void reloadCss(StyleMode mode)
    {
        import gtk.style_context : StyleContext;
        import gdk.display : Display;
        import omarchy.theme : StyleMode, loadPalette, generateCss, layoutCss;

        try
        {
            string css = layoutCss();
            if (mode == StyleMode.omarchy)
            {
                auto pal = loadPalette();
                if (pal.available)
                    css ~= generateCss(pal);
            }
            _cssProvider.loadFromString(css);
            auto display = Display.getDefault();
            if (display !is null)
                StyleContext.addProviderForDisplay(display, _cssProvider, 800);
        }
        catch (Exception)
        {
        }
    }

    void cycleStyle()
    {
        import omarchy.theme : StyleMode, styleModeFromName, styleModeName;

        StyleMode cur;
        try
        {
            cur = styleModeFromName(_cfg.styleMode);
        }
        catch (Exception)
        {
            cur = StyleMode.system;
        }
        StyleMode next = cur == StyleMode.system ? StyleMode.omarchy
            : cur == StyleMode.omarchy ? StyleMode.dark
            : cur == StyleMode.dark ? StyleMode.light : StyleMode.system;
        _cfg.styleMode = styleModeName(next);
        try
        {
            saveConfig(_cfg);
        }
        catch (Exception)
        {
        }
        applyStyleMode();
        _statusLabel.setText("Style: " ~ _cfg.styleMode);
    }

    bool handleAction(VimAction act)
    {
        final switch (act)
        {
        case VimAction.none:
            return false;
        case VimAction.nextItem:
            activeListMove(1);
            return true;
        case VimAction.prevItem:
            activeListMove(-1);
            return true;
        case VimAction.prevPane:
            cyclePane(-1);
            return true;
        case VimAction.nextPane:
            cyclePane(1);
            return true;
        case VimAction.activate:
        case VimAction.toggle:
            activateSelected(act == VimAction.toggle);
            return true;
        case VimAction.close:
            // Esc/q closes the Add dialog when open; never quits the app.
            if (_dialog !is null)
            {
                _dialog.close();
                return true;
            }
            return false;
        case VimAction.search:
            // `/` jumps to plugin search (opens the Add dialog).
            openAddPluginDialog();
            return true;
        case VimAction.help:
            openHelpDialog();
            return true;
        case VimAction.save:
            saveCurrentProfile();
            return true;
        case VimAction.saveAs:
            openSaveAsDialog();
            return true;
        case VimAction.settings:
            openSettingsDialog();
            return true;
        case VimAction.newProfile:
            createProfile();
            return true;
        case VimAction.deleteProfile:
        {
            string id = _profiles.selectedId();
            if (id.length == 0)
                id = _activeId;
            if (id.length > 0)
                deleteProfile(id);
            return true;
        }
        case VimAction.addPlugin:
            openAddPluginDialog();
            return true;
        case VimAction.removePlugin:
        {
            int s = _chain.selectedSlot();
            if (s >= 0)
                removeSlot(cast(uint) s);
            return true;
        }
        case VimAction.moveDown:
        {
            int s = _chain.selectedSlot();
            if (s >= 0)
                moveSlot(s, s + 1);
            return true;
        }
        case VimAction.moveUp:
        {
            int s = _chain.selectedSlot();
            if (s >= 0)
                moveSlot(s, s - 1);
            return true;
        }
        case VimAction.bypass:
        {
            int s = _chain.selectedSlot();
            if (s >= 0)
                toggleSlot(cast(uint) s);
            return true;
        }
        case VimAction.pluginInfo:
            showPluginInfo();
            return true;
        case VimAction.resetControl:
        {
            int s = _chain.selectedSlot();
            if (s >= 0 && _engine.resetSlotControls(cast(uint) s))
            {
                _profileDirty = true;
                _chain.setSlots(chainDisplay());
                _statusLabel.setText("Controls reset to defaults");
            }
            return true;
        }
        case VimAction.cycleStyle:
            cycleStyle();
            return true;
        }
    }

    // -- keyboard focus model ------------------------------------------------
    // Three navigable lists: profiles -> inputs -> chain. h/l... note `h`
    // opens help; Left/Right arrows (and l) move between panes, j/k move
    // within the focused (or last-focused) list.

    int focusedPane()
    {
        Widget f = getFocus();
        if (f is null)
            return _paneIndex;
        if (f.isAncestor(_profiles) || f == _profiles)
            return 0;
        if (f.isAncestor(_devices) || f == _devices)
            return 1;
        if (f.isAncestor(_chain) || f == _chain)
            return 2;
        return _paneIndex;
    }

    void cyclePane(int delta)
    {
        _paneIndex = focusedPane() + delta;
        _paneIndex = (_paneIndex % 3 + 3) % 3;
        final switch (_paneIndex)
        {
        case 0:
            _profiles.focusList();
            break;
        case 1:
            _devices.focusList();
            break;
        case 2:
            _chain.focusList();
            break;
        }
    }

    void activeListMove(int delta)
    {
        _paneIndex = focusedPane();
        final switch (_paneIndex)
        {
        case 0:
            _profiles.moveSelection(delta);
            break;
        case 1:
            _devices.moveSelection(delta);
            break;
        case 2:
            _chain.moveSelection(delta);
            break;
        }
    }

    void activateSelected(bool isToggle)
    {
        _paneIndex = focusedPane();
        final switch (_paneIndex)
        {
        case 0:
        {
            string id = _profiles.selectedId();
            if (id.length > 0)
                selectProfile(id);
            break;
        }
        case 1:
        {
            string node = _devices.selectedInput();
            if (node !is null)
                selectInput(node);
            break;
        }
        case 2:
        {
            int s = _chain.selectedSlot();
            if (s >= 0)
                toggleSlot(cast(uint) s);
            break;
        }
        }
    }

    void saveCurrentProfile()
    {
        if (!_engine.hasProfile)
            return;
        try
        {
            saveProfile(_engine.currentProfile());
            _profileDirty = false;
            _statusLabel.setText("Profile saved");
        }
        catch (Exception e)
        {
            _statusLabel.setText("Save failed: " ~ e.msg);
        }
    }

    static bool isEditableFocus(Widget w)
    {
        if (w is null)
            return false;
        import gtk.entry : Entry;
        import gtk.search_entry : SearchEntry;
        import gtk.text_view : TextView;
        import gtk.spin_button : SpinButton;

        if (cast(Entry) w !is null)
            return true;
        if (cast(SearchEntry) w !is null)
            return true;
        if (cast(TextView) w !is null)
            return true;
        if (cast(SpinButton) w !is null)
            return true;
        return false;
    }
}
