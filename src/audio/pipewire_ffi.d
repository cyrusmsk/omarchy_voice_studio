/**
 * PipeWire FFI — minimal, hand-maintained extern(C) bindings.
 *
 * Strategy (per spec §8.2 + project requirement "use C API with importC"):
 *
 *  - The authoritative API is the PipeWire C API
 *    (<pipewire/pipewire.h>, <pipewire/filter.h>, <pipewire/thread-loop.h>,
 *     <spa/param/audio/format-utils.h>).
 *  - Where the toolchain supports D ImportC, these declarations can be
 *    mechanically replaced by importing the C headers directly, e.g.:
 *
 *        // ImportC path (LDC >= 1.35 / DMD >= 2.107):
 *        //   import c_pipewire;  // from cimports/c_pipewire.h
 *
 *    See `src/audio/cimports/` for the ImportC-ready C wrapper headers and
 *    `src/audio/c_shim.c` for a C translation unit compiled with the real
 *    C compiler against the real PipeWire headers. The shim builds SPA
 *    format pods (header-inline builder API, not linkable from D) and is
 *    linked into the binary via dub preBuildCommands.
 *  - ABI is verified against PipeWire 1.x headers. All FFI stays in this
 *    file; the rest of the app goes through `audio.pipewire`.
 */
module audio.pipewire_ffi;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdint : int32_t, uint32_t, uint64_t, int64_t;

// ---------------------------------------------------------------------------
// Opaque PipeWire types
// ---------------------------------------------------------------------------

extern (C) struct pw_thread_loop;
extern (C) struct pw_filter;
extern (C) struct pw_properties;
extern (C) struct pw_loop;
extern (C) struct spa_hook;
extern (C) struct spa_pod;

// ---------------------------------------------------------------------------
// Direction / flags (pipewire/port.h, pipewire/filter.h)
// ---------------------------------------------------------------------------

enum PwDirection : int
{
    input = 0,
    output = 1,
}

enum PwFilterFlags : uint
{
    none = 0,
    inactive = (1 << 0),
    driver = (1 << 1),
    rtProcess = (1 << 2),
}

enum PwFilterState : int
{
    unconnected = 0,
    connecting = 1,
    paused = 2,
    streaming = 3,
    error = -1,
}

enum PwFilterPortFlags : uint
{
    none = 0,
    mapBuffers = (1 << 0),
}

// ---------------------------------------------------------------------------
// Property keys (pipewire/keys.h) — string content is the ABI.
// ---------------------------------------------------------------------------

enum PW_KEY_NODE_NAME = "node.name";
enum PW_KEY_NODE_DESCRIPTION = "node.description";
enum PW_KEY_MEDIA_TYPE = "media.type";
enum PW_KEY_MEDIA_CATEGORY = "media.category";
enum PW_KEY_MEDIA_ROLE = "media.role";
enum PW_KEY_MEDIA_CLASS = "media.class";
enum PW_KEY_TARGET_OBJECT = "target.object";
enum PW_KEY_PORT_NAME = "port.name";
enum PW_KEY_FORMAT_DSP = "format.dsp";
enum PW_KEY_AUDIO_CHANNELS = "audio.channels";
enum PW_KEY_AUDIO_RATE = "audio.rate";
enum PW_KEY_AUDIO_FORMAT = "audio.format";

// ---------------------------------------------------------------------------
// Minimal spa_io_position view (spa/node/io.h).
// Only clock.duration (cycle length in samples) is read by the RT path.
// Layout: flags u32, id u32, name char[64], nsec u64, rate u32x2,
//         position u64, duration u64, ...
// ---------------------------------------------------------------------------

extern (C) struct SpaIoClockHead
{
    uint32_t flags;
    uint32_t id;
    char[64] name;
    uint64_t nsec;
    uint32_t rateNum;
    uint32_t rateDenom;
    uint64_t position;
    uint64_t duration; // <- cycle length in samples
}

extern (C) struct SpaIoPosition
{
    SpaIoClockHead clock;
}

// ---------------------------------------------------------------------------
// Filter events — MUST match struct pw_filter_events field order.
// ---------------------------------------------------------------------------

