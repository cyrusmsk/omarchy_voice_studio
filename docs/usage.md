# Usage

Omarchy Voice Studio takes your physical microphone, processes it
(RNNoise → gain → LV2 chain → gain) and exposes the result as a virtual
PipeWire source named `omarchy-voice-studio`. Pick that source as the
input in OBS, Discord, your browser, or `pavucontrol` / `qpwgraph`. The
app never replaces your system default microphone.

## First run

```sh
dub run --compiler=ldc2
```

Three profiles are seeded on first run (only when no profiles exist —
your profiles are never overwritten):

| Profile | Chain | For |
|---|---|---|
| Broadcast | clean pass-through | starting point |
| Podcast | RNNoise → x42 fil4 EQ → ZamComp → x42 dpl limiter | spoken word |
| Discord Gaming | RNNoise → ZamGate → fil4 → dpl | keyboard clacks, shouts |

Profiles live in `~/.config/omarchy-voice-studio/profiles/*.json`
(`$XDG_CONFIG_HOME` respected). Edit by hand if you like — invalid files
are skipped, never crash the app.

## Daily use

1. Pick a profile in the sidebar (`j`/`k`, `Enter`).
2. Pick the input mic from the enumerated PipeWire sources
   (`--list-sources` shows the same list). Switching rewires capture
   without restarting the app. `Omarchy Voice Studio` appears in other
   apps.
3. Mono is the only channel mode in the UI (microphones are mono; the
   engine still honors `"channelMode": "stereo"` in hand-written JSON
   profiles, rebuilding the virtual mic ports live). A plugin added to
   the wrong channel layout says exactly what it needs.
4. Tune sliders (`i` shows the selected plugin's URI and port count).
   `Ctrl+S` saves, `Ctrl+Shift+S` saves a copy under a new name,
   control drags autosave every few seconds. `s` opens settings
   (style, backend autostart, backend status).
5. `t` cycles style: system → omarchy → dark → light.
6. `h` shows every keybinding; lists scroll to follow `j`/`k`.

Headless (for the systemd user service):

```sh
omarchy-voice-studio --headless --profile=discord
```

Useful diagnostics:

```sh
omarchy-voice-studio --list-lv2          # what Lilv sees (by URI)
omarchy-voice-studio --check-plugin=URI  # ports, ranges, instantiation
```

## Chain order and bypass

Signal flows top to bottom through the Processing chain list: `↑`/`↓`
(or `J`/`K`) reorder, `●`/`Space`/`b` bypasses, `✕`/`x` removes, `r`
resets a plugin to its defaults. Bypassed plugins pass audio through
unchanged. Switching profiles rebuilds the graph off the audio thread —
if the new chain fails, the old one keeps running and you get an error
instead of silence.

## Meters

Input/output bars update ~25 times a second with a clip latch:
below −18 dBFS is quiet, −18…−6 healthy, −6…−1 hot, above −1 clips and
the bar goes red. If the output clips, lower output gain or lean on the
dpl limiter (threshold −1 dB is a sane ceiling).
