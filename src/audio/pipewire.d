/**
 * PipeWire backend — owns the pw_thread_loop + pw_filter DSP node.
 *
 * Design (spec §8, §31):
 *  - GTK main thread -> Engine (control) -> RT PipeWire thread.
 *  - This module isolates ALL PipeWire FFI usage. `audio.engine` talks to
 *    `PipeWireBackend` only.
 *  - Node: pw_filter with per-channel F32 input/output ports
 *    (EnumFormat pods built by the C shim), connected with
 *    PW_FILTER_FLAG_RT_PROCESS.
 *  - Virtual source properties (spec §8.3):
 *      node.name = "omarchy-voice-studio"
 *      node.description = "Omarchy Voice Studio"
 *      media.type = "Audio", media.category = "Capture",
 *      media.role = "DSP", media.class = "Audio/Source"
 *  - Never makes itself the system default (spec §8.3). Input routing uses
 *    the port `target.object` property only when the user picked a device.
 *  - Graceful degradation: init/connect failures leave the backend stopped
 *    with a human-readable `lastError`; the app keeps running (spec §3.4).
 */
module audio.pipewire;

import audio.pipewire_ffi;
import core.stdc.string : strlen;

enum string VIRTUAL_NODE_NAME = "omarchy-voice-studio";
enum string VIRTUAL_NODE_DESC = "Omarchy Voice Studio";
enum uint MAX_CHANNELS = 2;

struct AudioDevice
{
    string nodeName;
    string displayName;
    string serial;
    bool isDefault;
}

enum BackendState : ubyte
{
    stopped,
    starting,
    running,
    failed,
}

// RT process trampoline: matches pw_filter_events.process.
private extern (C) void filterProcess(void* userdata, SpaIoPosition* pos) nothrow @nogc
{
    import audio.engine : Engine;

    auto eng = cast(Engine) userdata;
    if (eng is null || pos is null)
        return;
    eng.processFilterBlock(cast(uint) pos.clock.duration);
}

final class PipeWireBackend
{
private:
    pw_thread_loop* _loop;
    pw_filter* _filter;
    pw_filter_events _events; // must outlive _filter; plain member => stable
    bool _pwInitDone;
    string _lastError;
    BackendState _state = BackendState.stopped;
    uint _nodeId;
    uint _channels = 1;

    // RT-visible port handles (written once at connect, read by RT).
    void*[MAX_CHANNELS] _inPorts;
    void*[MAX_CHANNELS] _outPorts;

    // Format pods (one per port) must stay alive while connected.
    ubyte[512][MAX_CHANNELS] _podIn;
    ubyte[512][MAX_CHANNELS] _podOut;

public:
    @property BackendState state() const nothrow @nogc { return _state; }
    @property string lastError() const nothrow { return _lastError; }
    @property uint nodeId() const nothrow @nogc { return _nodeId; }
    @property uint channels() const nothrow @nogc { return _channels; }
    @property bool running() const nothrow @nogc
    {
        return _state == BackendState.running && _filter !is null;
    }

    /// Initialize PipeWire client library. Never throws.
    bool init() nothrow
    {
        try
        {
            if (!_pwInitDone)
            {
                pw_init(null, null);
                _pwInitDone = true;
            }
            auto v = pw_get_library_version();
            if (v is null)
            {
                _lastError = "PipeWire library returned no version";
                _state = BackendState.failed;
                return false;
            }
            return true;
        }
        catch (Exception e)
        {
            try
            {
                _lastError = e.msg;
            }
            catch (Exception)
            {
            }
            _state = BackendState.failed;
            return false;
        }
    }

    /**
     * Start the filter graph. `enginePtr` must be the owning
     * audio.engine.Engine (kept alive by the caller). Control thread only.
     */
    bool start(void* enginePtr, string inputNodeName, uint channels) nothrow
    {
        _state = BackendState.starting;
        try
        {
            if (!init())
                return false;
            if (channels < 1 || channels > MAX_CHANNELS)
                channels = 1;
            _channels = channels;

            _loop = pw_thread_loop_new("omarchy-voice-studio", null);
            if (_loop is null)
            {
                _lastError = "Could not create PipeWire thread loop (is PipeWire running?)";
                _state = BackendState.failed;
                return false;
            }
            auto loop = pw_thread_loop_get_loop(_loop);
            if (loop is null)
            {
                _lastError = "Could not get PipeWire loop";
                stop();
                _state = BackendState.failed;
                return false;
            }
            pw_thread_loop_start(_loop);

            pw_thread_loop_lock(_loop);
            scope (exit)
                pw_thread_loop_unlock(_loop);

            if (!createFilter(loop, enginePtr, inputNodeName))
            {
                stop();
                _state = BackendState.failed;
                return false;
            }

            _state = BackendState.running;
            return true;
        }
        catch (Exception e)
        {
            try
            {
                _lastError = e.msg;
            }
            catch (Exception)
            {
            }
            stop();
            _state = BackendState.failed;
            return false;
        }
    }

