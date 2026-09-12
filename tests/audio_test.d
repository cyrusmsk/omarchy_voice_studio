/// Audio DSP tests: gains, meters, profile switching keeps old graph.
module audio_test;

import audio.engine;
import audio.graph;
import audio.meter;
import audio.profile : Profile;
import audio.rt_queue;

unittest
{
    // Built-in gains work with zero LV2 plugins (spec §14).
    auto g = new AudioGraph(48000, 16);
    g.mode = ChannelMode.mono;
    g.inputGainDb = 6.0; // ~x2
    g.outputGainDb = 0.0;
    g.scratchA = [new float[16]];
    g.scratchB = [new float[16]];
    float[16] input;
    float[16] output;
    foreach (i; 0 .. 16)
        input[i] = 0.25f;
    float*[1] ins = [input.ptr];
    float*[1] outs = [output.ptr];
    g.process(ins.ptr, outs.ptr, 16);
    import std.math : abs;

    float expected = 0.25f * AudioGraph.dbToLin(6.0f);
    assert(abs(output[0] - expected) < 1e-5);

    // Failed profile switch preserves working audio (spec §16).
    auto eng = new Engine();
    Profile good;
    good.id = "good";
    good.name = "Good";
    assert(eng.applyProfile(good));
    Profile bad;
    bad.id = "";
    assert(!eng.applyProfile(bad));
    assert(eng.currentProfile.id == "good");

    // Queue overflow is explicit, never silent corruption.
    auto q = new CommandQueue(1); // capacity 2
    EngineCommand c;
    assert(q.enqueue(c));
    assert(q.enqueue(c));
    assert(!q.enqueue(c));
}
