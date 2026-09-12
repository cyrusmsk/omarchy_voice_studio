/**
 * Save As dialog (spec §23 Ctrl+Shift+S): duplicate the current profile
 * under a new name. The window slugs the name into a unique profile id.
 */
module ui.save_as_dialog;

import gtk.box;
import gtk.button;
import gtk.entry;
import gtk.event_controller_key;
import gtk.label;
import gtk.types : Orientation;
import gtk.window : Window;
import gdk.types : ModifierType;

class SaveAsDialog : Window
{
private:
    Entry _entry;
    void delegate(string name) _onSave;

public:
    this(Window parent, string initial, void delegate(string) onSave)
    {
        super();
        _onSave = onSave;
        setTitle("Save profile as");
        setDefaultSize(380, 160);
        setModal(true);
        if (parent !is null)
            setTransientFor(parent);

        auto v = new Box(Orientation.Vertical, 8);
        v.setMarginTop(12);
        v.setMarginBottom(12);
        v.setMarginStart(12);
        v.setMarginEnd(12);

        auto lbl = new Label("Profile name");
        lbl.setXalign(0.0f);
        v.append(lbl);

        _entry = new Entry();
        _entry.setText(initial);
        v.append(_entry);

        auto h = new Box(Orientation.Horizontal, 8);
        auto saveBtn = Button.newWithLabel("Save");
        saveBtn.addCssClass("suggested-action");
        saveBtn.connectClicked(() => commit());
        h.append(saveBtn);
        auto cancelBtn = Button.newWithLabel("Cancel");
        cancelBtn.connectClicked(() => close());
        h.append(cancelBtn);
        v.append(h);

        setChild(v);
        _entry.grabFocus();

        // Esc cancels; Return saves. Typing otherwise stays native.
        auto keys = new EventControllerKey();
        keys.connectKeyPressed((uint keyval, uint keycode, ModifierType state) {
            if (keyval == 0xff1b) // Escape
            {
                close();
                return true;
            }
            return false; // entry handles the rest (incl. Return via commit below)
        });
        addController(keys);
        _entry.connectActivate(() => commit());
    }

private:
    void commit()
    {
        string name;
        try
        {
            name = _entry.getText();
        }
        catch (Exception)
        {
            return;
        }
        import std.string : strip;

        if (name.strip().length == 0)
            return;
        if (_onSave !is null)
        {
            try
                _onSave(name.strip());
            catch (Exception)
            {
                return;
            }
        }
        close();
    }
}
