/**
 * Engine — control-thread owner of the audio graph (spec §31).
 *
 * Threads:
 *   GTK thread  --(EngineCommand)--> Engine --(publish)--> RT callback
 *
 *  - Holds `active` (RT-visible) and `pending` graphs. `publish()` swaps at
 *    a block boundary: RT `processFilterBlock` checks `pending` first.
 *  - Profile switching builds the new graph off-RT (LV2 instantiate +
 *    port connect + activate), validates, publishes; on failure the old
 *    graph keeps running (spec §16).
 *  - Retired graphs are reaped on the control thread only after the RT
 *    thread has processed 256 further blocks, so no in-flight run() can
 *    touch a freed instance.
 *  - UI commands (gain/bypass/control) apply to the control-side graph and
 *    are mirrored into RT-safe fields (plain floats/flags, no allocation).
 *  - Meters live in a shared MeterState; RT writes, GTK polls.
 */
module audio.engine;

import audio.graph : AudioGraph, ChannelMode, PluginSlot;
import audio.denoise : RnApi, loadRnNoise;
import audio.lv2 : Lv2World, Lv2PluginInfo, Lv2Handle, LilvInstance;
import audio.meter : MeterState, MeterSnapshot;
import audio.pipewire : PipeWireBackend, AudioDevice;
import audio.profile : Profile, DeviceRef;
import audio.rt_queue : CommandQueue, EngineCommand, EngineCommandKind;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;

enum uint RETIRE_GRACE_BLOCKS = 256;

final class Engine
{
private:
    AudioGraph _active; // RT-side graph (RT swaps; control reads)
    AudioGraph _latest; // control-side newest graph (tweaks always land here)
    AudioGraph _pending; // guarded by control thread; RT takes it atomically
    shared(bool) _hasPending;
    MeterState _meters;
    PipeWireBackend _backend;
    CommandQueue _queue;
    string _lastError;
    Profile _current;
    bool _hasCurrent;
    Lv2World _lv2; // null until first needed (or unavailable)
    bool _lv2Probed;
    RnApi _rn; // librnnoise binding (loaded lazily, process lifetime)
    bool _rnProbed;
    // Backend's active (input, channels): reconcile restarts it on drift.
    string _beInput;
    uint _beChannels;

    // RT block counter (RT writes; control reads with benign lag).
    uint _blocks;
    // Retired graphs awaiting reap (control frees LV2 after grace).
    // Ring of 4: overwriting an unreaped slot leaks instances but can
    // never free in-flight ones (deadlines only move forward).
    AudioGraph[4] _retired;
    uint[4] _retireDeadline;
    uint _retireNext; // RT-only ring cursor

    // RT port pointer staging (RT-only use).
    float*[2] _rtIn;
    float*[2] _rtOut;

    // Inspect cache: uri -> info (control thread only).
    Lv2PluginInfo[string] _inspectCache;

public:
    this()
    {
        _queue = new CommandQueue(8);
        _backend = new PipeWireBackend();
        _meters = MeterState.zeroed();
        _active = new AudioGraph(48000, 4096);
        ensureScratch(_active, 1);
        _active.meters = &_meters;
        _latest = _active;
    }

    @property string lastError() { return _lastError; }
    @property bool running() { return _backend.running; }
    @property bool hasProfile() const { return _hasCurrent; }
    @property uint backendNodeId() { return _backend.nodeId; }

    MeterSnapshot meterSnapshot() nothrow @nogc
    {
        return _meters.snapshot();
    }

    void clearClip() nothrow @nogc
    {
        _meters.clearClips();
    }

    bool startBackend()
    {
        uint ch = 1;
        if (_hasCurrent)
            ch = _current.channelMode == "stereo" ? 2 : 1;
        bool ok = _backend.start(cast(void*) this, currentInputName(), ch);
        if (!ok)
            _lastError = _backend.lastError;
        else
        {
            _beInput = currentInputName();
            _beChannels = ch;
        }
        return ok;
    }

    void stopBackend()
    {
        _backend.stop();
    }

    void pollBackend()
    {
        _backend.pollState();
    }

    AudioDevice[] sources()
    {
        return _backend.listSources();
    }

