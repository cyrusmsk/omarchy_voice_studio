# Omarchy Voice Studio

> Your processed microphone, everywhere.

Native GTK4 voice-processing studio for Omarchy (Arch Linux / Wayland).
Takes a physical microphone, runs it through a configurable chain
(input gain → LV2 plugins → output gain), and exposes the processed
signal as a **virtual PipeWire microphone** selectable in OBS, Discord,
browsers, and other apps.

Primary language: **D** (DUB, LDC). UI: GTK4 + libadwaita via
[gid](https://gid.dub.pm). Audio: native **PipeWire C API**
(`pw_filter` DSP node) bound through a small `extern(C)` + ImportC-ready
FFI layer in `src/audio/pipewire_ffi.d` (+ `src/audio/c_shim.c`, a real
C99 translation unit against `<pipewire/pipewire.h>`). LV2 via Lilv.
No Electron, no web tech, no GStreamer in the audio path.

## Layout

```
src/
  main.d                 entry point (GUI + --headless)
  audio/
    pipewire_ffi.d       ALL PipeWire FFI lives here (extern(C), ImportC-ready)
    cimports/c_pipewire.h  ImportC wrapper: #include <pipewire/...>
    c_shim.c             real C TU proving C-API usage (cc or ImportC)
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
    shortcuts.d          Vim-style keymap (pure, tested; never hijacks editing)
    add_plugin_dialog.d  fuzzy LV2 search (spec §12)
    help_dialog.d        keybinding overlay (single-sourced from shortcuts.d)
    save_as_dialog.d     duplicate profile under a new name
    settings_dialog.d    style + backend autostart (spec §24 settings)
resources/css/           static CSS + Omarchy palette hook
lv2/                     vendored mono LV2 bundles (fil4, dpl, Zam suite)
thirdparty/              plugin sources (x42, zam) for reproducible rebuilds
docs/                    usage + LV2 plugin guide (Omarchy-flavored markdown)
data/                    .desktop entry (launcher integration)
systemd/                 user service (headless virtual mic)
tests/                   dub test runner (unit tests live in modules)
```

## Build

```sh
# install deps (Arch): gtk4 libadwaita pipewire lilv lv2 ldc dub
dub build --compiler=ldc2
dub test --compiler=ldc2
dub run --compiler=ldc2
dub run --compiler=ldc2 -- --headless --profile=broadcast
```

Optional: build the C proof TU directly against PipeWire:

```sh
cc -c src/audio/c_shim.c $(pkg-config --cflags libpipewire-0.3) -o /tmp/c_shim.o
```

## PipeWire notes

- Preferred node API: `pw_filter` (DSP filter with input/output ports).
- Virtual source: `node.name=omarchy-voice-studio`,
  `media.class=Audio/Source`, `media.role=DSP`. It never replaces the
  system default; select it explicitly per app.
- MVP audio format: F32, native rate/quantum, mono + stereo, no resampling.
- RT rules: no allocation/GC/locks/GTK/IO/LV2-instantiation in `process()`.

## Keyboard

`j/k` + arrows move in the focused list, `l`/`Left`/`Right` move focus
profiles → inputs → chain, `Enter`/`Space` activates (select profile /
input, bypass slot), `/` opens plugin search, `n` new profile,
`d` deletes the selected profile, `a` add plugin, `x` remove slot,
`J/K` move slot, `b` bypass, `r` reset slot to defaults, `i` plugin info,
`s` settings, `t` cycles style, `Ctrl+S` save, `Ctrl+Shift+S` save as.
Text fields always keep native GTK editing. The Add dialog: `Esc`/`q` closes, `Return` adds.

## Style

System style is the default (untouched Adwaita, follows
`prefer-dark`). Press `t` to cycle: system → omarchy → dark → light.
Omarchy mode overlays the live palette from
`~/.local/state/omarchy/current` (theme.name + colors.toml) and reloads
on theme switch without restart. Choice persists in config.json.

## CLI

```sh
dub run --compiler=ldc2 -- --headless --profile=broadcast  # service mode
dub run --compiler=ldc2 -- --list-lv2                      # LV2 discovery
dub run --compiler=ldc2 -- --check-plugin=URI              # inspect+instantiate
```

## Bundled LV2 suite (`lv2/`)

Built from source into the project (no root needed); the app prepends
`<exe-dir>/lv2` (and `./lv2` for `dub run`) to `LV2_PATH`, so vendored
bundles win without system installation. Discovery is always by URI —
never paths (spec §3.3).

| Stage | Plugin | URI |
|---|---|---|
| EQ | x42 fil4 (mono/stereo) | `http://gareus.org/oss/lv2/fil4#mono` / `#stereo` |
| Limiter | x42 dpl (mono/stereo) | `http://gareus.org/oss/lv2/dpl#mono` / `#stereo` |
| Gate | ZamGate / ZamGateX2 | `urn:zamaudio:ZamGate[X2]` |
| Compressor | ZamComp / ZamCompX2 | `urn:zamaudio:ZamComp[X2]` |

Sources live in `thirdparty/` (x42-plugins, zam-plugins). Rebuild after
pulling with e.g. `make -C thirdparty/x42-plugins/fil4.lv2
BUILDOPENGL=no BUILDJACKAPP=no RW=$PWD/thirdparty/x42-plugins/robtk/`
and copy the bundle (`.so` + `.ttl` + `manifest.ttl`) into `lv2/`.

Want the Calf deesser (or LSP)? `sudo pacman -S calf lsp-plugins-lv2`
— the app discovers system LV2 automatically via Lilv. (Calf needs
cmake + GTK2 to build from source, so a system package is the sane
route there.)

Suggested voice chain: RNNoise → fil4 (HPF 70–100 Hz, −2..−4 dB @
200–300 Hz, +1..3 dB @ 2–4 kHz) → compressor → de-esser → dpl
(threshold −1 dB, release ~100 ms).

## Noise suppression (RNNoise)

Optional first stage per profile (`"denoise": true`), loaded at runtime
via `dlopen("librnnoise.so.0")` — no link dependency; missing library =
inert stage with a UI note. Fixed 480-sample delay line (≈10 ms), exact
sample conservation (proven by unit test), per-channel states, freed on
graph retire. Toggle in the UI under the input section.

## Status

Working end-to-end audio: `pw_filter` node with per-channel DSP ports
(wildcard DSP-format pods built by the C shim), RT processing
(input gain → LV2 chain → output gain → meters) verified bit-exact with a
looped 440 Hz tone (+3 dB in / −1 dB out measured exactly as predicted),
LV2 instantiate + port wiring with safe retire/reap, generic control
widgets (slider/toggle/integer/enumeration from Lilv metadata), fuzzy
Add Plugin dialog, profiles with debounced autosave, Omarchy theme
following, launcher + systemd integration. The virtual
`omarchy-voice-studio` source is selectable in any PipeWire app.
