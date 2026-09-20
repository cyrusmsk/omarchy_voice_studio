# Architecture

## Layout

```
src/
  main.d                 entry point (GUI + --headless + diagnostics)
  audio/
    pipewire_ffi.d       ALL PipeWire FFI lives here (extern(C), ImportC-ready)
    cimports/c_pipewire.h  ImportC wrapper: #include <pipewire/...>
    c_shim.c             real C TU: format pods + source enumeration
    pipewire.d           backend: thread-loop + pw_filter node, graceful errors
    engine.d             control thread: graphs, commands, profile switching
    graph.d              RT DSP core (gains, slots, meters; @nogc nothrow)
    meter.d              RT-safe meter state + dB/severity helpers
    rt_queue.d           lock-free UI→engine command queue
    lv2.d                Lilv discovery/inspection/instantiation + URID map
    denoise.d            RNNoise first stage (dlopen, delay-line framing)
    profile.d            JSON profiles (std.json), XDG persistence
  config/config.d        app id, config.json
  omarchy/
    theme.d              theme.name + colors.toml → GTK CSS
    integration.d        launcher/desktop hooks, theme watcher (no X11)
  ui/
    window.d             AdwNavigationSplitView shell, engine owner, 25 Hz tick
    profile_view.d       sidebar
    plugin_view.d        processing chain
    device_view.d        input/gains/virtual mic + meters
    meter.d              LevelBar wrapper
    scroll.d             scroll-follows-selection helper
    shortcuts.d          Vim-style keymap (pure, tested; never hijacks editing)
    add_plugin_dialog.d  fuzzy LV2 search (spec §12)
    help_dialog.d        keybinding overlay (single-sourced from shortcuts.d)
    save_as_dialog.d     duplicate profile under a new name
    settings_dialog.d    style + backend autostart (spec §24 settings)
resources/css/           static CSS + Omarchy palette hook
lv2/                     vendored mono LV2 bundles (tracked; .so committed)
thirdparty/              plugin sources (x42, zam) — gitignored, rebuildable
docs/                    this file + usage + LV2 plugin guide
data/                    .desktop entry (launcher integration)
systemd/                 user service (headless virtual mic)
tests/                   dub test runner (unit tests live in modules)
```

## PipeWire

- Node API: `pw_filter` (DSP filter with input/output ports), connected
  with `PW_FILTER_FLAG_RT_PROCESS`.
- Virtual source: `node.name=omarchy-voice-studio`,
  `media.class=Audio/Source`, `media.role=DSP`. It never replaces the
  system default; select it explicitly per app.
- Format: F32 planar (wildcard DSP EnumFormat pods built by the C shim —
  the SPA pod builder is header-inline, hence C), native rate/quantum,
  no resampling. Mono and stereo; the UI is mono-only, stereo profiles
  work via hand-written JSON.
- Input routing uses the port `target.object` property; switching input
  or channels reconciles by rebuilding the filter (brief dropout, no
  app restart).
- Device enumeration: registry snapshot in the C shim (own throwaway
  client; `Audio/Source` nodes, self excluded).

## Threads and real-time rules

```
GTK thread --commands--> Engine (control) --publish--> RT filter callback
```

- Graph replacement is atomic at block boundaries; retired graphs (and
  their LV2/RNNoise instances) are freed on the control thread after a
  grace period, never by RT.
- `process()` is `@nogc nothrow`: no allocation, locks, GC, GTK, IO, or
  plugin instantiation. All buffers are preallocated at build time.
- Meters: RT writes plain atomics; GTK polls ~25 Hz.

## LV2 host

- Discovery/inspection/instantiation on the control thread via Lilv;
  identity is always the URI (never bundle paths).
- Host features provided: `urid:map`/`urid:unmap` (process-global table,
  pre-warmed with common extension URIs so RT map calls don't allocate)
  and `options` (block length, sample rate — required by DPF plugins).
- Audio ports ping-pong through scratch buffers; bypass copies the
  signal through. Sidechain inputs tie to silence; atom/event ports get
  a dummy empty buffer — both labelled in the UI, never silent failures.
- Plugins with unsupported port types are marked invalid with the
  reason; the chain keeps working around them.

## RNNoise

Optional first stage per profile (`"denoise": true`), loaded at runtime
via `dlopen("librnnoise.so.0")` — no link dependency; missing library =
inert stage with a UI note. Fixed 480-sample delay line (≈10 ms), exact
sample conservation (proven by unit test), per-channel states, freed on
graph retire. Toggle in the UI under the input section.

## Status

Working end-to-end audio: `pw_filter` node with per-channel DSP ports,
RT processing (RNNoise → input gain → LV2 chain → output gain → meters)
verified bit-exact with a looped 440 Hz tone (+3 dB in / −1 dB out
measured exactly as predicted; EQ shaping measured as modeled). The
virtual `omarchy-voice-studio` source is selectable in any PipeWire app.
