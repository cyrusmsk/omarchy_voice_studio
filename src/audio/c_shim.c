/* PipeWire C helpers for Omarchy Voice Studio.
 *
 * Plain C99 against the real PipeWire/SPA C API. Compiled with cc via dub
 * preBuildCommands and linked into the D binary (see dub.sdl). Also
 * compilable in D ImportC mode (`ldc2 -c c_shim.c`).
 *
 * Why C: SPA pod building (spa_pod_builder_*, spa_format_audio_raw_build)
 * is a header-inline API — not exported from libpipewire — so D cannot link
 * it. The registry snapshot below likewise stays in C where the listener
 * structs are natural. D owns all policy (gains, graphs, profiles); C only
 * builds bytes and snapshots.
 */
#include <stdint.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <pipewire/main-loop.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/dsp-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/dict.h>

/* Keep the original minimal helpers (C-API proof + D fallback path). */
static int g_initialized = 0;

int ovs_pw_init_once(void) {
    if (g_initialized)
        return 1;
    pw_init(NULL, NULL);
    g_initialized = 1;
    return 1;
}

const char *ovs_pw_version(void) {
    return pw_get_library_version();
}

int ovs_pw_available(void) {
    return 1;
}

/* Build an EnumFormat pod for DSP audio for ONE filter port.
 * Filter DSP ports carry planar float (F32P) with the graph-native rate;
 * the format field is left wildcard (UNKNOWN) so any converter-accepted
 * DSP format negotiates. Buffers from pw_filter_get_dsp_buffer() are
 * always float samples in this mode.
 * Returns pod bytes written, or 0 on error. */
uint32_t ovs_format_dsp(void *buf, uint32_t cap) {
    struct spa_pod_builder b;
    spa_pod_builder_init(&b, buf, cap);

    struct spa_audio_info_dsp info;
    info.format = SPA_AUDIO_FORMAT_UNKNOWN;

    const struct spa_pod *pod =
        spa_format_audio_dsp_build(&b, SPA_PARAM_EnumFormat, &info);

    if (pod == NULL)
        return 0;
    /* Buffer started empty, so the builder state offset is the pod size. */
    return b.state.offset;
}

/* ---- PipeWire source enumeration (spec §8.4) ----
 * Snapshot of Audio/Source nodes via a throwaway client connection.
 * Runs its own main loop on the calling (control) thread; never touches
 * the engine's thread loop. Layout matches audio.pipewire_ffi.OvsSource. */

#define OVS_MAX_SOURCES 32

struct ovs_source {
    uint32_t id;
    char node_name[128];
    char description[256];
    char serial[64];
};

struct ovs_enum_ctx {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook core_listener;
    struct spa_hook registry_listener;
    struct ovs_source out[OVS_MAX_SOURCES];
    int count;
    int sync_seq;
    int done;
};

static void ovs_copy_str(char *dst, size_t cap, const char *src) {
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

static void ovs_on_registry_global(void *data, uint32_t id,
        uint32_t permissions, const char *type, uint32_t version,
        const struct spa_dict *props) {
    struct ovs_enum_ctx *ctx = data;
    (void)permissions; (void)version;
    if (ctx->count >= OVS_MAX_SOURCES)
        return;
    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
        return;
    const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (cls == NULL || strcmp(cls, "Audio/Source") != 0)
        return;
    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (name == NULL)
        return;
    if (strcmp(name, "omarchy-voice-studio") == 0)
        return; /* never list ourselves as an input */
    struct ovs_source *s = &ctx->out[ctx->count++];
    s->id = id;
    ovs_copy_str(s->node_name, sizeof(s->node_name), name);
    ovs_copy_str(s->description, sizeof(s->description),
            spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION));
    ovs_copy_str(s->serial, sizeof(s->serial),
            spa_dict_lookup(props, "object.serial"));
}

static void ovs_on_core_done(void *data, uint32_t id, int seq) {
    struct ovs_enum_ctx *ctx = data;
    (void)id;
    if (seq == ctx->sync_seq) {
        ctx->done = 1;
        pw_main_loop_quit(ctx->loop);
    }
}

static const struct pw_registry_events ovs_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = ovs_on_registry_global,
};

static const struct pw_core_events ovs_core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = ovs_on_core_done,
};

/* Fills `out` (capacity `cap` entries). Returns entry count, or -1 when
 * the daemon is unreachable. Never crashes the caller. */
int ovs_list_sources(struct ovs_source *out, int cap) {
    struct ovs_enum_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (cap <= 0 || out == NULL)
        return -1;

    ovs_pw_init_once();

    ctx.loop = pw_main_loop_new(NULL);
    if (ctx.loop == NULL)
        return -1;
    ctx.context = pw_context_new(pw_main_loop_get_loop(ctx.loop), NULL, 0);
    if (ctx.context == NULL) {
        pw_main_loop_destroy(ctx.loop);
        return -1;
    }
    ctx.core = pw_context_connect(ctx.context, NULL, 0);
    if (ctx.core == NULL) {
        pw_context_destroy(ctx.context);
        pw_main_loop_destroy(ctx.loop);
        return -1;
    }
    ctx.registry = pw_core_get_registry(ctx.core, PW_VERSION_REGISTRY, 0);
    if (ctx.registry == NULL) {
        pw_core_disconnect(ctx.core);
        pw_context_destroy(ctx.context);
        pw_main_loop_destroy(ctx.loop);
        return -1;
    }
    pw_registry_add_listener(ctx.registry, &ctx.registry_listener,
            &ovs_registry_events, &ctx);
    pw_core_add_listener(ctx.core, &ctx.core_listener, &ovs_core_events, &ctx);
    ctx.sync_seq = pw_core_sync(ctx.core, PW_ID_CORE, 0);
    pw_main_loop_run(ctx.loop);

    int n = ctx.count < cap ? ctx.count : cap;
    memcpy(out, ctx.out, (size_t)n * sizeof(struct ovs_source));

    pw_core_disconnect(ctx.core);
    pw_context_destroy(ctx.context);
    pw_main_loop_destroy(ctx.loop);
    return n;
}
