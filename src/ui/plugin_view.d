/**
 * Processing-chain view: ordered plugin slots with enable/bypass,
 * move up/down, remove — plus generic LV2 control widgets generated from
 * port metadata (slider / toggle / integer / enumeration) and an
 * Add Plugin entry point (spec §12).
 *
 * Control changes go straight to the engine (RT-safe plain-float writes);
 * the window persists them into the profile.
 */
module ui.plugin_view;

import gtk.adjustment;
import gtk.box;
import gtk.button;
import gtk.check_button;
import gtk.label;
import gtk.list_box;
import gtk.list_box_row;
import gtk.scale;
import gtk.switch_;
import gtk.types : Orientation;
import gtk.widget : Widget;
import audio.engine : Engine;

class PluginView : Box
{
private:
    ListBox _list;
    Engine.SlotDisplay[] _slots;
    // Swallows toggled/value-changed emissions during rebuild.
    bool _suspend;
    void delegate(uint idx) _onToggle;
    void delegate(int from, int to) _onMove;
    void delegate(uint idx) _onRemove;
    void delegate() _onAdd;
    void delegate(uint slot, uint control, float value) _onControl;

public:
    this(void delegate(uint) onToggle = null, void delegate(int, int) onMove = null,
        void delegate(uint) onRemove = null, void delegate() onAdd = null,
        void delegate(uint, uint, float) onControl = null)
    {
        super(Orientation.Vertical, 6);
        _onToggle = onToggle;
        _onMove = onMove;
        _onRemove = onRemove;
        _onAdd = onAdd;
        _onControl = onControl;

        auto title = new Label("Processing chain");
        title.setXalign(0.0f);
        append(title);

        _list = new ListBox();
        append(_list);

        auto addBtn = Button.newWithLabel("[ Add Plugin ]  (a)");
        addBtn.connectClicked(() {
            if (_onAdd !is null)
                _onAdd();
        });
        append(addBtn);
    }

    void setSlots(Engine.SlotDisplay[] slots)
    {
        _suspend = true;
        scope (exit)
            _suspend = false;
        _slots = slots.dup;
        _list.removeAll();
        foreach (i, ref s; _slots)
        {
            // NOTE: delegates capture loop variables by reference in D —
            // passing everything through bindRow() (function parameters,
            // fresh per call) so each row's callbacks hit their own slot.
            // Inlining the lambdas here made every row act on the LAST slot.
            uint idx = cast(uint) i;
            bindRow(idx, s.enabled ? "●" : "○", s.enabled,
                s.name.length ? s.name : s.uri, s.valid,
                s.note, s.controls.dup);
        }
    }

    private void bindRow(uint idx, string mark, bool enabled, string title,
        bool valid, string note, Engine.ControlDisplay[] ctrls)
    {
        auto row = new ListBoxRow();
        auto v = new Box(Orientation.Vertical, 4);
        auto h = new Box(Orientation.Horizontal, 8);

        auto toggle = new CheckButton();
        toggle.setLabel(mark);
        toggle.setActive(enabled);
        toggle.connectToggled(() {
            if (_suspend)
                return;
            if (_onToggle !is null)
                _onToggle(idx);
        });
        h.append(toggle);

        auto lbl = new Label(title);
        lbl.setXalign(0.0f);
        lbl.setHexpand(true);
        h.append(lbl);

        if (!valid)
        {
            // Specific reason when the engine knows one (e.g. channel
            // mismatch suggests switching the profile to stereo).
            auto warn = new Label(note.length > 0 ? note : "(unsupported)");
            h.append(warn);
        }
        else if (note.length > 0)
        {
            auto noteLbl = new Label(note);
            h.append(noteLbl);
        }

        auto upBtn = Button.newWithLabel("↑");
        upBtn.connectClicked(() {
            if (_onMove !is null)
                _onMove(cast(int) idx, cast(int) idx - 1);
        });
        h.append(upBtn);

        auto downBtn = Button.newWithLabel("↓");
        downBtn.connectClicked(() {
            if (_onMove !is null)
                _onMove(cast(int) idx, cast(int) idx + 1);
        });
        h.append(downBtn);

        auto rmBtn = Button.newWithLabel("✕");
        rmBtn.connectClicked(() {
            if (_onRemove !is null)
                _onRemove(idx);
        });
        h.append(rmBtn);

        v.append(h);

        // Generic controls for this slot.
        foreach (cd; ctrls)
            v.append(controlWidget(idx, cd));

        row.setChild(v);
        _list.append(row);
    }

