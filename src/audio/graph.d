/**
 * Audio processing graph — RT-safe DSP core.
 *
 * Layout (spec §8.1):
 *   input gain -> LV2 slot 0..N -> output gain -> meters
 *
 * Real-time rules (spec §3.2):
 *  - `process()` is @nogc nothrow, never allocates, never locks, never
 *    touches GTK/GC/LV2 instantiation.
 *  - LV2 instances are prepared on the control thread: audio ports are
 *    connected to the graph scratch buffers, control ports to plain floats.
 *    RT only calls the captured `run` pointer.
 *  - Signal flows through two scratch sides (A/B) ping-pong: slot N reads
 *    one side and writes the other. `outIsB` records each slot's output
 *    side at build time, so RT never branches on topology.
 *  - Built-in gain stages always work with no LV2 installed (spec §14).
 */
module audio.graph;

import audio.meter : MeterState;
import audio.denoise : DenoiseChannel;
import core.stdc.math : fabsf;

enum ChannelMode : ubyte
{
    mono,
    stereo,
}

// Opaque LV2 instance handle (owned by control thread, used by RT thread).
extern (C) alias Lv2RunFn = void function(void* instance, uint nframes) nothrow @nogc;

struct PluginSlot
{
    string uri;
    string name;
    bool enabled = true;
    bool valid; // false if plugin failed to instantiate

    // RT-relevant fields (plain data, set up before publish):
    void* instance; // LV2_Handle
    Lv2RunFn runFn;
    // Scratch sides wired at build time (strict alternation). The RT
    // invariant: after slot i, the signal is on side outIsB(i) — active
    // slots run the plugin, skipped slots copy in-side -> out-side.
    bool inIsB;
    bool outIsB;

    // Control port values (plain floats, preallocated; RT reads via the
    // pointers the plugin captured at connect time).
    float[] controls;

    // Message-port dummy buffer (empty atom area; plugins with a control/
    // notify interface stay inert). One shared buffer per slot is allowed
    // by LV2 (ports may alias). UI surfaces this as a note, never silent.
    ubyte[] atomScratch;
    // Human note for the UI, e.g. "(2 message ports inert)".
    string note;

    // Control-thread-owned lifetime (freed on graph retire, never RT):
    void* lilvInstance; // LilvInstance*
    float[] controlSink; // dummy sinks for control *output* ports
}

/// A fully-baked graph. Mutable only on the control thread. Once published,
/// the RT thread treats it as immutable except meter writes.
final class AudioGraph
{
    ChannelMode mode = ChannelMode.mono;
    uint sampleRate;
    uint maxFrames; // native quantum ceiling used for scratch sizing

    float inputGainDb;
    float outputGainDb;

    PluginSlot[] slots;

    // RNNoise first stage (empty when disabled). States created on the
    // control thread; RT only runs framed process calls (no allocation).
    DenoiseChannel[] denoise;
    string denoiseNote;

    // Scratch buffers (per channel), sized maxFrames.
    float[][] scratchA;
    float[][] scratchB;
    // Shared zero buffer for sidechain/extra plugin inputs.
    float[] zeroBuf;

    MeterState* meters; // not owned; set by engine

    this(uint sampleRate_ = 48000, uint maxFrames_ = 8192) nothrow
    {
        sampleRate = sampleRate_;
        maxFrames = maxFrames_;
    }

    uint channels() const nothrow @nogc
    {
        return mode == ChannelMode.stereo ? 2u : 1u;
    }

    float inputLin() const nothrow @nogc
    {
        return dbToLin(inputGainDb);
    }

    float outputLin() const nothrow @nogc
    {
        return dbToLin(outputGainDb);
    }

    static float dbToLin(float db) nothrow @nogc
    {
        if (db <= -90.0f)
            return 0.0f;
        return pow(db / 20.0f);
    }

