/**
 * Settings dialog (spec §24 "open settings"): style mode, backend
 * autostart, and backend status. Opened with `s`.
 */
module ui.settings_dialog;

import gtk.box;
import gtk.button;
import gtk.event_controller_key;
import gtk.label;
import gtk.list_box;
import gtk.list_box_row;
import gtk.switch_;
import gtk.types : Orientation;
import gtk.window : Window;
import gdk.types : ModifierType;
import omarchy.theme : StyleMode, styleModeName;

class SettingsDialog : Window
{
private:
    ListBox _styles;
    Switch _autostart;
    bool _suspend;
    void delegate(StyleMode mode) _onStyle;
    void delegate(bool on) _onAutostart;

    static immutable string[4] NAMES = ["system", "omarchy", "dark", "light"];
    static immutable string[4] DESCS = [
        "Desktop Adwaita, untouched",
        "Live Omarchy palette overlay",
        "Forced dark Adwaita",
        "Forced light Adwaita",
    ];

public:
    this(Window parent, StyleMode current, bool autostart, string status,
        void delegate(StyleMode) onStyle = null, void delegate(bool) onAutostart = null)
    {
        super();
        _onStyle = onStyle;
        _onAutostart = onAutostart;
        setTitle("Settings");
        setDefaultSize(420, 380);
        setModal(true);
        if (parent !is null)
            setTransientFor(parent);

        auto v = new Box(Orientation.Vertical, 8);
        v.setMarginTop(12);
        v.setMarginBottom(12);
        v.setMarginStart(12);
        v.setMarginEnd(12);

        auto stTitle = new Label("Style (`t` also cycles)");
        stTitle.setXalign(0.0f);
        v.append(stTitle);

        _suspend = true;
        _styles = new ListBox();
        foreach (i; 0 .. 4)
        {
            auto row = new ListBoxRow();
            auto b = new Box(Orientation.Vertical, 2);
            auto name = new Label(styleModeName(cast(StyleMode) i)
                ~ (cast(StyleMode) i == current ? "  ●" : ""));
            name.setXalign(0.0f);
            b.append(name);
            auto desc = new Label(DESCS[i]);
            desc.setXalign(0.0f);
            desc.addCssClass("ovs-dim");
            b.append(desc);
            row.setChild(b);
            _styles.append(row);
            if (cast(StyleMode) i == current)
                _styles.selectRow(row);
        }
        v.append(_styles);
        _styles.connectRowSelected((ListBoxRow row) {
            if (_suspend || row is null)
                return;
            int idx = row.getIndex();
            if (idx >= 0 && idx < 4 && _onStyle !is null)
                _onStyle(cast(StyleMode) idx);
        });
        _suspend = false;

        auto asRow = new Box(Orientation.Horizontal, 8);
        auto asLbl = new Label("Start audio backend automatically");
        asLbl.setXalign(0.0f);
        asLbl.setHexpand(true);
        asRow.append(asLbl);
        _autostart = new Switch();
        _autostart.setActive(autostart);
        _autostart.connectNotify("active", () {
            if (_suspend)
                return;
            if (_onAutostart !is null)
                _onAutostart(_autostart.getActive());
        });
        asRow.append(_autostart);
        v.append(asRow);

        auto stLbl = new Label(status);
        stLbl.setXalign(0.0f);
        stLbl.addCssClass("ovs-dim");
        v.append(stLbl);

        auto closeBtn = Button.newWithLabel("Close  (Esc)");
        closeBtn.connectClicked(() => close());
        v.append(closeBtn);

        setChild(v);

        auto keys = new EventControllerKey();
        keys.connectKeyPressed((uint keyval, uint keycode, ModifierType state) {
            if (keyval == 0xff1b) // Escape
            {
                close();
                return true;
            }
            return false;
        });
        addController(keys);
    }
}