    /// Drain UI commands + reap retired graphs. Control/idle context only.
    void pumpCommands()
    {
        EngineCommand cmd;
        while (_queue.dequeue(cmd))
            applyCommand(cmd);
        reapRetired();
    }

    bool postCommand(EngineCommand cmd)
    {
        return _queue.enqueue(cmd);
    }

    // -- profile management ----------------------------------------------

    /// Apply a profile: build off-RT, validate, publish or keep old.
    bool applyProfile(Profile p)
    {
        try
        {
            p.validate();
        }
        catch (Exception e)
        {
            _lastError = "Invalid profile '" ~ p.id ~ "': " ~ e.msg;
            return false;
        }

        AudioGraph next;
        try
        {
            next = buildGraph(p);
        }
        catch (Exception e)
        {
            // Keep current graph active; surface error (spec §16).
            _lastError = "Could not activate profile '" ~ p.name ~ "': " ~ e.msg;
            return false;
        }

        publish(next);
        _current = p;
        _hasCurrent = true;
        reconcileBackend();
        return true;
    }

    /// Restart a running backend when the active profile drifted from what
    /// the filter was built with (input target or channel count). Ports
    /// bake both in at creation, so this is the only way to adopt them
    /// without restarting the application (spec §8.4). No-op when stopped.
    void reconcileBackend() nothrow
    {
        try
        {
            if (!_backend.running || !_hasCurrent)
                return;
            uint wantCh = _current.channelMode == "stereo" ? 2 : 1;
            if (_current.input.nodeName == _beInput && wantCh == _beChannels)
                return;
            _backend.stop();
            if (!_backend.start(cast(void*) this, _current.input.nodeName, wantCh))
            {
                try
                {
                    _lastError = "Audio backend failed: " ~ _backend.lastError;
                }
                catch (Exception)
                {
                }
            }
            else
            {
                _beInput = _current.input.nodeName;
                _beChannels = wantCh;
            }
        }
        catch (Exception)
        {
        }
    }

    Profile currentProfile()
    {
        return _current;
    }

    /// Switch input device (rebuilds the graph; reconcileBackend adopts
    /// the new target without an application restart, spec §8.4).
    bool switchInput(DeviceRef dev)
    {
        if (!_hasCurrent)
            return false;
        auto cur = _current;
        cur.input = dev;
        return applyProfile(cur);
    }

    /// Cached inspection for UI control generation (control thread).
    Lv2PluginInfo inspectPlugin(string uri)
    {
        if (auto hit = uri in _inspectCache)
            return *hit;
        auto w = lv2world();
        if (w is null)
            throw new Exception("LV2 unavailable");
        auto info = w.inspect(uri);
        _inspectCache[uri] = info;
        return info;
    }

    // -- UI display model -------------------------------------------------

    enum ControlKind : ubyte
    {
        slider,
        toggle,
        integer,
        enumeration,
    }

    struct ControlDisplay
    {
        uint controlIndex; // index into slot.controls / engine.setControl port
        string symbol;
        string label;
        float value;
        float min;
        float max;
        float def;
        ControlKind kind;
        string[] enumLabels;
        float[] enumValues;
    }

    struct SlotDisplay
    {
        string uri;
        string name;
        bool enabled;
        bool valid;
        string note;
        ControlDisplay[] controls;
    }

    /// Display model for the processing chain (control thread only).
    SlotDisplay[] slotDisplay()
    {
        SlotDisplay[] out_;
        if (!_hasCurrent || _latest is null)
            return out_;
        foreach (si, ref s; _latest.slots)
        {
            SlotDisplay d;
            d.uri = s.uri;
            d.name = s.name.length ? s.name : s.uri;
            d.enabled = s.enabled;
            d.valid = s.valid;
            d.note = s.note;
            if (auto info = s.uri in _inspectCache)
            {
                auto ctrls = info.controlInputs_();
                foreach (ci, ref c; ctrls)
                {
                    if (ci >= s.controls.length)
                        break;
                    ControlDisplay cd;
                    cd.controlIndex = cast(uint) ci;
                    cd.symbol = c.symbol;
                    cd.label = c.name.length ? c.name : c.symbol;
                    cd.value = s.controls[ci];
                    cd.min = c.min;
                    cd.max = c.max;
                    cd.def = c.def;
                    if (c.isToggled)
                        cd.kind = ControlKind.toggle;
                    else if (c.isEnum && c.scalePoints.length > 0)
                    {
                        cd.kind = ControlKind.enumeration;
                        foreach (ref sp; c.scalePoints)
                        {
                            cd.enumLabels ~= sp.label;
                            cd.enumValues ~= sp.value;
                        }
                    }
                    else if (c.isInteger)
                        cd.kind = ControlKind.integer;
                    else
                        cd.kind = ControlKind.slider;
                    d.controls ~= cd;
                }
            }
            out_ ~= d;
        }
        return out_;
    }

