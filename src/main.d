/**
 * Entry point — Omarchy Voice Studio.
 *
 * Modes:
 *   dub run                 -> full GTK4/Adwaita UI
 *   dub run -- --headless [--profile ID]  -> engine only (systemd service)
 *   dub run -- --list-lv2   -> print discovered LV2 plugins, exit
 *   dub run -- --list-sources -> print PipeWire capture devices, exit
 *   dub run -- --check-plugin URI -> inspect + instantiate one plugin, exit
 *   dub run -- --dump-chain ID -> apply profile, print chain display model
 *
 * Headless mode still honors graceful degradation: no PipeWire / no LV2 /
 * no Omarchy never crashes the process; errors go to stderr with a
 * non-zero exit only when the requested profile itself is invalid.
 *
 * Bundled LV2 plugins in <exe-dir>/lv2 (and $PWD/lv2 for `dub run`) are
 * prepended to LV2_PATH so the app works with its vendored suite without
 * system installation.
 */
module main;

import config.config : APP_ID, AppConfig, loadConfig, saveConfig;

int main(string[] args)
{
    setupLocalLv2();

    string profileOverride;
    string checkUri;
    string dumpChain;
    bool headless;
    bool listLv2;
    bool listSources;
    foreach (a; args[1 .. $])
    {
        if (a == "--headless")
            headless = true;
        else if (a == "--list-lv2")
            listLv2 = true;
        else if (a == "--list-sources")
            listSources = true;
        else if (a.length > 15 && a[0 .. 15] == "--check-plugin=")
            checkUri = a[15 .. $];
        else if (a.length > 13 && a[0 .. 13] == "--dump-chain=")
            dumpChain = a[13 .. $];
        else if (a.length > 10 && a[0 .. 10] == "--profile=")
            profileOverride = a[10 .. $];
    }

    if (checkUri.length > 0)
        return runCheckPlugin(checkUri);
    if (dumpChain.length > 0)
        return runDumpChain(dumpChain);
    if (listSources)
        return runListSources();
    if (listLv2)
        return runListLv2();
    if (headless)
        return runHeadless(profileOverride);
    return runGui(args);
}

/// Prepend bundled ./lv2 to LV2_PATH (exe dir + CWD, first hit wins).
void setupLocalLv2()
{
    import std.file : exists, thisExePath;
    import std.path : buildPath, dirName;
    import std.process : environment;

    string[] candidates;
    try
    {
        candidates ~= buildPath(dirName(thisExePath()), "lv2");
    }
    catch (Exception)
    {
    }
    candidates ~= buildPath(".", "lv2");
    string hit;
    foreach (c; candidates)
    {
        try
        {
            if (exists(buildPath(c, "manifest.ttl")) || exists(c))
            {
                // Accept the dir if it holds at least one bundle.
                import std.file : dirEntries, SpanMode;

                foreach (e; dirEntries(c, "*.lv2", SpanMode.shallow))
                {
                    hit = c;
                    break;
                }
            }
        }
        catch (Exception)
        {
        }
        if (hit.length > 0)
            break;
    }
    if (hit.length == 0)
        return;
    // Resolve to absolute for Lilv.
    try
    {
        import std.path : absolutePath;

        hit = absolutePath(hit);
    }
    catch (Exception)
    {
    }
    string cur = environment.get("LV2_PATH", "");
    if (cur.length == 0)
        environment["LV2_PATH"] = hit;
    else
    {
        import std.string : indexOf;

        if (cur.indexOf(hit) < 0)
            environment["LV2_PATH"] = hit ~ ":" ~ cur;
    }
}

/// Apply a profile headlessly and print the chain display model the UI
/// would render (slot validity, control counts). No audio needed.
int runDumpChain(string id)
{
    import audio.engine : Engine;
    import audio.profile : listProfiles;
    import std.stdio : writefln, stderr;

    auto engine = new Engine();
    foreach (ref p; listProfiles())
    {
        if (p.id != id)
            continue;
        if (!engine.applyProfile(p))
        {
            stderr.writeln("apply FAILED: ", engine.lastError);
            return 1;
        }
        auto disp = engine.slotDisplay();
        writefln("profile %s: %d slots", p.id, disp.length);
        foreach (i, ref d; disp)
            writefln("  [%d] %s  valid=%s enabled=%s controls=%d note='%s'",
                i, d.name, d.valid, d.enabled, d.controls.length, d.note);
        if (engine.lastError.length > 0)
            writefln("note: %s", engine.lastError);
        return 0;
    }
    stderr.writeln("profile not found: ", id);
    return 1;
}

