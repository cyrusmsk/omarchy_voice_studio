/**
 * Level meter widget — thin wrapper around GtkLevelBar.
 *
 * RT rule: never called from the audio thread. The window polls
 * Engine.meterSnapshot() at ~25 Hz and pushes values here.
 */
module ui.meter;

import gtk.level_bar;
import gtk.widget;

class MeterWidget : LevelBar
{
    private string _name;

    this(string name)
    {
        super();
        _name = name;
        setMinValue(0.0);
        setMaxValue(1.0);
        setValue(0.0);
        // Offsets mirror spec §13 thresholds (linear approximations of
        // -18/-6/-1 dBFS): 0.126 / 0.5 / 0.891.
        addOffsetValue("low", 0.126);
        addOffsetValue("high", 0.5);
        addOffsetValue("full", 0.891);
        addCssClass("ovs-meter");
        addCssClass("normal");
    }

    void setPeak(float linear, bool clip)
    {
        float v = linear;
        if (v != v) // NaN guard: engine meters start unwritten until RT runs
            v = 0.0f;
        if (v < 0)
            v = 0;
        if (v > 1.2f)
            v = 1.2f;
        // LevelBar max is 1.0; clip shows via CSS class.
        setValue(v > 1.0 ? 1.0 : v);
        removeCssClass("normal");
        removeCssClass("healthy");
        removeCssClass("warning");
        removeCssClass("danger");
        import audio.meter : toDb, severityClass;

        addCssClass(severityClass(toDb(linear < 0 ? 0 : linear)));
        if (clip)
            addCssClass("danger");
    }
}
