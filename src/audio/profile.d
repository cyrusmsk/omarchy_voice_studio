/**
 * Profiles — persistent voice-processing configuration (spec §7).
 *
 * JSON via std.json only. Persisted: id, name, input device (name+serial,
 * never numeric node id), gains, channel mode, ordered plugin chain with
 * URIs + control values. Runtime state (node ids, pointers, widgets) is
 * never persisted (spec §3.3).
 */
module audio.profile;

import std.json;
import std.file : exists, mkdirRecurse, dirEntries, SpanMode, readText, write;
import std.path : buildPath;
import std.exception : enforce;

enum uint PROFILE_VERSION = 1;

struct DeviceRef
{
    string nodeName; // PipeWire node.name, e.g. alsa_input.usb-...
    string serial; // object.serial if available
    string displayName; // human-readable

    JSONValue toJson() const
    {
        return JSONValue([
            "nodeName": JSONValue(nodeName),
            "serial": JSONValue(serial),
            "displayName": JSONValue(displayName),
        ]);
    }

    static DeviceRef fromJson(JSONValue v)
    {
        DeviceRef d;
        if ("nodeName" in v)
            d.nodeName = v["nodeName"].str;
        if ("serial" in v)
            d.serial = v["serial"].str;
        if ("displayName" in v)
            d.displayName = v["displayName"].str;
        return d;
    }
}

struct PluginEntry
{
    string uri;
    bool enabled = true;
    double[string] controls;

    JSONValue toJson() const
    {
        JSONValue c = parseJSON("{}");
        foreach (k, v; controls)
            c[k] = JSONValue(v);
        return JSONValue([
            "uri": JSONValue(uri),
            "enabled": JSONValue(enabled),
            "controls": c,
        ]);
    }

    static PluginEntry fromJson(JSONValue v)
    {
        PluginEntry p;
        p.uri = v["uri"].str;
        enforce!Exception(p.uri.length > 0, "plugin entry missing uri");
        if ("enabled" in v)
            p.enabled = v["enabled"].boolean;
        if ("controls" in v && v["controls"].type == JSONType.object)
            foreach (k, val; v["controls"].object)
            {
                if (val.type == JSONType.float_)
                    p.controls[k] = val.floating;
                else if (val.type == JSONType.integer)
                    p.controls[k] = cast(double) val.integer;
            }
        return p;
    }
}

struct Profile
{
    string id;
    string name;
    DeviceRef input;
    double inputGainDb = 0.0;
    double outputGainDb = -1.0;
    string channelMode = "mono"; // "mono" | "stereo"
    bool denoise; // RNNoise first stage (inert when librnnoise missing)
    PluginEntry[] plugins;

    JSONValue toJson() const
    {
        JSONValue[] arr;
        foreach (ref p; plugins)
            arr ~= p.toJson();
        return JSONValue([
            "version": JSONValue(cast(long) PROFILE_VERSION),
            "id": JSONValue(id),
            "name": JSONValue(name),
            "inputDevice": input.toJson(),
            "inputGainDb": JSONValue(inputGainDb),
            "outputGainDb": JSONValue(outputGainDb),
            "channelMode": JSONValue(channelMode),
            "denoise": JSONValue(denoise),
            "plugins": JSONValue(arr),
        ]);
    }

    string toJsonString() const
    {
        return toJson().toPrettyString();
    }

    static Profile fromJson(JSONValue v)
    {
        Profile p;
        if ("id" in v)
            p.id = v["id"].str;
        if ("name" in v)
            p.name = v["name"].str;
        enforce!Exception(p.id.length > 0, "profile missing id");
        if (p.name.length == 0)
            p.name = p.id;
        if ("inputDevice" in v)
            p.input = DeviceRef.fromJson(v["inputDevice"]);
        if ("inputGainDb" in v)
            p.inputGainDb = jsonToDouble(v["inputGainDb"]);
        if ("outputGainDb" in v)
            p.outputGainDb = jsonToDouble(v["outputGainDb"]);
        if ("channelMode" in v)
            p.channelMode = v["channelMode"].str;
        if (p.channelMode != "mono" && p.channelMode != "stereo")
            throw new Exception("unsupported channelMode: " ~ p.channelMode);
        if ("denoise" in v && v["denoise"].type == JSONType.true_)
            p.denoise = true;
        if ("plugins" in v && v["plugins"].type == JSONType.array)
            foreach (e; v["plugins"].array)
                p.plugins ~= PluginEntry.fromJson(e);
        return p;
    }

