/**
 * Add Plugin dialog (spec §12): fuzzy search over already-discovered LV2
 * metadata. Search never instantiates plugins; the window instantiates the
 * chosen URI on Add (control thread, with graceful errors).
 */
module ui.add_plugin_dialog;

import gtk.box;
import gtk.button;
import gtk.event_controller_key;
import gtk.label;
import gtk.list_box;
import gtk.list_box_row;
import gtk.scrolled_window;
import gtk.search_entry;
import gtk.types : Orientation;
import gtk.window : Window;
import gdk.types : ModifierType;
import audio.lv2 : Lv2PluginInfo, discoverPlugins, searchPlugins;

class AddPluginDialog : Window
{
private:
    SearchEntry _search;
    ListBox _list;
    Label _status;
    Lv2PluginInfo[] _all;
    Lv2PluginInfo[] _shown;
    void delegate(string uri) _onAdd;

public:
    this(Window parent, void delegate(string uri) onAdd)
    {
        super();
        _onAdd = onAdd;
        setTitle("Add Plugin");
        setDefaultSize(520, 420);
        setModal(true);
        if (parent !is null)
            setTransientFor(parent);

        auto v = new Box(Orientation.Vertical, 8);
        v.setMarginTop(12);
        v.setMarginBottom(12);
        v.setMarginStart(12);
        v.setMarginEnd(12);

        _search = new SearchEntry();
        _search.setPlaceholderText("Search plugins…  (name, vendor, URI)");
        v.append(_search);

        auto scroll = new ScrolledWindow();
        scroll.setVexpand(true);
        scroll.setHexpand(true);
        _list = new ListBox();
        scroll.setChild(_list);
        v.append(scroll);

        _status = new Label("");
        _status.setXalign(0.0f);
        v.append(_status);

        auto h = new Box(Orientation.Horizontal, 8);
        auto addBtn = Button.newWithLabel("Add selected");
        addBtn.connectClicked(() => addSelected());
        h.append(addBtn);
        auto closeBtn = Button.newWithLabel("Close");
        closeBtn.connectClicked(() => close());
        h.append(closeBtn);
        v.append(h);

        setChild(v);

        _search.connectSearchChanged(() {
            try
                refresh(_search.getText());
            catch (Exception)
            {
            }
        });
        _list.connectRowActivated((ListBoxRow row, ListBox lb) { addSelected(); });

        try
        {
            _all = discoverPlugins();
        }
        catch (Exception e)
        {
            _all = null;
            _status.setText("Discovery failed");
        }
        refresh("");
        _search.grabFocus();

        // Keyboard-first: Esc/q closes, Return adds the top match.
        auto keys = new EventControllerKey();
        keys.connectKeyPressed((uint keyval, uint keycode, ModifierType state) {
            if (keyval == 0xff1b) // Escape
            {
                close();
                return true;
            }
            // Never hijack typing in the search field (only Esc/Return).
            if (getFocus() is _search)
            {
                if (keyval == 0xff0d) // Return: add first match
                {
                    if (_list.getSelectedRow() is null && _shown.length > 0)
                    {
                        auto first = _list.getRowAtIndex(0);
                        if (first !is null)
                            _list.selectRow(first);
                    }
                    addSelected();
                    return true;
                }
                return false;
            }
            if (keyval == 'q' && (state & 4u) == 0)
            {
                close();
                return true;
            }
            if ((keyval == 'j' || keyval == 0xff54) && (state & 5u) == 0)
            {
                moveDialogSelection(1);
                return true;
            }
            if ((keyval == 'k' || keyval == 0xff52) && (state & 5u) == 0)
            {
                moveDialogSelection(-1);
                return true;
            }
            return false;
        });
        addController(keys);
    }

private:
    void moveDialogSelection(int delta)
    {
        import ui.scroll : moveListSelection;

        moveListSelection(_list, cast(uint) _shown.length, delta);
    }

    void refresh(string query)
    {
        _shown = searchPlugins(_all, query);
        _list.removeAll();
        if (_shown.length == 0)
        {
            _status.setText(_all.length == 0
                ? "No LV2 plugins installed"
                : "No matches");
            return;
        }
        foreach (ref p; _shown)
        {
            auto row = new ListBoxRow();
            auto b = new Box(Orientation.Vertical, 2);
            auto name = new Label(p.name);
            name.setXalign(0.0f);
            b.append(name);
            string sub = p.vendor.length ? p.vendor ~ "  ·  " ~ p.uri : p.uri;
            if (p.clazz.length > 0)
                sub = p.clazz ~ "  ·  " ~ sub;
            if (!p.supportedForMvp())
                sub ~= "  (unsupported layout)";
            auto detail = new Label(sub);
            detail.setXalign(0.0f);
            b.append(detail);
            row.setChild(b);
            _list.append(row);
        }
        _status.setText("");
    }

    void addSelected()
    {
        auto row = _list.getSelectedRow();
        if (row is null)
        {
            _status.setText("Select a plugin first");
            return;
        }
        int idx = row.getIndex();
        if (idx < 0 || idx >= cast(int) _shown.length)
            return;
        if (!(_shown[idx].supportedForMvp()))
        {
            _status.setText("That plugin needs an unsupported channel layout");
            return;
        }
        if (_onAdd !is null)
        {
            try
                _onAdd(_shown[idx].uri);
            catch (Exception e)
            {
                _status.setText(e.msg);
                return;
            }
        }
        close();
    }
}