int runListSources()
{
    import audio.pipewire : PipeWireBackend;
    import std.stdio : writefln;

    auto be = new PipeWireBackend();
    auto devs = be.listSources();
    foreach (ref d; devs)
        writefln("%s\n    %s%s\n", d.nodeName.length ? d.nodeName : "(default)",
            d.displayName, d.serial.length ? "  [serial " ~ d.serial ~ "]" : "");
    writefln("(%d sources)", devs.length);
    return 0;
}

int runListLv2()
{
    import audio.lv2 : discoverPlugins;
    import std.stdio : writefln;

    auto found = discoverPlugins();
    foreach (ref p; found)
        writefln("%s\n    %s%s%s\n", p.uri, p.name,
            p.vendor.length ? " — " ~ p.vendor : "",
            p.clazz.length ? "  [" ~ p.clazz ~ "]" : "");
    writefln("(%d plugins)", found.length);
    return 0;
}

int runCheckPlugin(string uri)
{
    import audio.lv2 : Lv2World;
    import std.stdio : writefln, stderr;

    auto w = Lv2World.create();
    if (w is null)
    {
        stderr.writeln("LV2 unavailable");
        return 1;
    }
    try
    {
        auto info = w.inspect(uri);
        writefln("name: %s", info.name);
        writefln("audio in/out: %d/%d  controls: %d  message ports: %d",
            info.audioInputs, info.audioOutputs, info.controlInputs, info.messagePorts);
        writefln("supported: %s", info.supportedForMvp() ? "yes" : "NO");
        foreach (ref p; info.ports)
        {
            if (p.isControl && p.isInput)
                writefln("  ctl %-12s %-28s min=%s max=%s def=%s%s", p.symbol, p.name,
                    p.hasRange ? p.min : float.nan, p.hasRange ? p.max : float.nan,
                    p.hasDef ? p.def : float.nan,
                    p.scalePoints.length ? "  enum" : "");
        }
        auto h = w.instantiate(uri, 48000.0);
        if (!h.valid)
        {
            stderr.writeln("instantiate FAILED: ", h.error);
            return 1;
        }
        writefln("instantiate: OK  run=%s", h.run !is null ? "yes" : "NO");
        Lv2World.closeInstance(h);
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("FAILED: ", e.msg);
        return 1;
    }
}

int runHeadless(string profileOverride)
{
    import audio.engine : Engine;
    import audio.profile : listProfiles;
    import core.thread : Thread;
    import core.time : seconds;
    import std.stdio : stderr;

    auto cfg = loadConfig();
    string want = profileOverride.length ? profileOverride : cfg.activeProfileId;

    auto engine = new Engine();
    auto profiles = listProfiles();
    bool applied;
    foreach (ref p; profiles)
        if (p.id == want)
        {
            applied = engine.applyProfile(p);
            if (!applied)
                stderr.writeln("Cannot activate profile '", want, "': ", engine.lastError);
            break;
        }
    if (!applied && profiles.length > 0)
    {
        // Fall back to first valid profile rather than silence.
        foreach (ref p; profiles)
            if (engine.applyProfile(p))
            {
                applied = true;
                break;
            }
    }
    if (!applied)
        stderr.writeln("No usable profile; idling with built-in gains.");

    if (!engine.startBackend())
        stderr.writeln("PipeWire unavailable: ", engine.lastError, " (continuing)");

    while (true)
    {
        try
        {
            engine.pumpCommands();
        }
        catch (Exception e)
        {
            try
                stderr.writeln("engine error: ", e.msg);
            catch (Exception)
            {
            }
        }
        Thread.sleep(1.seconds);
    }
}

int runGui(string[] args)
{
    import adw.application : Application;
    import gio.types : ApplicationFlags;
    import ui.window : MainWindow;
    import audio.engine : Engine;

    auto app = new Application(APP_ID, ApplicationFlags.DefaultFlags);
    auto engine = new Engine();

    MainWindow win;
    app.connectActivate(() {
        if (win is null)
            win = new MainWindow(app, engine);
        win.onShown();
    });

    return app.run(args);
}
