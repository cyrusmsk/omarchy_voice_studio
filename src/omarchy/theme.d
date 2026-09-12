/**
 * Omarchy theme integration (spec §17).
 *
 * - Detects current theme state under ~/.local/state/omarchy/current/
 *   (new) and ~/.config/omarchy/current/ (legacy).
 * - Reads theme.name + colors.toml palette, generates GTK CSS variables.
 * - Missing Omarchy never blocks startup (spec §3.4).
 *
 * colors.toml is parsed with a tiny dependency-free parser (only the
 * palette keys we use).
 */
module omarchy.theme;

import std.file : exists, readText;
import std.path : buildPath;
import std.process : environment;
import std.string : strip, startsWith, endsWith, splitLines, indexOf;
import std.array : array;

struct OmarchyPalette
{
    bool available;
    string themeName = "default";
    string mode = "dark"; // "dark" | "light" from colors.toml
    string background = "#1e1e2e";
    string darkBackground = "#11111b";
    string lighterBackground = "#313244";
    string foreground = "#cdd6f4";
    string brightForeground = "#ffffff";
    string mutedForeground = "#7f849c";
    string accent = "#89b4fa";
    string selection = "#45475a";
    string muted = "#45475a";
    string surface = "#313244";
    string border = "#45475a";
    string success = "#a6e3a1";
    string warning = "#f9e2af";
    string danger = "#f38ba8";
    string orange = "#fab387";
    string cyan = "#89dceb";
    string blue = "#89b4fa";
    string magenta = "#cba6f7";
}

/// Style modes: `system` keeps the desktop GTK/Adwaita style untouched;
/// `omarchy` overlays the live Omarchy palette; `dark`/`light` force the
/// Adwaita appearance while still applying our layout CSS.
enum StyleMode : ubyte
{
    system,
    omarchy,
    dark,
    light,
}

string styleModeName(StyleMode m) pure nothrow @safe
{
    final switch (m)
    {
    case StyleMode.system:
        return "system";
    case StyleMode.omarchy:
        return "omarchy";
    case StyleMode.dark:
        return "dark";
    case StyleMode.light:
        return "light";
    }
}

StyleMode styleModeFromName(string s) pure @safe
{
    switch (s)
    {
    case "omarchy":
        return StyleMode.omarchy;
    case "dark":
        return StyleMode.dark;
    case "light":
        return StyleMode.light;
    default:
        return StyleMode.system;
    }
}

string omarchyStateDir()
{
    string home = environment.get("HOME", "/tmp");
    string cur = buildPath(home, ".local", "state", "omarchy", "current");
    if (exists(cur))
        return cur;
    string legacy = buildPath(home, ".config", "omarchy", "current");
    if (exists(legacy))
        return legacy;
    return cur; // default (may not exist)
}

/// Locate theme dir for tests/injectability.
OmarchyPalette loadPalette(string stateDir = null)
{
    string dir = stateDir is null ? omarchyStateDir() : stateDir;
    OmarchyPalette pal;
    try
    {
        string nameFile = buildPath(dir, "theme.name");
        if (exists(nameFile))
            pal.themeName = readText(nameFile).strip();
        string colorsFile = buildPath(dir, "theme", "colors.toml");
        if (!exists(colorsFile))
            colorsFile = buildPath(dir, "colors.toml");
        if (!exists(colorsFile))
            return pal; // not available, defaults kept
        string text = readText(colorsFile);
        auto kv = parseTomlFlat(text);
        pal.mode = kv.get("mode", pal.mode);
        pal.background = kv.get("background", pal.background);
        pal.darkBackground = kv.get("darker_background", kv.get("dark_background", pal.darkBackground));
        pal.lighterBackground = kv.get("lighter_background", pal.lighterBackground);
        pal.foreground = kv.get("foreground", pal.foreground);
        pal.brightForeground = kv.get("bright_foreground", kv.get("light_foreground", pal.brightForeground));
        pal.mutedForeground = kv.get("dark_foreground", pal.mutedForeground);
        pal.accent = kv.get("accent", pal.accent);
        if ("primary" in kv)
            pal.accent = kv["primary"];
        pal.selection = kv.get("selection", pal.selection);
        pal.muted = kv.get("muted", pal.muted);
        pal.surface = kv.get("surface", pal.lighterBackground);
        pal.border = kv.get("border", pal.muted);
        pal.success = kv.get("success", pal.success);
        if ("green" in kv)
            pal.success = kv["green"];
        if ("bright_green" in kv)
            pal.success = kv["bright_green"];
        pal.warning = kv.get("warning", pal.warning);
        if ("yellow" in kv)
            pal.warning = kv["yellow"];
        pal.danger = kv.get("danger", pal.danger);
        if ("red" in kv)
            pal.danger = kv["red"];
        pal.orange = kv.get("orange", pal.orange);
        pal.cyan = kv.get("cyan", pal.cyan);
        if ("bright_cyan" in kv)
            pal.cyan = kv["bright_cyan"];
        pal.blue = kv.get("blue", pal.accent);
        pal.magenta = kv.get("magenta", pal.magenta);
        if ("bright_magenta" in kv)
            pal.magenta = kv["bright_magenta"];
        pal.available = true;
    }
    catch (Exception)
    {
    }
    return pal;
}

