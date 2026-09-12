/**
 * RNNoise speech-noise-suppression stage (spec: first stage, outside LV2).
 *
 * Chain position: raw mic -> RNNoise -> input gain -> LV2 ... (user's
 * recommended topology: suppression, EQ, compressor, de-esser, limiter).
 *
 * Loading: librnnoise is dlopen()ed on the control thread; absence means
 * the stage is inert with a UI note (spec §3.4). No link-time dependency.
 *
 * Framing: RNNoise consumes fixed 480-sample frames @48 kHz. Graph quanta
 * are arbitrary, so each channel runs a fixed-delay line (DELAY = 480
 * samples ≈ 10 ms): every input sample is denoised exactly once, every
 * block emits exactly nframes, output lags input by a constant 480
 * samples. Startup emits 480 zeros (priming). No allocation after build.
 */
module audio.denoise;

import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW;

enum uint DENOISE_FRAME = 480;
enum uint DENOISE_DELAY = 480;
enum uint DENOISE_RING = 8192; // must exceed maxFrames + 2*FRAME

extern (C) struct DenoiseState;

// Resolved on the control thread via dlopen; RT only calls processFrame.
// Attributes describe the D-side call contract (C code cannot throw D
// exceptions; allocation behavior is the library's, bounded per call).
extern (C) alias RnCreateFn = DenoiseState* function(void* model) nothrow @nogc;
extern (C) alias RnProcessFn = float function(DenoiseState* st, float* dst, const(float)* src) nothrow @nogc;
extern (C) alias RnDestroyFn = void function(DenoiseState* st) nothrow @nogc;

struct RnApi
{
    void* lib;
    RnCreateFn create;
    RnProcessFn process;
    RnDestroyFn destroy_;
    bool available;
}

/// Load librnnoise (control thread). Never throws.
RnApi loadRnNoise() nothrow
{
    RnApi api;
    try
    {
        foreach (name; ["librnnoise.so.0", "librnnoise.so"])
        {
            import std.string : toStringz;

            api.lib = dlopen(name.toStringz, RTLD_NOW);
            if (api.lib !is null)
                break;
        }
        if (api.lib is null)
            return api;
        api.create = cast(RnCreateFn) dlsym(api.lib, "rnnoise_create");
        api.process = cast(RnProcessFn) dlsym(api.lib, "rnnoise_process_frame");
        api.destroy_ = cast(RnDestroyFn) dlsym(api.lib, "rnnoise_destroy");
        api.available = api.create !is null && api.process !is null && api.destroy_ !is null;
        if (!api.available && api.lib !is null)
        {
            dlclose(api.lib);
            api.lib = null;
        }
    }
    catch (Exception)
    {
    }
    return api;
}

/// One channel of delay-line denoising. Buffers preallocated at build.
struct DenoiseChannel
{
    float[DENOISE_RING] inRing;
    float[DENOISE_RING] procRing;
    float[DENOISE_FRAME] tmp;
    uint inWrite; // total input samples ever
    uint procCursor; // input position processed up to
    uint emitted; // output samples emitted
    DenoiseState* st;
    RnProcessFn procFn;

    void reset() nothrow @nogc
    {
        inWrite = 0;
        procCursor = 0;
        emitted = 0;
    }

    /**
     * Push nframes from src, emit exactly nframes to dst (RT-safe).
     *
     * Exact fixed-delay line: every input sample is denoised exactly once
     * and emitted exactly once, delayed by a constant (the smallest block
     * multiple >= nframes + DENOISE_DELAY). While priming, emits zeros and
     * holds the emit pointer (no sample loss, no pads after priming).
     */
    void pushEmit(const(float)* src, float* dst, uint nframes) nothrow @nogc
    {
        if (src is null || dst is null || st is null || procFn is null)
        {
            if (dst !is null && src !is null)
            {
                foreach (i; 0 .. nframes)
                    dst[i] = src[i]; // fail-open: pass through
            }
            else if (dst !is null)
            {
                foreach (i; 0 .. nframes)
                    dst[i] = 0.0f;
            }
            return;
        }
        foreach (i; 0 .. nframes)
            inRing[(inWrite + i) & (DENOISE_RING - 1)] = src[i];
        inWrite += nframes;

        // Process all complete new frames.
        while (inWrite - procCursor >= DENOISE_FRAME)
        {
            foreach (i; 0 .. DENOISE_FRAME)
                tmp[i] = inRing[(procCursor + i) & (DENOISE_RING - 1)];
            procFn(st, tmp.ptr, tmp.ptr);
            uint base = procCursor;
            foreach (i; 0 .. DENOISE_FRAME)
                procRing[(base + i) & (DENOISE_RING - 1)] = tmp[i];
            procCursor += DENOISE_FRAME;
        }

        // Emit with fixed delay (positions < procCursor are all processed).
        if (inWrite - emitted >= nframes + DENOISE_DELAY)
        {
            foreach (i; 0 .. nframes)
                dst[i] = procRing[(emitted + i) & (DENOISE_RING - 1)];
            emitted += nframes;
        }
        else
        {
            foreach (i; 0 .. nframes)
                dst[i] = 0.0f;
        }
    }
}

unittest
{
    // Accounting test with a fake frame processor (marks + identity).
    // Verifies: exact N-in/N-out, constant delay, no pads after priming.
    extern (C) static float fakeProc(DenoiseState* st, float* out_, const(float)* in_) nothrow @nogc
    {
        foreach (i; 0 .. DENOISE_FRAME)
            out_[i] = in_[i];
        return 0.0f;
    }

    DenoiseChannel ch;
    ch.st = cast(DenoiseState*) 0x1; // non-null sentinel (never deref'd)
    ch.procFn = &fakeProc;
    // Drive with awkward block sizes (not multiples of 480).
    float[1024] src;
    float[1024] dst;
    foreach (i; 0 .. 1024)
        src[i] = cast(float)(i + 1);
    uint total;
    float[] history;
    foreach (b; 0 .. 10)
    {
        ch.pushEmit(src.ptr, dst.ptr, 1024);
        total += 1024;
        history ~= dst[0 .. 1024];
    }
    assert(total == 10240);
    assert(history.length == 10240);
    // N=1024 blocks need N+480=1504 buffered: first block primes (zeros),
    // then the stream flows delayed by exactly one block (1024).
    foreach (i; 0 .. 1024)
        assert(history[i] == 0.0f);
    // ...input positions 0..9215 each exactly once, in order. Input pattern
    // repeats every 1024: sample value at global in-position q is (q%1024)+1.
    foreach (i; 1024 .. history.length)
    {
        uint q = cast(uint)(i - 1024);
        assert(history[i] == cast(float)((q % 1024) + 1));
    }
}
