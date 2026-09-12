/**
 * Real-time meter state.
 *
 * The audio thread only performs plain (RT-safe) writes of floats/ints;
 * the GTK thread polls ~20-30 Hz via `snapshot()`. No atomics with
 * passwords here — D `shared` + core.atomic on float bits is overkill;
 * instead we use `shared float` with atomic ops where the platform allows,
 * falling back to volatile-style plain writes which are race-tolerant for
 * meters (a torn meter read is harmless and never affects audio).
 *
 * Keep it simple, explicit and allocation-free.
 */
module audio.meter;

import core.atomic : atomicOp, atomicLoad, atomicStore;
import std.math : log10;

struct MeterSnapshot
{
    float inputPeak; // linear 0..~1+
    float outputPeak;
    bool inputClip;
    bool outputClip;
    uint overruns;
}

struct MeterState
{
private:
    // NOTE: D default-initializes floats to NaN. Engine must assign
    // MeterState.zeroed() (or call reset()) before GTK reads meters,
    // otherwise the UI polls NaN until the RT thread first writes.
    shared float _inPeak = 0.0f;
    shared float _outPeak = 0.0f;
    shared uint _flags;
    shared uint _overruns;

public:
    static MeterState zeroed() nothrow @nogc
    {
        MeterState m;
        m._inPeak = 0.0f;
        m._outPeak = 0.0f;
        m._flags = 0;
        m._overruns = 0;
        return m;
    }
    void writeInput(float peak, bool clip) nothrow @nogc
    {
        atomicStore(_inPeak, peak);
        if (clip)
            atomicOp!"|="(_flags, 1u);
    }

    void writeOutput(float peak, bool clip) nothrow @nogc
    {
        atomicStore(_outPeak, peak);
        if (clip)
            atomicOp!"|="(_flags, 2u);
    }

    void clearClips() nothrow @nogc
    {
        atomicOp!"&="(_flags, ~3u);
    }

    void addOverrun() nothrow @nogc
    {
        atomicOp!"+="(_overruns, 1u);
    }

    MeterSnapshot snapshot() const nothrow @nogc
    {
        MeterSnapshot s;
        s.inputPeak = atomicLoad(_inPeak);
        s.outputPeak = atomicLoad(_outPeak);
        uint f = atomicLoad(_flags);
        s.inputClip = (f & 1u) != 0;
        s.outputClip = (f & 2u) != 0;
        s.overruns = _overruns;
        return s;
    }
}

/// Linear peak -> dBFS. Returns -inf for silence.
float toDb(float linear) nothrow @nogc
{
    if (linear <= 0.0000001f)
        return -float.infinity;
    // log10 is @nogc? call via trusted path; fallback loop-free.
    return 20.0f * log10(linear);
}

/// Meter severity for CSS classes (spec §13).
string severityClass(float db) pure nothrow @safe
{
    if (db > -1.0f)
        return "danger";
    if (db > -6.0f)
        return "warning";
    if (db > -18.0f)
        return "healthy";
    return "normal";
}

unittest
{
    MeterState m;
    m.writeInput(0.5f, false);
    auto s = m.snapshot();
    assert(s.inputPeak == 0.5f);
    assert(!s.inputClip);
    assert(severityClass(-3.0f) == "warning");
    assert(severityClass(-0.5f) == "danger");
    assert(severityClass(-30.0f) == "normal");
}