    // -- live tweaks (control thread) -------------------------------------

    void setInputGain(float db)
    {
        // Tweaks always land on the newest graph. In steady state that is
        // the active graph; right after publish() it is the pending graph
        // the RT thread is about to pick up — never a retired one.
        if (_latest !is null)
            _latest.inputGainDb = db;
    }

    void setOutputGain(float db)
    {
        if (_latest !is null)
            _latest.outputGainDb = db;
    }

    void setSlotEnabled(uint slot, bool enabled)
    {
        if (_latest !is null && slot < _latest.slots.length)
            _latest.slots[slot].enabled = enabled;
    }

    /// Bypass toggle that also persists into the current profile copy.
    void persistSlotEnabled(uint slot, bool enabled)
    {
        setSlotEnabled(slot, enabled);
        if (_hasCurrent && slot < _current.plugins.length)
            _current.plugins[slot].enabled = enabled;
    }

    /// Human-readable denoise state for the UI (control thread).
    string denoiseInfo()
    {
        if (!_hasCurrent)
            return "";
        if (!_current.denoise)
            return "off";
        if (_latest !is null && _latest.denoiseNote.length > 0)
            return _latest.denoiseNote;
        return "on";
    }

    /// Toggle RNNoise for the current profile (rebuilds the graph).
    bool setDenoise(bool on)
    {
        if (!_hasCurrent)
            return false;
        auto cur = _current;
        cur.denoise = on;
        return applyProfile(cur);
    }

    void setControl(uint slot, uint port, float value)
    {
        if (_latest !is null && slot < _latest.slots.length)
        {
            auto ref s = _latest.slots[slot];
            if (port < s.controls.length)
                s.controls[port] = value;
        }
    }

    /// Reset one slot's controls to plugin defaults (control thread).
    /// Returns false when the slot has no inspectable defaults.
    bool resetSlotControls(uint slot)
    {
        if (!_hasCurrent || slot >= _current.plugins.length)
            return false;
        string uri = _current.plugins[slot].uri;
        Lv2PluginInfo info;
        if (auto hit = uri in _inspectCache)
            info = *hit;
        else
        {
            auto w = lv2world();
            if (w is null)
                return false;
            try
                info = w.inspect(uri);
            catch (Exception)
            {
                return false;
            }
            _inspectCache[uri] = info;
        }
        auto ctrls = info.controlInputs_();
        foreach (ci, ref c; ctrls)
            setControlPersist(slot, cast(uint) ci, c.symbol, c.def);
        return ctrls.length > 0;
    }
    void setControlPersist(uint slot, uint port, string symbol, float value)
    {
        setControl(slot, port, value);
        if (_hasCurrent && slot < _current.plugins.length && symbol.length > 0)
            _current.plugins[slot].controls[symbol] = value;
    }

    // -- RT entry ----------------------------------------------------------

    /**
     * Called from the PipeWire RT thread via the pw_filter process event.
     * Never allocates, locks, or touches GTK/LV2/GC.
     */
    void processFilterBlock(uint nframes) nothrow @nogc
    {
        _blocks += 1;

        // Block-boundary graph swap.
        if (_hasPending)
        {
            auto next = cast(AudioGraph) atomicLoad!(MemoryOrder.acq)(*cast(shared void**)&_pending);
            if (next !is null)
            {
                auto old = _active;
                _active = next;
                // Schedule the old graph for deferred reap (control frees
                // LV2 instances after the grace period).
                _retired[_retireNext % _retired.length] = old;
                _retireDeadline[_retireNext % _retired.length] = _blocks + RETIRE_GRACE_BLOCKS;
                _retireNext++;
                atomicStore!(MemoryOrder.rel)(_hasPending, false);
            }
        }

        if (_active is null || nframes == 0)
            return;
        uint got = _backend.portBuffers(nframes, _active.maxFrames, _rtIn.ptr, _rtOut.ptr);
        if (got == 0)
            return;
        _active.process(_rtIn.ptr, _rtOut.ptr, got);
    }

