/**
 * Profile sidebar: list of profiles + New/Delete.
 *
 * Emits selection changes to the window via delegates (no direct engine
 * access — the window owns the Engine).
 */
module ui.profile_view;

import gtk.box;
import gtk.button;
import gtk.label;
import gtk.list_box;
import gtk.list_box_row;
import gtk.scrolled_window;
import gtk.types : Orientation, SelectionMode;
import gtk.widget : Widget;
import audio.profile : Profile;

class ProfileView : Box
{
private:
    ListBox _list;
    Profile[] _profiles;
    // While true, row-selected emissions (from remove()/selectRow() during
    // rebuild) are swallowed. Without this, programmatic selection recurses:
    // selectRow -> row-selected -> selectProfile -> setProfiles -> selectRow
    // ... until stack overflow (SIGSEGV). See coredump analysis.
    bool _suspend;
    void delegate(string id) _onSelect;
    void delegate() _onNew;
    void delegate(string id) _onDelete;

public:
    this(void delegate(string id) onSelect = null, void delegate() onNew = null,
        void delegate(string id) onDelete = null)
    {
        super(Orientation.Vertical, 6);
        _onSelect = onSelect;
        _onNew = onNew;
        _onDelete = onDelete;

        auto title = new Label("Profiles");
        title.setXalign(0.0f);
        append(title);

        auto scroll = new ScrolledWindow();
        scroll.setVexpand(true);
        _list = new ListBox();
        _list.setSelectionMode(SelectionMode.Single);
        scroll.setChild(_list);
        append(scroll);

        auto newBtn = Button.newWithLabel("+ New Profile  (n)");
        newBtn.connectClicked(() {
            if (_onNew !is null)
                _onNew();
        });
        append(newBtn);

        auto delBtn = Button.newWithLabel("Delete Profile  (d)");
        delBtn.connectClicked(() {
            if (_onDelete !is null)
            {
                string id = selectedId();
                if (id.length > 0)
                    _onDelete(id);
            }
        });
        append(delBtn);

        _list.connectRowSelected((ListBoxRow row) {
            if (_suspend)
                return;
            if (row is null)
                return;
            int idx = row.getIndex();
            if (idx >= 0 && idx < cast(int) _profiles.length && _onSelect !is null)
                _onSelect(_profiles[idx].id);
        });
    }

    void setProfiles(Profile[] profiles, string activeId)
    {
        _suspend = true;
        scope (exit)
            _suspend = false;
        _profiles = profiles.dup;
        // Clear + rebuild (remove() emits row-selected; swallowed via _suspend).
        _list.removeAll();
        foreach (i, ref p; _profiles)
        {
            auto row = new ListBoxRow();
            string mark = (p.id == activeId) ? "> " : "  ";
            auto lbl = new Label(mark ~ p.name);
            lbl.setXalign(0.0f);
            row.setChild(lbl);
            _list.append(row);
            if (p.id == activeId)
            {
                _list.selectRow(row);
                import ui.scroll : ensureRowVisible;

                ensureRowVisible(_list, row);
            }
        }
    }

    @property Profile[] profiles() { return _profiles; }

    /// Keyboard navigation: move selection by delta rows (activates +
    /// scrolls into view).
    void moveSelection(int delta)
    {
        import ui.scroll : moveListSelection;

        moveListSelection(_list, cast(uint) _profiles.length, delta);
    }

    string selectedId()
    {
        auto sel = _list.getSelectedRow();
        if (sel is null)
            return null;
        int idx = sel.getIndex();
        if (idx < 0 || idx >= cast(int) _profiles.length)
            return null;
        return _profiles[idx].id;
    }

    void focusList()
    {
        _list.grabFocus();
    }
}