    /// Keyboard navigation over slots (highlight only; Space toggles).
    void moveSelection(int delta)
    {
        import ui.scroll : moveListSelection;

        moveListSelection(_list, cast(uint) _slots.length, delta);
    }

    int selectedSlot()
    {
        auto sel = _list.getSelectedRow();
        if (sel is null)
            return -1;
        return sel.getIndex();
    }

    void focusList()
    {
        _list.grabFocus();
    }

private:
    Widget controlWidget(uint slot, Engine.ControlDisplay cd)
    {
        auto box = new Box(Orientation.Horizontal, 8);
        box.setMarginStart(24);
        auto lbl = new Label(cd.label);
        lbl.setXalign(0.0f);
        lbl.setHexpand(true);
        lbl.setTooltipText(cd.symbol);
        box.append(lbl);

        auto valLbl = new Label("");
        valLbl.setXalign(1.0f);
        valLbl.setSizeRequest(90, -1);

        final switch (cd.kind)
        {
        case Engine.ControlKind.toggle:
            auto sw = new Switch();
            sw.setActive(cd.value >= 0.5f);
            sw.connectNotify("active", () {
                if (_suspend)
                    return;
                bool on = sw.getActive();
                valLbl.setText(on ? "on" : "off");
                if (_onControl !is null)
                    _onControl(slot, cd.controlIndex, on ? 1.0f : 0.0f);
            });
            valLbl.setText(cd.value >= 0.5f ? "on" : "off");
            box.append(valLbl);
            box.append(sw);
            break;
        case Engine.ControlKind.enumeration:
        case Engine.ControlKind.integer:
        case Engine.ControlKind.slider:
            float lo = cd.min, hi = cd.max;
            if (!(hi > lo))
            {
                hi = lo + 1.0f;
            }
            double step = cd.kind == Engine.ControlKind.slider ? (hi - lo) / 100.0 : 1.0;
            if (step <= 0)
                step = 1.0;
            auto adj = new Adjustment(cd.value, lo, hi, step, (hi - lo) / 10.0, 0.0);
            auto scale = new Scale(Orientation.Horizontal, adj);
            scale.setDigits(cd.kind == Engine.ControlKind.slider ? 2 : 0);
            scale.setDrawValue(false);
            scale.setSizeRequest(160, -1);
            scale.connectValueChanged(() {
                if (_suspend)
                    return;
                float nv = cast(float) scale.getValue();
                valLbl.setText(displayValue(cd, nv));
                if (_onControl !is null)
                    _onControl(slot, cd.controlIndex, nv);
            });
            valLbl.setText(displayValue(cd, cd.value));
            box.append(valLbl);
            box.append(scale);
            break;
        }
        return box;
    }

    static string displayValue(ref const Engine.ControlDisplay cd, float v)
    {
        import std.format : format;

        if (cd.kind == Engine.ControlKind.enumeration)
        {
            // Nearest scale-point label.
            string best = format("%.2f", v);
            float bestD = float.max;
            foreach (i, lab; cd.enumLabels)
            {
                float d = v - cd.enumValues[i];
                if (d < 0)
                    d = -d;
                if (d < bestD)
                {
                    bestD = d;
                    best = lab;
                }
            }
            return best;
        }
        if (cd.kind == Engine.ControlKind.toggle)
            return v >= 0.5f ? "on" : "off";
        if (cd.kind == Engine.ControlKind.integer)
            return format("%d", cast(int) v);
        return format("%.2f", v);
    }
}