extern (C) struct pw_filter_events
{
    uint32_t version_;
    void function(void* data) nothrow @nogc destroy;
    void function(void* data, int oldState, int state, const(char)* error) nothrow @nogc stateChanged;
    void function(void* data, void* portData, uint32_t id, void* area, uint32_t size) nothrow @nogc ioChanged;
    void function(void* data, void* portData, uint32_t id, const(spa_pod)* param) nothrow @nogc paramChanged;
    void function(void* data, void* portData, void* buffer) nothrow @nogc addBuffer;
    void function(void* data, void* portData, void* buffer) nothrow @nogc removeBuffer;
    void function(void* data, SpaIoPosition* position) nothrow @nogc process;
    void function(void* data) nothrow @nogc drained;
    void function(void* data, const(void)* command) nothrow @nogc command;
}

// ---------------------------------------------------------------------------
// Core lifecycle
// ---------------------------------------------------------------------------

extern (C) nothrow @nogc:
void pw_init(int* argc, char*** argv);
void pw_deinit();
const(char)* pw_get_library_version();

// ---------------------------------------------------------------------------
// Thread loop
// ---------------------------------------------------------------------------

pw_thread_loop* pw_thread_loop_new(const(char)* name, void* props);
void pw_thread_loop_destroy(pw_thread_loop* loop);
void pw_thread_loop_start(pw_thread_loop* loop);
void pw_thread_loop_stop(pw_thread_loop* loop);
pw_loop* pw_thread_loop_get_loop(pw_thread_loop* loop);
void pw_thread_loop_lock(pw_thread_loop* loop);
void pw_thread_loop_unlock(pw_thread_loop* loop);

// ---------------------------------------------------------------------------
// Properties (varargs constructor avoided; build via new_string + set)
// ---------------------------------------------------------------------------

pw_properties* pw_properties_new_string(const(char)* args);
int pw_properties_set(pw_properties* properties, const(char)* key, const(char)* value);
void pw_properties_free(pw_properties* properties);

// ---------------------------------------------------------------------------
// Filter — signatures verified against pipewire/filter.h (1.x)
// ---------------------------------------------------------------------------

pw_filter* pw_filter_new_simple(
    pw_loop* loop,
    const(char)* name,
    pw_properties* filter_props,
    const(pw_filter_events)* events,
    void* data);

void pw_filter_destroy(pw_filter* filter);
int pw_filter_connect(pw_filter* filter, uint32_t flags, const(spa_pod)** params, uint32_t n_params);
int pw_filter_disconnect(pw_filter* filter);
uint32_t pw_filter_get_node_id(pw_filter* filter);
int pw_filter_get_state(pw_filter* filter, const(char)** error);
int pw_filter_set_active(pw_filter* filter, bool active);

// Returns port_data (opaque per-port user area).
void* pw_filter_add_port(
    pw_filter* filter,
    int direction,
    uint32_t port_flags,
    size_t port_data_size,
    pw_properties* props,
    const(spa_pod)** params,
    uint32_t n_params);

int pw_filter_remove_port(void* port_data);

// DSP buffer for a port (RT-safe). Returns float samples for audio ports.
void* pw_filter_get_dsp_buffer(void* port_data, uint32_t n_samples);

// ---------------------------------------------------------------------------
// C shim (src/audio/c_shim.c) — compiled with cc against PipeWire headers.
// Builds SPA EnumFormat pods (builder API is header-inline, hence C) and
// snapshots Audio/Source nodes (registry listeners are C-natural).
// ---------------------------------------------------------------------------

/// Build an EnumFormat pod for DSP audio (planar float, graph-native rate,
/// wildcard format) into `buf` (capacity `cap`). Returns pod size in bytes,
/// or 0 on error.
uint32_t ovs_format_dsp(void* buf, uint32_t cap);

/// Source snapshot entry. Layout mirrors struct ovs_source in c_shim.c.
extern (C) struct OvsSource
{
    uint32_t id;
    char[128] nodeName;
    char[256] description;
    char[64] serial;
}

/// Fill `out_` (capacity `cap`) with Audio/Source nodes. Returns entry
/// count, or -1 when the daemon is unreachable. Control thread only.
int ovs_list_sources(OvsSource* out_, int cap);