    void stop() nothrow
    {
        try
        {
            if (_filter !is null)
            {
                // First detach RT from the ports: an in-flight process
                // block then degrades to silence instead of touching freed
                // port data. A finer fence is unnecessary — worst case one
                // stale block runs against ports being unlinked.
                foreach (c; 0 .. MAX_CHANNELS)
                {
                    _inPorts[c] = null;
                    _outPorts[c] = null;
                }
                // Best effort: disconnect under lock when the loop exists.
                bool locked;
                try
                {
                    if (_loop !is null)
                    {
                        pw_thread_loop_lock(_loop);
                        locked = true;
                    }
                    pw_filter_disconnect(_filter);
                    pw_filter_destroy(_filter);
                }
                catch (Exception)
                {
                }
                if (locked && _loop !is null)
                {
                    try
                        pw_thread_loop_unlock(_loop);
                    catch (Exception)
                    {
                    }
                }
                _filter = null;
            }
        }
        catch (Exception)
        {
        }
        try
        {
            if (_loop !is null)
            {
                pw_thread_loop_stop(_loop);
                pw_thread_loop_destroy(_loop);
                _loop = null;
            }
        }
        catch (Exception)
        {
        }
        _state = BackendState.stopped;
    }

    /// Poll filter state/node id from the GUI thread.
    void pollState() nothrow
    {
        if (_filter is null)
            return;
        try
        {
            const(char)* err;
            int st = pw_filter_get_state(_filter, &err);
            if (st == PwFilterState.streaming || st == PwFilterState.paused)
            {
                _state = BackendState.running;
                _nodeId = pw_filter_get_node_id(_filter);
            }
            else if (st == PwFilterState.error)
            {
                _state = BackendState.failed;
                if (err !is null)
                {
                    import std.string : fromStringz;

                    _lastError = fromStringz(err).idup;
                }
                else
                    _lastError = "PipeWire filter error";
            }
        }
        catch (Exception)
        {
        }
    }

    /**
     * Fill per-channel DSP buffer pointers for one block (RT-safe).
     * Returns actual frames (clamped to `maxFrames`).
     */
    uint portBuffers(uint nframes, uint maxFrames, float** ins, float** outs) nothrow @nogc
    {
        if (nframes > maxFrames)
            nframes = maxFrames;
        if (nframes == 0)
            return 0;
        foreach (c; 0 .. _channels)
        {
            if (_inPorts[c] is null || _outPorts[c] is null)
                return 0; // torn down (see stop): degrade to silence
            ins[c] = cast(float*) pw_filter_get_dsp_buffer(_inPorts[c], nframes);
            outs[c] = cast(float*) pw_filter_get_dsp_buffer(_outPorts[c], nframes);
            if (ins[c] is null || outs[c] is null)
                return 0;
        }
        return nframes;
    }

    /// Enumerate capture devices via a registry snapshot (control thread).
    /// Always starts with the "Default source" entry; falls back to just
    /// that when PipeWire is unavailable — UI still starts (spec §3.4).
    AudioDevice[] listSources() nothrow
    {
        AudioDevice[] devs;
        try
        {
            AudioDevice dflt;
            dflt.nodeName = "";
            dflt.displayName = "Default source";
            dflt.isDefault = true;
            devs ~= dflt;

            OvsSource[32] buf;
            int n = ovs_list_sources(buf.ptr, 32);
            if (n > 32)
                n = 32;
            foreach (i; 0 .. (n < 0 ? 0 : n))
            {
                import std.string : fromStringz;

                AudioDevice d;
                d.nodeName = fromStringz(buf[i].nodeName.ptr).idup;
                if (d.nodeName.length == 0)
                    continue;
                string desc = fromStringz(buf[i].description.ptr).idup;
                d.displayName = desc.length > 0 ? desc : d.nodeName;
                d.serial = fromStringz(buf[i].serial.ptr).idup;
                devs ~= d;
            }
        }
        catch (Exception)
        {
        }
        return devs;
    }

