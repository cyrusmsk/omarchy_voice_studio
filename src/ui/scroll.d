/**
 * Scroll-follows-selection helper.
 *
 * GTK4 ListBox has no scroll-to-row API, and keyboard selection (j/k)
 * otherwise moves invisibly outside the viewport. After every programmatic
 * selectRow(), views call ensureRowVisible() so the selected row is
 * scrolled into view. Walks up to the nearest enclosing ScrolledWindow
 * (correct with nested scrollers) and nudges its vertical adjustment.
 * Pure GTK calls, never touches audio.
 */
module ui.scroll;

import gtk.adjustment : Adjustment;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.scrolled_window : ScrolledWindow;
import gtk.types : Allocation;
import gtk.widget : Widget;

void ensureRowVisible(ListBox list, ListBoxRow row)
{
    if (list is null || row is null)
        return;
    try
    {
        // The row may have been destroyed by a rebuild triggered through
        // selection (profiles/devices rebuild on activate) — detached rows
        // must never move the viewport.
        if (row.getParent() is null)
            return;
        // Nearest enclosing scroller (inner list scroller wins when nested).
        Widget w = list.getParent();
        ScrolledWindow sw;
        while (w !is null)
        {
            sw = cast(ScrolledWindow) w;
            if (sw !is null)
                break;
            w = w.getParent();
        }
        if (sw is null)
            return;
        // Content coordinates: the row's allocation is relative to the
        // ListBox origin, which is the scrolled content origin; the
        // adjustment value is the top visible content offset. (Deliberately
        // not translateCoordinates: that yields viewport-relative coords,
        // which must not be compared against the adjustment value.)
        Allocation alloc;
        row.getAllocation(alloc);
        double top = alloc.y;
        double bottom = top + alloc.height;
        Adjustment adj = sw.getVadjustment();
        if (adj is null)
            return;
        double val = adj.getValue();
        double page = adj.getPageSize();
        if (page <= 0)
            return;
        if (top < val)
            adj.setValue(top);
        else if (bottom > val + page)
            adj.setValue(bottom - page);
    }
    catch (Exception)
    {
    }
}

/// Move selection by delta rows, activate-free, and keep it visible.
/// Returns the new index, or -1 when the list is empty.
int moveListSelection(ListBox list, uint count, int delta)
{
    if (list is null || count == 0)
        return -1;
    int cur = 0;
    auto sel = list.getSelectedRow();
    if (sel !is null)
        cur = sel.getIndex();
    int next = cur + delta;
    if (next < 0)
        next = 0;
    if (next >= cast(int) count)
        next = cast(int) count - 1;
    auto row = list.getRowAtIndex(next);
    if (row is null)
        return -1;
    list.selectRow(row);
    ensureRowVisible(list, row);
    return next;
}
