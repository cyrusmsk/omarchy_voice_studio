/**
 * Help overlay: keyboard-first keybinding reference.
 *
 * Opened with `h` (or `?`), closed with `Esc`/`q`/`h`. Content comes from
 * ui.shortcuts.bindingHelp so code, overlay and docs never drift apart.
 */
module ui.help_dialog;

import gtk.box;
import gtk.button;
import gtk.event_controller_key;
import gtk.grid;
import gtk.label;
import gtk.scrolled_window;
import gtk.types : Orientation;
import gtk.window : Window;
import gdk.types : ModifierType;
import ui.shortcuts : bindingHelp;

class HelpDialog : Window
{
public:
    this(Window parent)
    {
        super();
        setTitle("Keyboard shortcuts");
        setDefaultSize(460, 520);
        setModal(true);
        if (parent !is null)
            setTransientFor(parent);

        auto v = new Box(Orientation.Vertical, 8);
        v.setMarginTop(12);
        v.setMarginBottom(12);
        v.setMarginStart(12);
        v.setMarginEnd(12);

        auto title = new Label("Omarchy Voice Studio — keys");
        title.setXalign(0.0f);
        v.append(title);

        auto scroll = new ScrolledWindow();
        scroll.setVexpand(true);
        scroll.setHexpand(true);
        auto grid = new Grid();
        grid.setColumnSpacing(16);
        grid.setRowSpacing(4);
        auto rows = bindingHelp();
        foreach (i, ref r; rows)
        {
            auto k = new Label(r.keys);
            k.setXalign(0.0f);
            k.addCssClass("ovs-keys");
            grid.attach(k, 0, cast(int) i, 1, 1);
            auto a = new Label(r.action);
            a.setXalign(0.0f);
            a.setHexpand(true);
            grid.attach(a, 1, cast(int) i, 1, 1);
        }
        scroll.setChild(grid);
        v.append(scroll);

        auto closeBtn = Button.newWithLabel("Close  (Esc)");
        closeBtn.connectClicked(() => close());
        v.append(closeBtn);

        setChild(v);

        auto keys = new EventControllerKey();
        keys.connectKeyPressed((uint keyval, uint keycode, ModifierType state) {
            uint k = keyval;
            if (k >= 'A' && k <= 'Z')
                k += 32;
            if (keyval == 0xff1b || k == 'q' || k == 'h' || keyval == '?')
            {
                close();
                return true;
            }
            return false;
        });
        addController(keys);
    }
}