    static Profile fromJsonString(string s)
    {
        return fromJson(parseJSON(s));
    }

    /// Validate without touching audio hardware.
    void validate() const
    {
        enforce!Exception(id.length > 0, "profile id is empty");
        enforce!Exception(name.length > 0, "profile name is empty");
        enforce!Exception(channelMode == "mono" || channelMode == "stereo",
            "unsupported channelMode");
        enforce!Exception(inputGainDb >= -60 && inputGainDb <= 24,
            "inputGainDb out of range");
        enforce!Exception(outputGainDb >= -60 && outputGainDb <= 24,
            "outputGainDb out of range");
        foreach (ref pl; plugins)
            enforce!Exception(pl.uri.length > 0, "plugin uri is empty");
    }

private:
    static double jsonToDouble(JSONValue v)
    {
        if (v.type == JSONType.float_)
            return v.floating;
        if (v.type == JSONType.integer)
            return cast(double) v.integer;
        return 0.0;
    }
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

string profilesDir()
{
    import std.process : environment;

    string base = environment.get("XDG_CONFIG_HOME", "");
    if (base.length == 0)
        base = buildPath(environment.get("HOME", "/tmp"), ".config");
    return buildPath(base, "omarchy-voice-studio", "profiles");
}

void saveProfile(Profile p, string dir = null)
{
    p.validate();
    string d = dir is null ? profilesDir() : dir;
    if (!exists(d))
        mkdirRecurse(d);
    write(buildPath(d, p.id ~ ".json"), p.toJsonString());
}

Profile loadProfile(string id, string dir = null)
{
    string d = dir is null ? profilesDir() : dir;
    return Profile.fromJsonString(readText(buildPath(d, id ~ ".json")));
}

Profile[] listProfiles(string dir = null)
{
    string d = dir is null ? profilesDir() : dir;
    Profile[] out_;
    if (!exists(d))
        return out_;
    foreach (e; dirEntries(d, "*.json", SpanMode.shallow))
    {
        try
        {
            auto p = Profile.fromJsonString(readText(e.name));
            p.validate();
            out_ ~= p;
        }
        catch (Exception)
        {
            // Skip invalid profiles; surface them in UI separately.
        }
    }
    return out_;
}

unittest
{
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    import std.conv : to;

    static void cleanupDir(string d) nothrow
    {
        try
        {
            rmdirRecurse(d);
        }
        catch (Exception)
        {
        }
    }

    static uint n;
    string d = buildPath(tempDir(), "ovs-prof-test-" ~ (n++).to!string);
    scope (exit)
        cleanupDir(d);

    Profile p;
    p.id = "broadcast";
    p.name = "Broadcast";
    p.input.nodeName = "alsa_input.usb-test";
    p.input.displayName = "USB Mic";
    p.inputGainDb = 0.0;
    p.outputGainDb = -1.0;
    p.channelMode = "mono";
    PluginEntry e;
    e.uri = "http://example.org/plugin/compressor";
    e.enabled = true;
    e.controls["threshold"] = -18.0;
    e.controls["ratio"] = 3.0;
    p.plugins = [e];

    saveProfile(p, d);
    auto q = loadProfile("broadcast", d);
    assert(q.id == "broadcast");
    assert(q.plugins.length == 1);
    assert(q.plugins[0].uri == "http://example.org/plugin/compressor");
    assert(listProfiles(d).length == 1);
}