    /// Legacy swap entry (unconnected path: no RT runs the graph, so the
    /// old graph is reaped on the next pump).
    void processCallback(void* filterData) nothrow @nogc
    {
        if (_hasPending)
        {
            auto next = cast(AudioGraph) atomicLoad!(MemoryOrder.acq)(*cast(shared void**)&_pending);
            if (next !is null)
            {
                auto old = _active;
                _active = next;
                _retired[_retireNext % _retired.length] = old;
                _retireDeadline[_retireNext % _retired.length] = 0; // reap ASAP
                _retireNext++;
                atomicStore!(MemoryOrder.rel)(_hasPending, false);
            }
        }
    }

    /// Direct (test) processing entry.
    void processBuffers(float** ins, float** outs, uint nframes) nothrow @nogc
    {
        if (_active !is null)
            _active.process(ins, outs, nframes);
    }

private:
    Lv2World lv2world()
    {
        if (!_lv2Probed)
        {
            _lv2Probed = true;
            _lv2 = Lv2World.create(); // null when unavailable: graceful
        }
        return _lv2;
    }

    string currentInputName()
    {
        if (_hasCurrent)
            return _current.input.nodeName;
        return "";
    }

    void applyCommand(ref const EngineCommand cmd) nothrow
    {
        try
        {
            final switch (cmd.kind)
            {
            case EngineCommandKind.setInputGain:
                setInputGain(cmd.value);
                break;
            case EngineCommandKind.setOutputGain:
                setOutputGain(cmd.value);
                break;
            case EngineCommandKind.setSlotEnabled:
                setSlotEnabled(cmd.slot, cmd.value != 0.0f);
                break;
            case EngineCommandKind.setControl:
                setControl(cmd.slot, cmd.port, cmd.value);
                break;
            case EngineCommandKind.swapGraph:
                if (cmd.graph !is null)
                    publish(cast(AudioGraph) cmd.graph);
                break;
            case EngineCommandKind.noop:
                break;
            }
        }
        catch (Exception)
        {
        }
    }

    AudioGraph buildGraph(ref Profile p)
    {
        auto g = new AudioGraph(48000, 4096);
        g.mode = p.channelMode == "stereo" ? ChannelMode.stereo : ChannelMode.mono;
        g.inputGainDb = cast(float) p.inputGainDb;
        g.outputGainDb = cast(float) p.outputGainDb;
        g.meters = &_meters;

        uint ch = g.channels();
        ensureScratch(g, ch);
        buildDenoise(g, p.denoise, ch);

        auto w = p.plugins.length > 0 ? lv2world() : null;
        bool sideB = false; // slot0 reads A
        foreach (ref e; p.plugins)
        {
            PluginSlot s;
            s.uri = e.uri;
            s.name = e.uri;
            s.enabled = e.enabled;
            s.inIsB = sideB;
            s.outIsB = !sideB;
            sideB = !sideB;
            if (e.uri.length == 0)
            {
                s.valid = false;
                s.note = "(empty plugin entry)";
                _lastError = "The selected plugin chain requires an unsupported channel layout.";
            }
            else if (w is null)
            {
                s.valid = false;
                s.note = "(LV2 unavailable)";
                _lastError = "LV2 unavailable — plugin skipped: " ~ e.uri;
            }
            else
            {
                wireLv2Slot(w, g, s, e.uri, e.controls);
            }
            g.slots ~= s;
        }
        return g;
    }

