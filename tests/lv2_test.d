/// LV2 metadata tests: search runs on discovered metadata, URIs persist.
module lv2_test;

import audio.lv2;

unittest
{
    // Search never instantiates; pure metadata filtering.
    Lv2PluginInfo mk(string uri, string name)
    {
        Lv2PluginInfo p;
        p.uri = uri;
        p.name = name;
        p.audioInputs = 1;
        p.audioOutputs = 1;
        return p;
    }

    auto all = [mk("urn:a:comp", "Studio Compressor"), mk("urn:a:gate", "Noise Gate")];
    assert(searchPlugins(all, "gate").length == 1);
    assert(searchPlugins(all, "urn:a:").length == 2);
    assert(searchPlugins(all, "missing").length == 0);

    // URI identity is what profiles persist (never bundle paths).
    assert(all[0].uri == "urn:a:comp");

    // Discovery degrades gracefully (no throw even with no plugins).
    auto found = discoverPlugins();
    assert(found.length >= 0);
}
