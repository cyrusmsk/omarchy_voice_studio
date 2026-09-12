/// Profile persistence tests (spec §9 acceptance: restart keeps profiles).
module profile_test;

import audio.profile;

unittest
{
    import std.file : tempDir, rmdirRecurse, exists;
    import std.path : buildPath;

    string d = buildPath(tempDir(), "ovs-spec-profile-test");
    if (exists(d))
        rmdirRecurse(d);

    Profile mk(string id, string name)
    {
        Profile p;
        p.id = id;
        p.name = name;
        p.channelMode = "stereo";
        p.inputGainDb = 3.0;
        p.outputGainDb = -2.0;
        p.input.nodeName = "alsa_input.usb-test";
        p.input.displayName = "USB Mic";
        return p;
    }

    auto a = mk("broadcast", "Broadcast");
    auto b = mk("discord", "Discord");
    saveProfile(a, d);
    saveProfile(b, d);
    assert(listProfiles(d).length == 2);

    // Restart-equivalent: fresh load from disk.
    auto r = loadProfile("discord", d);
    assert(r.name == "Discord");
    assert(r.channelMode == "stereo");
    assert(r.inputGainDb == 3.0);

    // Invalid channel mode is rejected, never persisted silently.
    Profile bad = mk("bad", "Bad");
    bad.channelMode = "5.1";
    bool threw;
    try
        saveProfile(bad, d);
    catch (Exception)
        threw = true;
    assert(threw);

    rmdirRecurse(d);
}