    /**
     * Real-time process. `ins`/`outs` are per-channel buffers with
     * `nframes` samples each (nframes <= maxFrames). Allocation-free.
     */
    void process(float** ins, float** outs, uint nframes) nothrow @nogc
    {
        uint ch = channels();
        if (nframes > maxFrames)
            nframes = maxFrames;
        float ig = inputLin();
        float og = outputLin();

        // 1. RNNoise (optional first stage) + input gain -> scratchA
        bool useDenoise = denoise.length == ch && ch > 0;
        float inPeak = 0.0f;
        foreach (c; 0 .. ch)
        {
            float* src = ins[c];
            float* dst = scratchPtr(scratchA, c, nframes);
            if (src is null || dst is null)
                continue;
            if (useDenoise)
                denoise[c].pushEmit(src, dst, nframes);
            else
            {
                foreach (i; 0 .. nframes)
                    dst[i] = src[i];
            }
            foreach (i; 0 .. nframes)
            {
                float v = dst[i] * ig;
                dst[i] = v;
                float a = v < 0 ? -v : v;
                if (a > inPeak)
                    inPeak = a;
            }
        }

        // 2. plugin chain ping-pong (cur=false => signal in A).
        bool curIsB = false;
        foreach (ref slot; slots)
        {
            if (!slot.enabled || !slot.valid || slot.runFn is null)
            {
                // Skipped (bypassed or failed) slot: pass signal through
                // to this slot's output side so the chain invariant holds.
                if (slot.valid && curIsB != slot.outIsB)
                    copySide(curIsB, slot.outIsB, ch, nframes);
                if (slot.valid)
                    curIsB = slot.outIsB;
                continue;
            }
            slot.runFn(slot.instance, nframes);
            curIsB = slot.outIsB;
        }

        // 3. output gain -> outs
        float outPeak = 0.0f;
        foreach (c; 0 .. ch)
        {
            float* src = curIsB ? scratchPtr(scratchB, c, nframes)
                : scratchPtr(scratchA, c, nframes);
            float* dst = outs[c];
            if (src is null || dst is null)
                continue;
            foreach (i; 0 .. nframes)
            {
                float v = src[i] * og;
                dst[i] = v;
                float a = v < 0 ? -v : v;
                if (a > outPeak)
                    outPeak = a;
            }
        }

        if (meters !is null)
        {
            meters.writeInput(inPeak, inPeak >= 1.0f);
            meters.writeOutput(outPeak, outPeak >= 1.0f);
        }
    }

private:
    void copySide(bool srcIsB, bool dstIsB, uint ch, uint nframes) nothrow @nogc
    {
        foreach (c; 0 .. ch)
        {
            float* src = scratchPtr(srcIsB ? scratchB : scratchA, c, nframes);
            float* dst = scratchPtr(dstIsB ? scratchB : scratchA, c, nframes);
            if (src is null || dst is null || src == dst)
                continue;
            foreach (i; 0 .. nframes)
                dst[i] = src[i];
        }
    }

    float* scratchPtr(float[][] buf, uint ch, uint nframes) nothrow @nogc
    {
        if (ch >= buf.length)
            return null;
        if (buf[ch].length < nframes)
            return null;
        return buf[ch].ptr;
    }
}

// 10^(x), @nogc-safe.
private float pow(float x) nothrow @nogc
{
    import core.stdc.math : powf;

    return powf(10.0f, x);
}

unittest
{
    auto g = new AudioGraph(48000, 64);
    g.mode = ChannelMode.mono;
    g.inputGainDb = 0.0f;
    g.outputGainDb = 0.0f;
    g.scratchA = [new float[64]];
    g.scratchB = [new float[64]];
    float[64] input;
    float[64] output;
    foreach (i; 0 .. 64)
        input[i] = 0.25f;
    float*[1] ins = [input.ptr];
    float*[1] outs = [output.ptr];
    g.process(ins.ptr, outs.ptr, 64);
    foreach (i; 0 .. 64)
        assert(output[i] == 0.25f);
}
