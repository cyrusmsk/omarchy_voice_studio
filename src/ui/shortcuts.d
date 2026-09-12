/**
 * Keyboard-first navigation (spec §23).
 *
 * Design: the window installs a GtkEventControllerKey and forwards key
 * presses to `mapKey()`. When focus is inside a text-editing widget
 * (GtkEditable / entry / search), normal GTK text editing takes precedence
 * and we return NoMatch so the event propagates.
 *
 * This module is pure logic (no GTK objects) so it is unit-testable.
 */
module ui.shortcuts;

/// Actions the window implements.
enum VimAction : ubyte
{
    none,
    nextItem, // j / Down
    prevItem, // k / Up
    prevPane, // Left (h opens help)
    nextPane, // l / Right
    activate, // Enter
    toggle, // Space
    close, // Esc / q
    search, // /
    help, // h / ?
    save, // Ctrl+S
    saveAs, // Ctrl+Shift+S
    newProfile, // n
    deleteProfile, // d
    addPlugin, // a
    removePlugin, // x
    moveDown, // J
    moveUp, // K
    bypass, // b
    resetControl, // r
    cycleStyle, // t
    pluginInfo, // i
    settings, // s
}

struct KeyPress
{
    uint keyval; // GDK keyval
    uint modifiers; // GDK modifier mask (bit0 shift, bit2 control)
}

enum : uint
{
    GDK_SHIFT = 1u << 0,
    GDK_CONTROL = 1u << 2,
}

// GDK keyvals for the keys we bind (from gdk/gdkkeysyms.h).
enum : uint
{
    KEY_Escape = 0xff1b,
    KEY_Return = 0xff0d,
    KEY_space = 0x020,
    KEY_slash = 0x02f,
    KEY_Down = 0xff54,
    KEY_Up = 0xff52,
    KEY_Left = 0xff51,
    KEY_Right = 0xff53,
}

private uint lowerAscii(uint kv) pure nothrow @nogc @safe
{
    if (kv >= 'A' && kv <= 'Z')
        return kv + 32;
    return kv;
}

/// Map a key press to a VimAction. `inEditable` must be true when a text
/// entry owns focus (then only Escape/Enter/Ctrl+S pass through).
VimAction mapKey(KeyPress k, bool inEditable) pure nothrow @nogc @safe
{
    bool ctrl = (k.modifiers & GDK_CONTROL) != 0;
    bool shift = (k.modifiers & GDK_SHIFT) != 0;

    if (inEditable)
    {
        if (k.keyval == KEY_Escape)
            return VimAction.close;
        if (k.keyval == KEY_Return)
            return VimAction.activate;
        if (ctrl && (lowerAscii(k.keyval) == 's'))
            return shift ? VimAction.saveAs : VimAction.save;
        return VimAction.none;
    }

    if (ctrl && lowerAscii(k.keyval) == 's')
        return shift ? VimAction.saveAs : VimAction.save;

    switch (k.keyval)
    {
    case KEY_Down:
        return VimAction.nextItem;
    case KEY_Up:
        return VimAction.prevItem;
    case KEY_Left:
        return VimAction.prevPane;
    case KEY_Right:
        return VimAction.nextPane;
    case KEY_Return:
        return VimAction.activate;
    case KEY_Escape:
        return VimAction.close;
    case KEY_space:
        return VimAction.toggle;
    case KEY_slash:
        return VimAction.search;
    case '?':
        return VimAction.help;
    default:
        break;
    }

    if (ctrl)
        return VimAction.none;

    switch (lowerAscii(k.keyval))
    {
    case 'j':
        return shift ? VimAction.moveDown : VimAction.nextItem;
    case 'k':
        return shift ? VimAction.moveUp : VimAction.prevItem;
    case 'h':
        return VimAction.help;
    case 'l':
        return VimAction.nextPane;
    case 'q':
        return VimAction.close;
    case 'n':
        return VimAction.newProfile;
    case 'd':
        return VimAction.deleteProfile;
    case 'a':
        return VimAction.addPlugin;
    case 'x':
        return VimAction.removePlugin;
    case 'b':
        return VimAction.bypass;
    case 'i':
        return VimAction.pluginInfo;
    case 's':
        return VimAction.settings;
    case 'r':
        return VimAction.resetControl;
    case 't':
        return VimAction.cycleStyle;
    default:
        return VimAction.none;
    }
}

unittest
{
    assert(mapKey(KeyPress('j', 0), false) == VimAction.nextItem);
    assert(mapKey(KeyPress('J', GDK_SHIFT), false) == VimAction.moveDown);
    assert(mapKey(KeyPress('k', 0), false) == VimAction.prevItem);
    assert(mapKey(KeyPress(KEY_Escape, 0), false) == VimAction.close);
    // Text editing takes precedence:
    assert(mapKey(KeyPress('j', 0), true) == VimAction.none);
    assert(mapKey(KeyPress(KEY_Escape, 0), true) == VimAction.close);
    assert(mapKey(KeyPress('s', GDK_CONTROL), true) == VimAction.save);
    assert(mapKey(KeyPress('/', 0), false) == VimAction.search);
    assert(mapKey(KeyPress('t', 0), false) == VimAction.cycleStyle);
    assert(mapKey(KeyPress('d', 0), false) == VimAction.deleteProfile);
    assert(mapKey(KeyPress('a', 0), false) == VimAction.addPlugin);
    assert(mapKey(KeyPress('h', 0), false) == VimAction.help);
    assert(mapKey(KeyPress('i', 0), false) == VimAction.pluginInfo);
    assert(mapKey(KeyPress('s', 0), false) == VimAction.settings);
    assert(mapKey(KeyPress('s', GDK_CONTROL), false) == VimAction.save);    assert(mapKey(KeyPress('?', GDK_SHIFT), false) == VimAction.help);
    assert(mapKey(KeyPress(KEY_Left, 0), false) == VimAction.prevPane);
}

/// Single source of truth for the help overlay (and docs).
struct BindingHelp
{
    string keys;
    string action;
}

BindingHelp[] bindingHelp() pure @safe
{
    return [
        BindingHelp("j / Down", "next item"),
        BindingHelp("k / Up", "previous item"),
        BindingHelp("h / ?", "this help"),
        BindingHelp("l / Right", "next pane"),
        BindingHelp("Left", "previous pane"),
        BindingHelp("Enter", "activate"),
        BindingHelp("Space", "toggle bypass / selection"),
        BindingHelp("Esc / q", "close dialog"),
        BindingHelp("/", "plugin search"),
        BindingHelp("n", "new profile"),
        BindingHelp("d", "delete selected profile"),
        BindingHelp("a", "add plugin"),
        BindingHelp("x", "remove plugin"),
        BindingHelp("J / K", "move plugin down / up"),
        BindingHelp("b", "bypass plugin"),
        BindingHelp("i", "plugin info"),
        BindingHelp("r", "reset plugin controls"),
        BindingHelp("t", "cycle style (system → omarchy → dark → light)"),
        BindingHelp("s", "settings"),
        BindingHelp("Ctrl+S", "save profile"),
        BindingHelp("Ctrl+Shift+S", "save profile as"),
    ];
}