    ~this()
    {
        stop();
    }

private:
    // Caller must hold the thread-loop lock.
    bool createFilter(pw_loop* loop, void* enginePtr, string inputNodeName)
    {
        import std.string : toStringz;

        // --- filter properties (node identity, spec §8.3) ---
        auto props = pw_properties_new_string("");
        if (props is null)
        {
            _lastError = "Could not allocate filter properties";
            return false;
        }
        // new_simple takes ownership; on early failure free explicitly.
        bool propsOwned;
        scope (failure)
            if (!propsOwned)
                pw_properties_free(props);

        pw_properties_set(props, PW_KEY_NODE_NAME, VIRTUAL_NODE_NAME.toStringz);
        pw_properties_set(props, PW_KEY_NODE_DESCRIPTION, VIRTUAL_NODE_DESC.toStringz);
        pw_properties_set(props, PW_KEY_MEDIA_TYPE, "Audio".toStringz);
        pw_properties_set(props, PW_KEY_MEDIA_CATEGORY, "Capture".toStringz);
        pw_properties_set(props, PW_KEY_MEDIA_ROLE, "DSP".toStringz);
        pw_properties_set(props, PW_KEY_MEDIA_CLASS, "Audio/Source".toStringz);

        _events = pw_filter_events.init;
        _events.version_ = 1; // PW_VERSION_FILTER_EVENTS
        _events.process = &filterProcess;

        _filter = pw_filter_new_simple(loop, "voice-studio-filter", props, &_events, enginePtr);
        if (_filter is null)
        {
            _lastError = "Could not create PipeWire filter";
            return false;
        }
        propsOwned = true;

        // --- ports, one per channel per direction, each with its own
        // single-channel F32 format pod (built by C shim) ---
        foreach (c; 0 .. _channels)
        {
            import std.format : format;

            uint inSize = ovs_format_dsp(_podIn[c].ptr, cast(uint) _podIn[c].length);
            uint outSize = ovs_format_dsp(_podOut[c].ptr, cast(uint) _podOut[c].length);
            if (inSize == 0 || outSize == 0)
            {
                _lastError = "Could not build audio format description";
                return false;
            }
            const(spa_pod)*[1] inParams = [cast(const(spa_pod)*) _podIn[c].ptr];
            const(spa_pod)*[1] outParams = [cast(const(spa_pod)*) _podOut[c].ptr];

            auto pprops = pw_properties_new_string("");
            if (pprops is null)
            {
                _lastError = "Could not allocate port properties";
                return false;
            }
            string pname = format("input_%d", c);
            pw_properties_set(pprops, PW_KEY_PORT_NAME, pname.toStringz);
            if (inputNodeName.length > 0)
                pw_properties_set(pprops, PW_KEY_TARGET_OBJECT, inputNodeName.toStringz);
            _inPorts[c] = pw_filter_add_port(_filter, PwDirection.input,
                PwFilterPortFlags.mapBuffers, 0, pprops, inParams.ptr, 1);
            if (_inPorts[c] is null)
            {
                _lastError = "Could not add filter input port";
                return false;
            }

            auto oprops = pw_properties_new_string("");
            if (oprops is null)
            {
                _lastError = "Could not allocate port properties";
                return false;
            }
            string oname = format("output_%d", c);
            pw_properties_set(oprops, PW_KEY_PORT_NAME, oname.toStringz);
            // Virtual mic output: DSP format marker for resolvers.
            pw_properties_set(oprops, PW_KEY_FORMAT_DSP, "32 bit float mono audio".toStringz);
            _outPorts[c] = pw_filter_add_port(_filter, PwDirection.output,
                PwFilterPortFlags.mapBuffers, 0, oprops, outParams.ptr, 1);
            if (_outPorts[c] is null)
            {
                _lastError = "Could not add filter output port";
                return false;
            }
        }

        if (pw_filter_connect(_filter, PwFilterFlags.rtProcess, null, 0) < 0)
        {
            _lastError = "Could not connect PipeWire filter (is the PipeWire daemon running?)";
            return false;
        }
        pw_filter_set_active(_filter, true);
        return true;
    }
}
