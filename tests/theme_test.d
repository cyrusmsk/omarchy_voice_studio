/// Omarchy theme tests: absence never blocks startup (spec §3.4).
module theme_test;

import omarchy.theme;
import omarchy.integration : ThemeWatcher, themeMarker;

unittest
{
    // No Omarchy installed -> defaults, unavailable, valid CSS.
    auto p = loadPalette("/nonexistent-ovs-dir-xyz");
    assert(!p.available);
    assert(generateCss(p).length > 100);

    // Watcher on missing dir never fires, never throws.
    auto w = new ThemeWatcher("/nonexistent-ovs-dir-xyz");
    assert(!w.poll());
    assert(themeMarker("/nonexistent-ovs-dir-xyz") == 0);

    // Legacy + current layouts both resolve (whichever exists).
    assert(omarchyStateDir().length > 0);
}

private import omarchy.theme : omarchyStateDir;