    /// Build the RNNoise first stage (control thread). Inert with a note
    /// when disabled or librnnoise is missing; never fails the profile.
    void buildDenoise(AudioGraph g, bool want, uint ch)    {
        if (!want)
            return;
        if (!_rnProbed)
        {
            _rnProbed = true;
            _rn = loadRnNoise();
        }
        if (!_rn.available)
        {
            g.denoiseNote = "RNNoise unavailable (librnnoise not found)";
            return;
        }
        if (g.sampleRate != 48000)
        {
            g.denoiseNote = "RNNoise needs 48 kHz";
            return;
        }
        g.denoise.length = ch;
        foreach (c; 0 .. ch)
        {
            auto st = _rn.create(null);
            if (st is null)
            {
                g.denoise.length = 0;
                g.denoiseNote = "RNNoise init failed";
                return;
            }
            g.denoise[c].st = st;
            g.denoise[c].procFn = _rn.process;
            g.denoise[c].reset();
        }
        g.denoiseNote = "RNNoise on";
    }

    /// Instantiate + connect one LV2 slot (control thread). Sets s.valid,
    /// s.name, s.controls, buffers; records _lastError on failure.
    void wireLv2Slot(Lv2World w, AudioGraph g, ref PluginSlot s,
        string uri, const double[string] saved)
    {
        import std.string : toStringz;

        Lv2PluginInfo info;
        try
        {
            if (auto hit = uri in _inspectCache)
                info = *hit;
            else
            {
                info = w.inspect(uri);
                _inspectCache[uri] = info;
            }
        }
        catch (Exception e)
        {
            s.valid = false;
            s.note = "(plugin unavailable)";
            _lastError = "Plugin unavailable (" ~ uri ~ "): " ~ e.msg;
            return;
        }
        s.name = info.name;

        if (!info.supportedForMvp())
        {
            s.valid = false;
            s.note = "(unsupported ports)";
            _lastError = "Unsupported plugin (needs mono/stereo audio-only ports): " ~ info.name;
            return;
        }
        auto ain = info.audioPortIndices(true);
        auto aout = info.audioPortIndices(false);
        if (aout.length != g.channels() || ain.length < g.channels())
        {
            s.valid = false;
            import std.format : format;

            s.note = format("(needs %s profile: %d in / %d out)",
                g.channels() == 2 ? "stereo" : "mono", ain.length, aout.length);
            _lastError = "The selected plugin chain requires an unsupported channel layout.";
            return;
        }

        auto h = w.instantiate(uri, cast(double) g.sampleRate);
        if (!h.valid)
        {
            s.valid = false;
            s.note = "(instantiation failed)";
            _lastError = "Could not instantiate " ~ info.name ~ ": " ~ h.error;
            return;
        }

        // Control values: saved profile values by symbol, else defaults.
        auto ctrls = info.controlInputs_();
        s.controls.length = ctrls.length;
        foreach (i, ref c; ctrls)
        {
            float v = c.def;
            if (auto sv = c.symbol in saved)
                v = cast(float)*sv;
            else if (auto nm = c.name in saved)
                v = cast(float)*nm;
            if (c.hasRange)
            {
                if (v < c.min)
                    v = c.min;
                if (v > c.max)
                    v = c.max;
            }
            s.controls[i] = v;
        }
        s.controlSink.length = 0;

        // Wire audio ports to scratch sides. Extra audio inputs (sidechain)
        // are tied to a shared zero buffer — standard host behavior,
        // surfaced as a UI note.
        float[][] inSide = s.inIsB ? g.scratchB : g.scratchA;
        float[][] outSide = s.outIsB ? g.scratchB : g.scratchA;
        foreach (ci, lv2idx; ain)
        {
            if (ci < g.channels())
                h.connect(h.lv2handle, lv2idx, inSide[ci].ptr);
            else
            {
                h.connect(h.lv2handle, lv2idx, g.zeroBuf.ptr);
                if (s.note.length == 0)
                    s.note = "(sidechain silenced)";
            }
        }
        foreach (ci, lv2idx; aout)
            h.connect(h.lv2handle, lv2idx, outSide[ci].ptr);
        // Wire control inputs to plain floats, control outputs to sinks,
        // message (atom/event) ports to the shared dummy buffer.
        size_t ci;
        s.atomScratch.length = 0;
        foreach (ref p; info.ports)
        {
            if (p.isControl && p.isInput)
            {
                h.connect(h.lv2handle, p.index, &s.controls[ci]);
                ci++;
            }
            else if (p.isControl && p.isOutput)
            {
                s.controlSink ~= 0.0f;
                h.connect(h.lv2handle, p.index, &s.controlSink[$ - 1]);
            }
            else if (p.isMessage)
            {
                if (s.atomScratch.length == 0)
                    s.atomScratch = new ubyte[256]; // zeroed empty area
                h.connect(h.lv2handle, p.index, s.atomScratch.ptr);
            }
        }
        if (info.messagePorts > 0)
        {
            import std.conv : to;

            s.note = "(" ~ info.messagePorts.to!string ~ " message port" ~
                (info.messagePorts > 1 ? "s" : "") ~ " inert)";
        }

        s.instance = h.lv2handle;
        s.runFn = h.run;
        s.lilvInstance = h.instance;
        s.valid = true;
    }

