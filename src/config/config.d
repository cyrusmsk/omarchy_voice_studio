/**
 * Persistent app configuration (non-profile settings).
 *
 * Location: $XDG_CONFIG_HOME/omarchy-voice-studio/config.json
 * (fallback ~/.config/...). Never stores runtime state.
 */
module config.config;

import std.json;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;

enum string APP_ID = "com.omarchy.VoiceStudio";
enum string APP_NAME = "Omarchy Voice Studio";

struct AppConfig
{
    string activeProfileId = "broadcast";
    bool startHeadless;
    bool autoStartBackend = true;
    string lastInputNode;
    // Style mode: "system" (desktop default), "omarchy", "dark", "light".
    string styleMode = "system";

    JSONValue toJson() const
    {
        return JSONValue([
            "activeProfileId": JSONValue(activeProfileId),
            "startHeadless": JSONValue(startHeadless),
            "autoStartBackend": JSONValue(autoStartBackend),
            "lastInputNode": JSONValue(lastInputNode),
            "styleMode": JSONValue(styleMode),
        ]);
    }

    static AppConfig fromJson(JSONValue v)
    {
        AppConfig c;
        if ("activeProfileId" in v)
            c.activeProfileId = v["activeProfileId"].str;
        if ("startHeadless" in v)
            c.startHeadless = v["startHeadless"].boolean;
        if ("autoStartBackend" in v)
            c.autoStartBackend = v["autoStartBackend"].boolean;
        if ("lastInputNode" in v)
            c.lastInputNode = v["lastInputNode"].str;
        if ("styleMode" in v)
            c.styleMode = v["styleMode"].str;
        return c;
    }
}

string configDir()
{
    import std.process : environment;

    string base = environment.get("XDG_CONFIG_HOME", "");
    if (base.length == 0)
        base = buildPath(environment.get("HOME", "/tmp"), ".config");
    return buildPath(base, "omarchy-voice-studio");
}

string configPath(string dir = null)
{
    string d = dir is null ? configDir() : dir;
    return buildPath(d, "config.json");
}

AppConfig loadConfig(string dir = null)
{
    string p = configPath(dir);
    if (!exists(p))
        return AppConfig.init;
    try
    {
        import std.json : parseJSON;

        return AppConfig.fromJson(parseJSON(readText(p)));
    }
    catch (Exception)
    {
        return AppConfig.init;
    }
}

void saveConfig(AppConfig c, string dir = null)
{
    string d = dir is null ? configDir() : dir;
    if (!exists(d))
        mkdirRecurse(d);
    write(configPath(d), c.toJson().toPrettyString());
}

unittest
{
    AppConfig c;
    c.activeProfileId = "discord";
    auto s = c.toJson().toString();
    auto d = AppConfig.fromJson(parseJSON(s));
    assert(d.activeProfileId == "discord");
}
