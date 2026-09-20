# Vendored LV2 plugins

Prebuilt mono bundles, committed so the app works out of the box (it
prepends this directory to `LV2_PATH`). Each plugin is the work of its
upstream author under its own GPL license — see the per-bundle `COPYING`
in `lv2/` and the DPF notice in [upstream-NOTICE.DPF](upstream-NOTICE.DPF).
These binaries are *plugins*, not linked code: the D application (MIT)
loads them at runtime through Lilv.

| Bundle | Plugin | Upstream | License |
|---|---|---|---|
| `fil4.lv2` | x42-eq Parametric Equalizer | github.com/x42/fil4.lv2 | GPL-2.0 |
| `dpl.lv2` | x42-dpl Peak Limiter | github.com/x42/dpl.lv2 | GPL-3.0 |
| `ZamGate.lv2` | ZamGate | github.com/zamaudio/zam-plugins | GPL-2.0+ |
| `ZamComp.lv2` | ZamComp | github.com/zamaudio/zam-plugins | GPL-2.0+ |
| `ZamDynamicEQ.lv2` | ZamDynamicEQ | github.com/zamaudio/zam-plugins | GPL-2.0+ |
| `ZaMultiComp.lv2` | ZaMultiComp | github.com/zamaudio/zam-plugins | GPL-2.0+ |

Stereo and "X2" variants are intentionally excluded (microphones are
mono); upstream sources in `thirdparty/` are gitignored — the x42 ones
were built with `BUILDOPENGL=no BUILDJACKAPP=no` against shared robtk,
zam-plugins with the stock `make` after `git submodule update --init`.
Full recipes: [lv2-plugins.md](lv2-plugins.md). These attribution notes
live in `docs/`, not `lv2/`, so the search path contains only bundles.

Note: `*_ui.so` files ship unused (the app renders controls from
metadata) but stay because bundles must remain complete for external
LV2 hosts.