string[string] parseTomlFlat(string text)
{
    string[string] kv;
    foreach (line; text.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0 || t[0] == '#' || t[0] == '[')
            continue;
        auto eq = t.indexOf('=');
        if (eq < 0)
            continue;
        string key = t[0 .. eq].strip();
        string val = t[eq + 1 .. $].strip();
        // Quoted value: take everything up to the matching close quote
        // (hex colors contain '#' so comment-stripping must not run first).
        if (val.length >= 2 && (val[0] == '"' || val[0] == '\''))
        {
            char q = val[0];
            auto end = val.indexOf(q, 1);
            if (end >= 1)
                val = val[1 .. end];
            else
                val = val[1 .. $];
        }
        else
        {
            // Bare value: strip trailing comment, then stray quotes.
            auto hash = val.indexOf('#');
            if (hash >= 0)
                val = val[0 .. hash].strip();
            if (val.length >= 2 && ((val[0] == '"' && val[$ - 1] == '"') || (val[0] == '\'' && val[$ - 1] == '\'')))
                val = val[1 .. $ - 1];
        }
        kv[key] = val;
    }
    return kv;
}

/// Generate GTK CSS applying the Omarchy palette + meter severity classes.
///
/// Layout/typography only enhance; colors follow the theme. In `system`
/// mode this CSS is not loaded at all — the desktop Adwaita style rules.
string generateCss(const OmarchyPalette pal)
{
    import std.format : format;

    return format!(
        "@define-color ovs_bg %s;\n" ~
        "@define-color ovs_bg_dark %s;\n" ~
        "@define-color ovs_fg %s;\n" ~
        "@define-color ovs_fg_bright %s;\n" ~
        "@define-color ovs_fg_muted %s;\n" ~
        "@define-color ovs_accent %s;\n" ~
        "@define-color ovs_select %s;\n" ~
        "@define-color ovs_surface %s;\n" ~
        "@define-color ovs_border %s;\n" ~
        "window { background-color: @ovs_bg; color: @ovs_fg; }\n" ~
        "headerbar { background-color: @ovs_bg_dark; color: @ovs_fg_bright; border-color: @ovs_border; }\n" ~
        "headerbar label { color: @ovs_fg_bright; }\n" ~
        "list row { border-radius: 8px; }\n" ~
        "list row:selected { background-color: @ovs_select; color: @ovs_fg_bright; }\n" ~
        "list row:selected label { color: @ovs_fg_bright; }\n" ~
        "entry, search { background-color: @ovs_bg_dark; color: @ovs_fg; border-color: @ovs_border; }\n" ~
        "button { border-color: @ovs_border; }\n" ~
        "button.suggested-action { background-color: @ovs_accent; color: @ovs_bg_dark; }\n" ~
        "checkbutton check:checked { background-color: @ovs_accent; border-color: @ovs_accent; }\n" ~
        "scale highlight { background-color: @ovs_accent; }\n" ~
        "scale slider { border-color: @ovs_accent; }\n" ~
        "switch:checked { background-color: @ovs_accent; }\n" ~
        "levelbar trough { background-color: @ovs_bg_dark; border-color: @ovs_border; }\n" ~
        ".ovs-meter.normal trough > fill { background: %s; }\n" ~
        ".ovs-meter.healthy trough > fill { background: %s; }\n" ~
        ".ovs-meter.warning trough > fill { background: %s; }\n" ~
        ".ovs-meter.danger trough > fill { background: %s; }\n" ~
        ".ovs-status-running { color: %s; font-weight: bold; }\n" ~
        ".ovs-dim { color: @ovs_fg_muted; }\n")(
        pal.background, pal.darkBackground, pal.foreground, pal.brightForeground,
        pal.mutedForeground, pal.accent, pal.selection, pal.surface, pal.border,
        pal.mutedForeground, pal.success, pal.warning, pal.danger, pal.success);
}

/// Static layout CSS (no colors): applied in every style mode so meters,
/// rows and status classes render even under the plain system style.
/// Mirrors resources/css/application.css (kept for packaging).
string layoutCss() pure @safe
{
    return
        "window { font-family: \"Inter\", \"Cantarell\", sans-serif; }\n" ~
        ".ovs-meter { min-height: 10px; border-radius: 6px; }\n" ~
        ".ovs-meter trough { min-height: 10px; border-radius: 6px; }\n" ~
        ".ovs-meter trough > fill { border-radius: 6px; transition: none; }\n" ~
        ".ovs-meter.danger trough > fill { animation: none; }\n" ~
        ".ovs-status-running { font-weight: bold; }\n" ~
        ".ovs-sidebar row { padding: 6px 10px; border-radius: 8px; }\n" ~
        ".ovs-chain row { padding: 8px; border-radius: 8px; }\n" ~
        ".ovs-keys { font-family: monospace; font-weight: bold; }\n";
}

unittest
{
    auto kv = parseTomlFlat("[theme]\nbackground = \"#111111\" # dark\naccent='#22aa22'\n");
    assert(kv["background"] == "#111111");
    assert(kv["accent"] == "#22aa22");

    OmarchyPalette p;
    p.accent = "#123456";
    string css = generateCss(p);
    assert(css.length > 50);
    assert(styleModeFromName("dark") == StyleMode.dark);
    assert(styleModeName(StyleMode.system) == "system");

    // Missing dir => unavailable but no throw.
    auto q = loadPalette("/nonexistent-ovs-dir-xyz");
    assert(!q.available);
}
