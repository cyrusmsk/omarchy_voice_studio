/**
 * Omarchy integration: launcher entry, theme watching, Wayland posture.
 *
 * - No X11/Xlib/XCB code anywhere (spec: Wayland through GTK/GDK only).
 * - Wayland-specific code (if ever needed beyond GTK) lives here.
 * - Theme watching polls the state dir mtime (KISS; no GFileMonitor
 *   dependency in the audio path) and is driven from the GTK thread.
 */
module omarchy.integration;

import omarchy.theme : omarchyStateDir, loadPalette, generateCss, OmarchyPalette;
import std.file : exists, timeLastModified, FileException;
import std.datetime : SysTime;

enum string DESKTOP_ID = "com.omarchy.VoiceStudio.desktop";

/// Returns seconds-since-epoch-ish marker for change detection, or 0.
long themeMarker(string stateDir = null)
{
    import omarchy.theme : omarchyStateDir;
    import std.path : buildPath;

    string dir = stateDir is null ? omarchyStateDir() : stateDir;
    string[] candidates = [
        buildPath(dir, "theme.name"),
        buildPath(dir, "colors.toml"),
        buildPath(dir, "theme", "colors.toml"),
    ];
    long latest = 0;
    foreach (c; candidates)
    {
        try
        {
            if (exists(c))
            {
                auto t = timeLastModified(c);
                long u = t.toUnixTime();
                if (u > latest)
                    latest = u;
            }
        }
        catch (Exception)
        {
        }
    }
    return latest;
}

/// Minimal theme watcher: poll from a GTK timeout, reload CSS on change.
final class ThemeWatcher
{
private:
    string _dir;
    long _last;
    void delegate(string cssCss) _onChange;

public:
    this(string dir = null, void delegate(string) onChange = null)
    {
        _dir = dir is null ? omarchyStateDir() : dir;
        _onChange = onChange;
        _last = themeMarker(_dir);
    }

    /// Call periodically from GTK thread. Returns true if theme changed.
    bool poll()
    {
        long m = themeMarker(_dir);
        if (m != _last)
        {
            _last = m;
            if (_onChange !is null)
            {
                try
                {
                    auto pal = loadPalette(_dir);
                    _onChange(generateCss(pal));
                }
                catch (Exception)
                {
                }
            }
            return true;
        }
        return false;
    }
}

unittest
{
    auto w = new ThemeWatcher("/nonexistent-ovs-dir-xyz");
    assert(!w.poll());
}
