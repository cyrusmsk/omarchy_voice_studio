# LV2 plugins

The app discovers LV2 plugins through Lilv, by URI — never by path.
Anything Lilv can see, the Add dialog (`a` or `/`) can add: search by
name, vendor, or URI, `Enter` to add. Unsupported plugins (odd channel
layouts, CV ports) are labelled, never silently adapted.

## Shipped suite (`lv2/`)

Built from source in `thirdparty/` (no root needed) and auto-found via
`LV2_PATH`:

| Stage | Bundle | URIs |
|---|---|---|
| EQ | x42 fil4 | `http://gareus.org/oss/lv2/fil4#mono` |
| Limiter | x42 dpl | `http://gareus.org/oss/lv2/dpl#mono` |
| Gate | ZamGate | `urn:zamaudio:ZamGate` |
| Compressor | ZamComp | `urn:zamaudio:ZamComp` |
| Dynamic EQ / de-esser | ZamDynamicEQ | `urn:zamaudio:ZamDynamicEQ` |
| Multiband dynamics | ZaMultiComp | `urn:zamaudio:ZaMultiComp` |

Mono only, on purpose: microphones are mono, stereo doubles DSP cost
for no voice benefit, and upstream doesn't even ship every plugin in
stereo (there is no `ZamDynamicEQX2`). The engine still accepts stereo
chains for loopback/capture-mix sources — system LV2 with stereo ports
works the same way.

No dedicated de-esser plugin ships: use ZamDynamicEQ as one — a narrow
dynamic cut at 5–8 kHz tames sibilance (fast attack, medium release).
The Calf deesser remains one `sudo pacman -S calf` away (see below).

Sidechain inputs are tied to silence and labelled; x42 message ports
(`control`/`notify`) stay inert and labelled. Verify a plugin with:

```sh
omarchy-voice-studio --check-plugin=http://gareus.org/oss/lv2/fil4#mono
```

## Adding more plugins

1. **System packages (easiest).** Anything installed to the standard
   LV2 paths is discovered automatically. On Arch/Omarchy:

   ```sh
   sudo pacman -S calf lsp-plugins-lv2
   ```

   This gets you the Calf deesser/compressor/gate/limiter and the full
   LSP suite (including gates). Rebuilding from source is not
   recommended here: Calf needs cmake + GTK2 + FluidSynth.

2. **Vendored bundles (this repo's way).** Build the plugin, then drop
   the bundle directory (`.so` + `.ttl` files + `manifest.ttl`) into
   this repo's `lv2/`:

   ```sh
   cp -r /path/to/built/MyPlugin.lv2 lv2/
   omarchy-voice-studio --list-lv2   # confirm the URI shows up
   ```

   The x42 recipe used for fil4/dpl:

   ```sh
   make -C thirdparty/x42-plugins/fil4.lv2 BUILDOPENGL=no BUILDJACKAPP=no \
     RW=$PWD/thirdparty/x42-plugins/robtk/
   cp thirdparty/x42-plugins/fil4.lv2/build/fil4.{so,ttl} \
      thirdparty/x42-plugins/fil4.lv2/build/manifest.ttl lv2/fil4.lv2/
   ```

3. **Write the profile.** Add the URI to a profile's `plugins` array
   with control values keyed by LV2 *symbol* (see
   `--check-plugin=URI` for exact symbols, ranges, and defaults):

   ```json
   {"uri": "http://gareus.org/oss/lv2/fil4#mono", "enabled": true,
    "controls": {"HighPass": 1.0, "HPfreq": 80.0, "gain1": -3.0}}
   ```

   Unknown symbols are ignored at build (defaults win); out-of-range
   values are clamped. A plugin that vanished from the system marks its
   slot unsupported — audio keeps flowing around it.

## Requirements for a plugin to work here

- Mono/stereo audio in/out (extra sidechain inputs are silenced).
- Audio + control + atom/event ports only (no CV).
- No required LV2 features beyond `urid:map`, `urid:unmap`, `options`
  (all provided by the host), and no worker-thread scheduling.