    void ensureScratch(AudioGraph g, uint ch)
    {
        g.scratchA.length = ch;
        g.scratchB.length = ch;
        foreach (c; 0 .. ch)
        {
            if (g.scratchA[c].length < g.maxFrames)
                g.scratchA[c].length = g.maxFrames;
            if (g.scratchB[c].length < g.maxFrames)
                g.scratchB[c].length = g.maxFrames;
        }
        if (g.zeroBuf.length < g.maxFrames)
            g.zeroBuf.length = g.maxFrames;
        g.zeroBuf[] = 0.0f;
    }

    void publish(AudioGraph next)
    {
        next.meters = &_meters;
        _latest = next;
        // If a previous pending graph was never picked up (two publishes
        // within one block), retire it with grace instead of leaking it.
        // Safe either way: if RT grabs it this block it becomes active and
        // is retired normally on the next swap.
        auto superseded = cast(AudioGraph) atomicLoad!(MemoryOrder.acq)(
            *cast(shared void**)&_pending);
        if (_hasPending && superseded !is null && superseded !is next)
        {
            _retired[_retireNext % _retired.length] = superseded;
            _retireDeadline[_retireNext % _retired.length] = _blocks + RETIRE_GRACE_BLOCKS;
            _retireNext++;
        }
        atomicStore!(MemoryOrder.rel)(*cast(shared void**)&_pending, cast(shared void*) next);
        atomicStore!(MemoryOrder.rel)(_hasPending, true);
        // NOTE: _active is swapped by the RT thread at the next block
        // boundary (which schedules the old graph for deferred reap).
        // The control side must NOT swap _active itself: it would retire
        // the new graph while RT may still run the old one.
    }

    /// Free retired LV2 instances once past the grace deadline (control).
    void reapRetired() nothrow
    {
        try
        {
            uint now = _blocks; // benign lag vs RT increments
            foreach (i; 0 .. _retired.length)
            {
                if (_retired[i] is null)
                    continue;
                if (now < _retireDeadline[i])
                    continue;
            foreach (ref s; _retired[i].slots)
            {
                if (s.lilvInstance !is null)
                {
                    Lv2Handle h;
                    h.instance = cast(LilvInstance*) s.lilvInstance;
                    Lv2World.closeInstance(h);
                    s.lilvInstance = null;
                    s.runFn = null;
                    s.instance = null;
                }
            }
            // Destroy RNNoise states (control thread only).
            if (_rn.available)
            {
                foreach (ref d; _retired[i].denoise)
                {
                    if (d.st !is null)
                    {
                        _rn.destroy_(d.st);
                        d.st = null;
                    }
                }
            }
            _retired[i] = null;
            }
        }
        catch (Exception)
        {
        }
    }
}

unittest
{
    import audio.profile : Profile, PluginEntry;

    auto eng = new Engine();
    Profile p;
    p.id = "test";
    p.name = "Test";
    p.channelMode = "mono";
    assert(eng.applyProfile(p));
    assert(eng.hasProfile);

    Profile bad;
    bad.id = "";
    assert(!eng.applyProfile(bad));
    // Old graph preserved:
    assert(eng.hasProfile);
    assert(eng.currentProfile.id == "test");

    // Input switch rewrites the profile without a backend restart when the
    // backend is down (no daemon needed for this path).
    import audio.profile : DeviceRef;

    DeviceRef dev;
    dev.nodeName = "alsa_input.usb-test";
    dev.displayName = "USB Mic";
    dev.serial = "42";
    assert(eng.switchInput(dev));
    assert(eng.currentProfile.input.nodeName == "alsa_input.usb-test");
    assert(eng.currentProfile.input.serial == "42");
}
