/**
 * Input device selector + gain sliders + virtual-mic status.
 */
module ui.device_view;

import gtk.box;
import gtk.button;
import gtk.label;
import gtk.list_box;
import gtk.list_box_row;
import gtk.scale;
import gtk.adjustment;
import gtk.switch_;
import gtk.types : Orientation;
import gtk.widget : Widget;
import audio.pipewire : AudioDevice;
import ui.meter : MeterWidget;

class DeviceView : Box
{
private:
    ListBox _inputs;
    MeterWidget _inMeter;
    MeterWidget _outMeter;
    Scale _inGain;
    Scale _outGain;
    Label _virtLabel;
    AudioDevice[] _devices;
    // Swallows row-selected emissions during rebuild (see profile_view.d).
    bool _suspend;

    void delegate(string nodeName) _onSelectInput;
    void delegate(float db) _onInputGain;
    void delegate(float db) _onOutputGain;
    void delegate(bool on) _onDenoise;
    Switch _denoiseSwitch;
    Label _denoiseNote;

public:
    this(void delegate(string) onSelectInput = null, void delegate(float) onInputGain = null,
        void delegate(float) onOutputGain = null, void delegate(bool) onDenoise = null)
    {
        super(Orientation.Vertical, 8);
        _onSelectInput = onSelectInput;
        _onInputGain = onInputGain;
        _onOutputGain = onOutputGain;
        _onDenoise = onDenoise;

        auto inTitle = new Label("Input");
        inTitle.setXalign(0.0f);
        append(inTitle);

        _inputs = new ListBox();
        append(_inputs);
        _inputs.connectRowSelected((ListBoxRow row) {
            if (_suspend)
                return;
            if (row is null)
                return;
            int idx = row.getIndex();
            if (idx >= 0 && idx < cast(int) _devices.length && _onSelectInput !is null)
                _onSelectInput(_devices[idx].nodeName);
        });

        append(gainRow("Input gain", -60.0, 24.0, &_inGain, true));
        _inMeter = new MeterWidget("input");
        append(_inMeter);

        auto dnRow = new Box(Orientation.Horizontal, 8);
        auto dnLbl = new Label("Noise suppression (RNNoise)");
        dnLbl.setXalign(0.0f);
        dnLbl.setHexpand(true);
        dnRow.append(dnLbl);
        _denoiseSwitch = new Switch();
        _denoiseSwitch.connectNotify("active", () {
            if (_suspend)
                return;
            if (_onDenoise !is null)
                _onDenoise(_denoiseSwitch.getActive());
        });
        dnRow.append(_denoiseSwitch);
        append(dnRow);
        _denoiseNote = new Label("");
        _denoiseNote.setXalign(0.0f);
        _denoiseNote.addCssClass("ovs-dim");
        append(_denoiseNote);

        auto virtTitle = new Label("Virtual Mic");
        virtTitle.setXalign(0.0f);
        append(virtTitle);
        _virtLabel = new Label("Omarchy Voice Studio");
        _virtLabel.setXalign(0.0f);
        append(_virtLabel);

        append(gainRow("Output gain", -60.0, 24.0, &_outGain, false));
        _outMeter = new MeterWidget("output");
        append(_outMeter);
    }

    void setDevices(AudioDevice[] devs, string activeNode)
    {
        _suspend = true;
        scope (exit)
            _suspend = false;
        _devices = devs.dup;
        _inputs.removeAll();
        foreach (i, ref d; _devices)
        {
            auto row = new ListBoxRow();
            bool active = (d.nodeName == activeNode || (d.isDefault && activeNode.length == 0));
            auto lbl = new Label((active ? "> " : "  ") ~ d.displayName);
            lbl.setXalign(0.0f);
            row.setChild(lbl);
            _inputs.append(row);
            if (active)
            {
                _inputs.selectRow(row);
                import ui.scroll : ensureRowVisible;

                ensureRowVisible(_inputs, row);
            }
        }
    }

    void setMeters(float inPeak, bool inClip, float outPeak, bool outClip)
    {
        _inMeter.setPeak(inPeak, inClip);
        _outMeter.setPeak(outPeak, outClip);
    }

    void setDenoise(bool on, string note)
    {
        _suspend = true;
        scope (exit)
            _suspend = false;
        _denoiseSwitch.setActive(on);
        _denoiseNote.setText(note);
    }

    /// Reflect profile gains on the sliders (programmatic, no feedback).
    void setGains(double inDb, double outDb)
    {
        _suspend = true;
        scope (exit)
            _suspend = false;
        if (_inGain !is null)
            _inGain.setValue(inDb);
        if (_outGain !is null)
            _outGain.setValue(outDb);
    }

    /// Keyboard navigation over the input list.
    void moveSelection(int delta)
    {
        import ui.scroll : moveListSelection;

        moveListSelection(_inputs, cast(uint) _devices.length, delta);
    }

    void focusList()
    {
        _inputs.grabFocus();
    }

    string selectedInput()
    {
        auto sel = _inputs.getSelectedRow();
        if (sel is null)
            return null;
        int idx = sel.getIndex();
        if (idx < 0 || idx >= cast(int) _devices.length)
            return null;
        return _devices[idx].nodeName;
    }

    void setRunning(bool running, string err)    {
        if (running)
        {
            _virtLabel.setText("Omarchy Voice Studio  ● Running");
            _virtLabel.addCssClass("ovs-status-running");
        }
        else
        {
            _virtLabel.setText(err.length ? ("Stopped: " ~ err) : "Stopped");
            _virtLabel.removeCssClass("ovs-status-running");
        }
    }

private:
    Widget gainRow(string title, double lo, double hi, Scale* slot, bool isInput)
    {
        auto box = new Box(Orientation.Horizontal, 8);
        auto lbl = new Label(title);
        lbl.setXalign(0.0f);
        lbl.setHexpand(true);
        box.append(lbl);
        auto adj = new Adjustment(0.0, lo, hi, 0.5, 2.0, 0.0);
        auto scale = new Scale(Orientation.Horizontal, adj);
        scale.setDigits(1);
        scale.setDrawValue(true);
        scale.setSizeRequest(180, -1);
        scale.connectValueChanged(() {
            if (_suspend)
                return;
            float db = cast(float) scale.getValue();
            if (isInput)
            {
                if (_onInputGain !is null)
                    _onInputGain(db);
            }
            else if (_onOutputGain !is null)
                _onOutputGain(db);
        });
        box.append(scale);
        *slot = scale;
        return box;
    }
}
