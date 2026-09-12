/**
 * LV2 discovery, inspection + instantiation via the Lilv C API.
 *
 * Threading (spec §3.2):
 *  - Discovery/inspection/instantiation run on the control thread
 *    (may allocate, do I/O, dlopen).
 *  - The RT side only calls the plugin's `run()` through the function
 *    pointer captured at build time (see audio.graph). Lilv is never
 *    touched from RT.
 *  - Plugin identity is always the URI, never the bundle path (spec §3.3).
 *  - Graceful degradation: no lilv / no plugins / missing URI => empty
 *    results + explicit errors, never a crash (spec §3.4).
 */
module audio.lv2;

import core.stdc.stdint : uint32_t;

// ---------------------------------------------------------------------------
// Lilv extern(C) bindings (only what we use; verified against lilv.h)
// ---------------------------------------------------------------------------

extern (C) struct LilvWorld;
extern (C) struct LilvPlugins;
extern (C) struct LilvPlugin;
extern (C) struct LilvNode;
extern (C) struct LilvPort;
extern (C) struct LilvScalePoints;
extern (C) struct LilvScalePoint;
extern (C) struct LilvIter;
extern (C) struct LilvInstance;
extern (C) struct LilvPluginClass;
extern (C) struct LilvNodes;

extern (C) nothrow @nogc
{
    LilvWorld* lilv_world_new();
    void lilv_world_load_all(LilvWorld* world);
    void lilv_world_free(LilvWorld* world);
    const(LilvPlugins)* lilv_world_get_all_plugins(const(LilvWorld)* world);
    uint lilv_plugins_size(const(LilvPlugins)* plugins);
    LilvIter* lilv_plugins_begin(const(LilvPlugins)* plugins);
    const(LilvPlugin)* lilv_plugins_get(const(LilvPlugins)* plugins, const(LilvIter)* i);
    LilvIter* lilv_plugins_next(const(LilvPlugins)* plugins, LilvIter* i);
    const(LilvPlugin)* lilv_plugins_get_by_uri(const(LilvPlugins)* plugins, const(LilvNode)* uri);
    const(LilvNode)* lilv_plugin_get_uri(const(LilvPlugin)* plugin);
    const(LilvNode)* lilv_plugin_get_name(const(LilvPlugin)* plugin);
    const(LilvNode)* lilv_plugin_get_author_name(const(LilvPlugin)* plugin);
    const(LilvPluginClass)* lilv_plugin_get_class(const(LilvPlugin)* plugin);
    const(LilvNode)* lilv_plugin_class_get_label(const(LilvPluginClass)* plugin_class);
    LilvNodes* lilv_plugin_get_value(const(LilvPlugin)* plugin, const(LilvNode)* predicate);
    void lilv_nodes_free(LilvNodes* collection);
    LilvIter* lilv_nodes_begin(const(LilvNodes)* collection);
    const(LilvNode)* lilv_nodes_get(const(LilvNodes)* collection, const(LilvIter)* i);
    LilvIter* lilv_nodes_next(const(LilvNodes)* collection, LilvIter* i);
    const(char)* lilv_node_as_uri(const(LilvNode)* node);
    const(char)* lilv_node_as_string(const(LilvNode)* node);
    float lilv_node_as_float(const(LilvNode)* node);
    bool lilv_node_is_float(const(LilvNode)* node);
    bool lilv_node_is_int(const(LilvNode)* node);
    int lilv_node_as_int(const(LilvNode)* node);
    LilvNode* lilv_new_uri(LilvWorld* world, const(char)* uri);
    void lilv_node_free(LilvNode* node);
    uint32_t lilv_plugin_get_num_ports(const(LilvPlugin)* plugin);
    void lilv_plugin_get_port_ranges_float(const(LilvPlugin)* plugin,
        float* min_values, float* max_values, float* def_values);
    bool lilv_plugin_is_replaced(const(LilvPlugin)* plugin);
    const(LilvPort)* lilv_plugin_get_port_by_index(const(LilvPlugin)* plugin, uint32_t index);
    bool lilv_port_is_a(const(LilvPlugin)* plugin, const(LilvPort)* port, const(LilvNode)* port_class);
    bool lilv_port_has_property(const(LilvPlugin)* plugin, const(LilvPort)* port, const(LilvNode)* property);
    const(LilvNode)* lilv_port_get_symbol(const(LilvPlugin)* plugin, const(LilvPort)* port);
    const(LilvNode)* lilv_port_get_name(const(LilvPlugin)* plugin, const(LilvPort)* port);
    LilvScalePoints* lilv_port_get_scale_points(const(LilvPlugin)* plugin, const(LilvPort)* port);
    void lilv_scale_points_free(LilvScalePoints* collection);
    uint lilv_scale_points_size(const(LilvScalePoints)* collection);
    LilvIter* lilv_scale_points_begin(const(LilvScalePoints)* collection);
    const(LilvScalePoint)* lilv_scale_points_get(const(LilvScalePoints)* collection, const(LilvIter)* i);
    LilvIter* lilv_scale_points_next(const(LilvScalePoints)* collection, LilvIter* i);
    const(LilvNode)* lilv_scale_point_get_label(const(LilvScalePoint)* point);
    const(LilvNode)* lilv_scale_point_get_value(const(LilvScalePoint)* point);
    LilvInstance* lilv_plugin_instantiate(const(LilvPlugin)* plugin,
        double sample_rate, const(LV2Feature)** features);
    void lilv_instance_free(LilvInstance* instance);
    void lilv_instance_activate(LilvInstance* instance);
    void lilv_instance_deactivate(LilvInstance* instance);
}

// LV2 descriptor + Lilv instance layouts (ABI, control thread reads only).
extern (C) struct LV2Descriptor
{
    const(char)* uri;
    void* instantiate;
    void function(void* instance, uint port, void* data) connectPort;
    void function(void* instance) activate;
    void function(void* instance, uint nframes) run;
    void function(void* instance) deactivate;
    void function(void* instance) cleanup;
    void* function(const(char)* uri) extensionData;
}

extern (C) struct LilvInstanceImpl
{
    const(LV2Descriptor)* descriptor;
    void* handle;
    void* pimpl;
}

// LV2 feature structs (ABI from lv2core + urid extension).
extern (C) struct LV2Feature
{
    const(char)* uri;
    void* data;
}

extern (C) struct LV2UridMap
{
    void* handle;
    uint function(void* handle, const(char)* uri) map;
}

extern (C) struct LV2UridUnmap
{
    void* handle;
    const(char)* function(void* handle, uint urid) unmap;
}

// LV2 options feature (required by DPF/Zam hosts): null-terminated array
// of LV2_Options_Option. Values are host constants (process lifetime).
extern (C) struct LV2OptionsOption
{
    uint context; // 0 = instance
    uint subject; // 0 = global
    uint key; // URID
    uint size;
    uint type; // URID of atom type
    const(void)* value;
}

enum LV2_URID_MAP_URI = "http://lv2plug.in/ns/ext/urid#map";
enum LV2_URID_UNMAP_URI = "http://lv2plug.in/ns/ext/urid#unmap";
enum LV2_OPTIONS_URI = "http://lv2plug.in/ns/ext/options#options";
enum LV2_BUF_SIZE_BOUNDED = "http://lv2plug.in/ns/ext/buf-size#boundedBlockLength";
enum LV2_BUF_SIZE_FIXED = "http://lv2plug.in/ns/ext/buf-size#fixedBlockLength";
enum LV2_BUF_SIZE_NOMINAL = "http://lv2plug.in/ns/ext/buf-size#nominalBlockLength";
enum LV2_PARAMS_RATE = "http://lv2plug.in/ns/ext/parameters#sampleRate";

// ---------------------------------------------------------------------------
// Process-global URID table (host duty for urid:map/unmap).
//
// URIDs are process-global by spec, so one shared table is correct.
// Fixed capacity, atomic claim: lookups never allocate; inserts copy the
// URI string once. Inserts happen on the control thread during
// instantiate/activate (plus pre-registered URIs below); a plugin mapping
// a never-before-seen URI from its RT run() would allocate once —
// therefore the table is warmed with the standard extensions at startup.
// ---------------------------------------------------------------------------

struct UridTable
{
    enum uint MAX = 1024;
    string[MAX] uris = void; // written once per slot, then immutable
    shared uint count;

    void register(string uri) nothrow
    {
        try
        {
            mapUri(uri);
        }
        catch (Exception)
        {
        }
    }

    uint mapUri(string uri) nothrow
    {
        import core.atomic : atomicFetchAdd, MemoryOrder;

        try
        {
            uint n = count;
            if (n > MAX)
                n = MAX;
            foreach (i; 0 .. n)
            {
                if (uris[i] == uri)
                    return i + 1; // 0 reserved = invalid
            }
            if (n >= MAX)
                return n > 0 ? n : 1; // table full: best effort
            uint slot = atomicFetchAdd(count, 1u);
            if (slot >= MAX)
                return MAX;
            uris[slot] = uri.idup;
            return slot + 1;
        }
        catch (Exception)
        {
            return 1;
        }
    }

    string unmapUri(uint urid) nothrow
    {
        try
        {
            if (urid == 0 || urid - 1 >= count || urid - 1 >= MAX)
                return null;
            return uris[urid - 1];
        }
        catch (Exception)
        {
            return null;
        }
    }
}

__gshared UridTable gUrids;
__gshared LV2UridMap gUridMap;
__gshared LV2UridUnmap gUridUnmap;
// LV2 Feature structs must outlive every instance (plugins keep the
// pointers for run()). The instantiate call takes an array of POINTERS.
__gshared LV2Feature gMapFeature;
__gshared LV2Feature gUnmapFeature;
__gshared LV2Feature gOptionsFeature;
__gshared const(LV2Feature)*[4] gFeaturePtrs;
// Options values (process lifetime).
__gshared float gOptRate = 48000.0f;
__gshared int gOptMinBlock = 1;
__gshared int gOptMaxBlock = 4096;
__gshared int gOptNominalBlock = 1024;
__gshared LV2OptionsOption[5] gOptions;

extern (C) uint uridMapCb(void* handle, const(char)* uri)
{
    if (uri is null)
        return 0;
    try
    {
        import std.string : fromStringz;

        return gUrids.mapUri(fromStringz(uri).idup);
    }
    catch (Exception)
    {
        return 0;
    }
}

extern (C) const(char)* uridUnmapCb(void* handle, uint urid)
{
    try
    {
        import std.string : toStringz;

        auto s = gUrids.unmapUri(urid);
        if (s.length == 0)
            return null;
        return s.toStringz;
    }
    catch (Exception)
    {
        return null;
    }
}

shared static this()
{
    // Warm the table with standard extension URIs (control thread).
    static immutable string[] common = [
        "http://lv2plug.in/ns/ext/atom#AtomPort",
        "http://lv2plug.in/ns/ext/atom#Sequence",
        "http://lv2plug.in/ns/ext/atom#Tuple",
        "http://lv2plug.in/ns/ext/atom#Vector",
        "http://lv2plug.in/ns/ext/atom#String",
        "http://lv2plug.in/ns/ext/atom#Int",
        "http://lv2plug.in/ns/ext/atom#Long",
        "http://lv2plug.in/ns/ext/atom#Float",
        "http://lv2plug.in/ns/ext/atom#Double",
        "http://lv2plug.in/ns/ext/atom#Bool",
        "http://lv2plug.in/ns/ext/atom#URID",
        "http://lv2plug.in/ns/ext/atom#Blank",
        "http://lv2plug.in/ns/ext/atom#Resource",
        "http://lv2plug.in/ns/ext/atom#Path",
        "http://lv2plug.in/ns/ext/atom#Literal",
        "http://lv2plug.in/ns/ext/atom#frameTime",
        "http://lv2plug.in/ns/ext/atom#beatsPerMinute",
        "http://lv2plug.in/ns/ext/midi#MidiEvent",
        "http://lv2plug.in/ns/ext/patch#Set",
        "http://lv2plug.in/ns/ext/patch#Get",
        "http://lv2plug.in/ns/ext/patch#Put",
        "http://lv2plug.in/ns/ext/patch#Remove",
        "http://lv2plug.in/ns/ext/patch#Copy",
        "http://lv2plug.in/ns/ext/patch#Move",
        "http://lv2plug.in/ns/ext/patch#Add",
        "http://lv2plug.in/ns/ext/patch#Delete",
        "http://lv2plug.in/ns/ext/patch#Clear",
        "http://lv2plug.in/ns/ext/patch#subject",
        "http://lv2plug.in/ns/ext/patch#property",
        "http://lv2plug.in/ns/ext/patch#value",
        "http://lv2plug.in/ns/ext/urid#map",
        "http://lv2plug.in/ns/ext/urid#unmap",
        "http://lv2plug.in/ns/ext/buf-size#boundedBlockLength",
        "http://lv2plug.in/ns/ext/buf-size#fixedBlockLength",
        "http://lv2plug.in/ns/ext/buf-size#nominalBlockLength",
        "http://lv2plug.in/ns/ext/parameters#sampleRate",
        "http://lv2plug.in/ns/ext/port-props#supportsStrictBounds",
        "http://lv2plug.in/ns/ext/port-props#expensive",
        "http://lv2plug.in/ns/ext/port-props#causesArtifacts",
        "http://lv2plug.in/ns/ext/port-props#continuousCV",
        "http://lv2plug.in/ns/ext/port-props#discreteCV",
        "http://lv2plug.in/ns/ext/port-props#logarithmic",
        "http://lv2plug.in/ns/ext/port-props#trigger",
        "http://lv2plug.in/ns/ext/state#StateChanged",
        "http://lv2plug.in/ns/ext/state#makePath",
        "http://lv2plug.in/ns/ext/worker#schedule",
        "http://lv2plug.in/ns/ext/worker#interface",
        "http://lv2plug.in/ns/ext/log#log",
        "http://lv2plug.in/ns/ext/options#options",
        "http://lv2plug.in/ns/ext/options#interface",
        "http://lv2plug.in/ns/ext/resize-port#minimumSize",
        "http://lv2plug.in/ns/ext/resize-port#asLargeAs",
        "http://lv2plug.in/ns/lv2core#toggled",
        "http://lv2plug.in/ns/lv2core#integer",
        "http://lv2plug.in/ns/lv2core#enumeration",
        "http://lv2plug.in/ns/lv2core#connectionOptional",
        "http://lv2plug.in/ns/lv2core#reportsLatency",
        "http://lv2plug.in/ns/lv2core#inPlaceBroken",
        "http://lv2plug.in/ns/lv2core#isLive",
    ];
    foreach (u; common)
        gUrids.register(u);
    gUridMap.handle = null;
    gUridMap.map = &uridMapCb;
    gUridUnmap.handle = null;
    gUridUnmap.unmap = &uridUnmapCb;
    gMapFeature.uri = LV2_URID_MAP_URI;
    gMapFeature.data = &gUridMap;
    gUnmapFeature.uri = LV2_URID_UNMAP_URI;
    gUnmapFeature.data = &gUridUnmap;
    // Options (DPF et al. require the feature to exist; values describe
    // this host: 48 kHz engine, blocks up to maxFrames 4096).
    gUrids.register(LV2_OPTIONS_URI);
    gUrids.register(LV2_BUF_SIZE_BOUNDED);
    gUrids.register(LV2_BUF_SIZE_FIXED);
    gUrids.register(LV2_BUF_SIZE_NOMINAL);
    gUrids.register(LV2_PARAMS_RATE);
    gUrids.register("http://lv2plug.in/ns/ext/atom#Float");
    gUrids.register("http://lv2plug.in/ns/ext/atom#Int");
    uint floatT = gUrids.mapUri("http://lv2plug.in/ns/ext/atom#Float");
    uint intT = gUrids.mapUri("http://lv2plug.in/ns/ext/atom#Int");
    gOptions[0] = LV2OptionsOption(0, 0, gUrids.mapUri(LV2_PARAMS_RATE),
        4, floatT, &gOptRate);
    gOptions[1] = LV2OptionsOption(0, 0, gUrids.mapUri(LV2_BUF_SIZE_BOUNDED),
        4, intT, &gOptMaxBlock);
    gOptions[2] = LV2OptionsOption(0, 0, gUrids.mapUri(LV2_BUF_SIZE_FIXED),
        4, intT, &gOptMaxBlock);
    gOptions[3] = LV2OptionsOption(0, 0, gUrids.mapUri(LV2_BUF_SIZE_NOMINAL),
        4, intT, &gOptNominalBlock);
    gOptions[4] = LV2OptionsOption(0, 0, 0, 0, 0, null);
    gOptionsFeature.uri = LV2_OPTIONS_URI;
    gOptionsFeature.data = gOptions.ptr;
    gFeaturePtrs[0] = &gMapFeature;
    gFeaturePtrs[1] = &gUnmapFeature;
    gFeaturePtrs[2] = &gOptionsFeature;
    gFeaturePtrs[3] = null;
}

// Well-known LV2 URIs (content is the ABI; created via lilv_new_uri).
enum LV2_URI_INPUT = "http://lv2plug.in/ns/lv2core#InputPort";
enum LV2_URI_OUTPUT = "http://lv2plug.in/ns/lv2core#OutputPort";
enum LV2_URI_AUDIO = "http://lv2plug.in/ns/lv2core#AudioPort";
enum LV2_URI_CONTROL = "http://lv2plug.in/ns/lv2core#ControlPort";
enum LV2_URI_TOGGLED = "http://lv2plug.in/ns/lv2core#toggled";
enum LV2_URI_INTEGER = "http://lv2plug.in/ns/lv2core#integer";
enum LV2_URI_ENUMERATION = "http://lv2plug.in/ns/lv2core#enumeration";
enum LV2_URI_CONNECTION_OPTIONAL = "http://lv2plug.in/ns/lv2core#connectionOptional";
enum LV2_URI_ATOM = "http://lv2plug.in/ns/ext/atom#AtomPort";
enum LV2_URI_EVENT = "http://lv2plug.in/ns/ext/event#EventPort";

// ---------------------------------------------------------------------------
// D-side model
// ---------------------------------------------------------------------------

struct Lv2ScalePoint
{
    string label;
    float value;
}

struct Lv2PortInfo
{
    uint index;
    bool isAudio;
    bool isInput;
    bool isOutput;
    bool isControl;
    bool isMessage; // atom/event port (dummy-connected, UI shows a note)
    bool isOptional;
    bool isToggled;
    bool isInteger;
    bool isEnum;
    string symbol;
    string name;
    float def;
    float min;
    float max;
    bool hasDef;
    bool hasRange;
    Lv2ScalePoint[] scalePoints;
}

struct Lv2PluginInfo
{
    string uri;
    string name;
    string vendor;
    string clazz;
    uint audioInputs;
    uint audioOutputs;
    uint controlInputs;
    uint messagePorts; // atom/event message ports (dummy-connected, see below)
    bool hasUnsupportedPorts; // CV/etc. (never silently adapted)
    Lv2PortInfo[] ports;

    bool supportedForMvp() const pure nothrow @safe
    {
        if (hasUnsupportedPorts)
            return false;
        if (audioInputs == 0 || audioOutputs == 0)
            return false;
        // Extra audio inputs (sidechain) are tied to silence; outputs must
        // fit mono/stereo.
        if (audioInputs > 4 || audioOutputs > 2)
            return false;
        return true;
    }

    /// Audio port LV2 indices, input or output.
    uint[] audioPortIndices(bool wantInput) const @safe
    {
        uint[] idx;
        foreach (ref p; ports)
            if (p.isAudio && ((wantInput && p.isInput) || (!wantInput && p.isOutput)))
                idx ~= p.index;
        return idx;
    }

    /// Control input ports in index order.
    const(Lv2PortInfo)[] controlInputs_() const @safe
    {
        const(Lv2PortInfo)[] r;
        foreach (ref p; ports)
            if (p.isControl && p.isInput)
                r ~= p;
        return r;
    }
}

/// Instantiated plugin (control thread owns lifetime).
struct Lv2Handle
{
    LilvInstance* instance; // null when invalid
    void* lv2handle;
    extern (C) void function(void* instance, uint nframes) nothrow @nogc run;
    extern (C) void function(void* instance, uint port, void* data) nothrow @nogc connect;
    bool valid;
    string error;
}

// ---------------------------------------------------------------------------
// Discovery (cheap metadata; never instantiates — spec §12)
// ---------------------------------------------------------------------------

/// Discover installed LV2 plugins. Never throws: returns empty on failure.
Lv2PluginInfo[] discoverPlugins() nothrow
{
    try
    {
        auto w = Lv2World.create();
        if (w is null)
            return null;
        return w.discover();
    }
    catch (Exception)
    {
        return null;
    }
}

/// Plugin class label ("Equaliser", "Dynamics", ...) for search display.
/// Reads rdf:type values and maps known LV2 plugin subclasses to friendly
/// names (upstream lv2core only labels the generic base classes).
/// Never throws; empty when unavailable.
string pluginClassLabel(LilvWorld* world, const(LilvPlugin)* plugin) nothrow
{
    try
    {
        import std.string : fromStringz, lastIndexOf;

        if (world is null)
            return null;
        auto pred = lilv_new_uri(world,
            "http://www.w3.org/1999/02/22-rdf-syntax-ns#type");
        if (pred is null)
            return null;
        scope (exit)
            lilv_node_free(pred);
        auto vals = lilv_plugin_get_value(plugin, pred);
        if (vals is null)
            return null;
        scope (exit)
            lilv_nodes_free(vals);
        string best;
        for (auto it = lilv_nodes_begin(vals); it !is null; it = lilv_nodes_next(vals, it))
        {
            auto n = lilv_nodes_get(vals, it);
            if (n is null)
                continue;
            auto u = lilv_node_as_uri(n);
            if (u is null)
                continue;
            string uri = fromStringz(u).idup;
            auto h = uri.lastIndexOf('#');
            string frag = h >= 0 ? uri[h + 1 .. $] : uri;
            string label = classNickname(frag);
            if (label.length > 0 && (best.length == 0 || label.length < best.length))
                best = label; // prefer the most specific short name
        }
        return best;
    }
    catch (Exception)
    {
        return null;
    }
}

/// Cheap per-plugin metadata (uri/name/vendor/class). Shared by
/// discovery and inspection so the two never drift apart.
private Lv2PluginInfo describeBasic(LilvWorld* world, const(LilvPlugin)* p)
{
    import std.string : fromStringz;

    Lv2PluginInfo info;
    auto uri = lilv_plugin_get_uri(p);
    if (uri !is null)
    {
        auto s = lilv_node_as_uri(uri);
        if (s !is null)
            info.uri = fromStringz(s).idup;
    }
    if (info.uri.length == 0)
        return info;
    auto name = lilv_plugin_get_name(p);
    if (name !is null)
    {
        auto s = lilv_node_as_string(name);
        if (s !is null)
            info.name = fromStringz(s).idup;
    }
    if (info.name.length == 0)
        info.name = info.uri;
    info.clazz = pluginClassLabel(world, p);
    auto vendor = lilv_plugin_get_author_name(p);
    if (vendor !is null)
    {
        auto s = lilv_node_as_string(vendor);
        if (s !is null)
            info.vendor = fromStringz(s).idup;
    }
    // Discovery keeps counts cheap; full classification happens in
    // inspect (control thread, on demand).
    info.audioInputs = 1;
    info.audioOutputs = 1;
    return info;
}

private string classNickname(string frag) nothrow pure @safe{
    switch (frag)
    {
    case "LimiterPlugin":
        return "Limiter";
    case "CompressorPlugin":
        return "Compressor";
    case "ExpanderPlugin":
        return "Expander";
    case "GatePlugin":
        return "Gate";
    case "ParaEQPlugin":
    case "EQPlugin":
    case "GraphicEQPlugin":
    case "FilterPlugin":
        return "Equaliser";
    case "DelayPlugin":
        return "Delay";
    case "ReverbPlugin":
        return "Reverb";
    case "DistortionPlugin":
    case "OverdrivePlugin":
    case "WaveshaperPlugin":
        return "Distortion";
    case "ChorusPlugin":
    case "FlangerPlugin":
    case "PhaserPlugin":
        return "Modulation";
    case "AmplifierPlugin":
        return "Amplifier";
    case "GeneratorPlugin":
    case "InstrumentPlugin":
        return "Instrument";
    case "AnalyserPlugin":
        return "Analyser";
    case "UtilityPlugin":
        return "Utility";
    case "SpatialPlugin":
        return "Spatial";
    case "PitchPlugin":
        return "Pitch";
    case "SimulatorPlugin":
        return "Simulator";
    case "DynamicsPlugin":
        return "Dynamics";
    default:
        return null;
    }
}

/// Case-insensitive substring search over already-discovered metadata.
Lv2PluginInfo[] searchPlugins(Lv2PluginInfo[] all, string query) @safe
{
    import std.string : toLower, indexOf;

    if (query.length == 0)
        return all.dup;
    auto q = query.toLower();
    Lv2PluginInfo[] hits;
    foreach (ref p; all)
    {
        string hay = (p.name ~ " " ~ p.vendor ~ " " ~ p.clazz ~ " " ~ p.uri).toLower();
        if (hay.indexOf(q) >= 0)
            hits ~= p;
    }
    return hits;
}

// ---------------------------------------------------------------------------
// World: cached Lilv state for inspection + instantiation (control thread)
// ---------------------------------------------------------------------------

final class Lv2World
{
private:
    LilvWorld* _world;
    LilvNode* _in;
    LilvNode* _out;
    LilvNode* _audio;
    LilvNode* _control;
    LilvNode* _toggled;
    LilvNode* _integer;
    LilvNode* _enumeration;
    LilvNode* _optional;
    LilvNode* _atom;
    LilvNode* _event;

public:
    /// Returns null when Lilv/world is unavailable (graceful: no LV2).
    static Lv2World create() nothrow
    {
        try
        {
            auto w = new Lv2World();
            if (!w.open())
                return null;
            return w;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private bool open()
    {
        _world = lilv_world_new();
        if (_world is null)
            return false;
        lilv_world_load_all(_world);
        _in = lilv_new_uri(_world, LV2_URI_INPUT);
        _out = lilv_new_uri(_world, LV2_URI_OUTPUT);
        _audio = lilv_new_uri(_world, LV2_URI_AUDIO);
        _control = lilv_new_uri(_world, LV2_URI_CONTROL);
        _toggled = lilv_new_uri(_world, LV2_URI_TOGGLED);
        _integer = lilv_new_uri(_world, LV2_URI_INTEGER);
        _enumeration = lilv_new_uri(_world, LV2_URI_ENUMERATION);
        _optional = lilv_new_uri(_world, LV2_URI_CONNECTION_OPTIONAL);
        _atom = lilv_new_uri(_world, LV2_URI_ATOM);
        _event = lilv_new_uri(_world, LV2_URI_EVENT);
        return _in !is null && _audio !is null && _control !is null;
    }

    ~this()
    {
        // Nodes are owned by the world; free world only.
        if (_world !is null)
        {
            lilv_world_free(_world);
            _world = null;
        }
    }

    /// Cheap metadata sweep (never instantiates — spec §12).
    Lv2PluginInfo[] discover()
    {
        Lv2PluginInfo[] out_;
        if (_world is null)
            return out_;
        auto all = lilv_world_get_all_plugins(_world);
        if (all is null)
            return out_;
        // NOTE: lilv_plugins_get takes an iterator, NOT an index.
        // Passing integers here segfaults (found via gdb in zix_tree_get).
        for (auto it = lilv_plugins_begin(all); it !is null; it = lilv_plugins_next(all, it))
        {
            auto p = lilv_plugins_get(all, it);
            if (p is null)
                continue;
            auto info = describeBasic(_world, p);
            if (info.uri.length == 0)
                continue;
            out_ ~= info;
        }
        return out_;
    }

    /// Full port classification for one plugin URI. Throws on missing plugin.
    Lv2PluginInfo inspect(string uri)
    {
        import std.exception : enforce;
        import std.string : fromStringz;

        enforce(_world !is null, "LV2 unavailable");
        auto all = lilv_world_get_all_plugins(_world);
        enforce(all !is null, "LV2 plugin list unavailable");

        import std.string : toStringz;

        auto key = lilv_new_uri(_world, uri.toStringz);
        enforce(key !is null, "out of memory");
        scope (exit)
            lilv_node_free(key);
        auto plugin = lilv_plugins_get_by_uri(all, key);
        enforce(plugin !is null, "plugin not installed: " ~ uri);

        Lv2PluginInfo info;
        info.uri = uri;
        auto basic = describeBasic(_world, plugin);
        info.name = basic.name.length ? basic.name : uri;
        info.vendor = basic.vendor;
        info.clazz = basic.clazz;

        uint32_t n = lilv_plugin_get_num_ports(plugin);
        float[] mins = new float[n];
        float[] maxs = new float[n];
        float[] defs = new float[n];
        lilv_plugin_get_port_ranges_float(plugin, mins.ptr, maxs.ptr, defs.ptr);

        import std.math : isNaN;

        foreach (i; 0 .. n)
        {
            auto port = lilv_plugin_get_port_by_index(plugin, i);
            if (port is null)
            {
                info.hasUnsupportedPorts = true;
                continue;
            }
            Lv2PortInfo pi;
            pi.index = i;
            pi.isInput = lilv_port_is_a(plugin, port, _in);
            pi.isOutput = lilv_port_is_a(plugin, port, _out);
            pi.isAudio = lilv_port_is_a(plugin, port, _audio);
            pi.isControl = lilv_port_is_a(plugin, port, _control);
            pi.isOptional = lilv_port_has_property(plugin, port, _optional);
            bool isMessage = false;
            if (_atom !is null && lilv_port_is_a(plugin, port, _atom))
                isMessage = true;
            if (_event !is null && lilv_port_is_a(plugin, port, _event))
                isMessage = true;
            if (isMessage)
            {
                // Atom/event message ports (x42 `control`/`notify`, ...).
                // The host dummy-connects an empty buffer: the plugin's
                // message interface stays inert, audio/control unaffected.
                // Surfaced in the UI as a note, never silent.
                pi.isMessage = true;
                info.messagePorts++;
                fillPortNames(plugin, port, pi);
                info.ports ~= pi;
                continue;
            }
            if (!pi.isAudio && !pi.isControl)
            {
                // CVPort etc. — explicit, never silent (spec §15/§41).
                info.hasUnsupportedPorts = true;
                continue;
            }
            if (pi.isControl && pi.isInput)
            {
                pi.isToggled = lilv_port_has_property(plugin, port, _toggled);
                pi.isInteger = lilv_port_has_property(plugin, port, _integer);
                pi.isEnum = lilv_port_has_property(plugin, port, _enumeration);
                float lo = mins[i], hi = maxs[i], dv = defs[i];
                if (!isNaN(lo) && !isNaN(hi) && hi > lo)
                {
                    pi.min = lo;
                    pi.max = hi;
                    pi.hasRange = true;
                }
                else
                {
                    pi.min = pi.isToggled ? 0 : 0;
                    pi.max = pi.isToggled ? 1 : 1;
                }
                if (!isNaN(dv))
                {
                    pi.def = dv;
                    pi.hasDef = true;
                }
                else
                    pi.def = pi.min;
                auto sp = lilv_port_get_scale_points(plugin, port);
                if (sp !is null)
                {
                    scope (exit)
                        lilv_scale_points_free(sp);
                    for (auto it = lilv_scale_points_begin(sp); it !is null;
                        it = lilv_scale_points_next(sp, it))
                    {
                        auto p = lilv_scale_points_get(sp, it);
                        if (p is null)
                            continue;
                        Lv2ScalePoint spt;
                        auto lab = lilv_scale_point_get_label(p);
                        if (lab !is null)
                        {
                            auto s = lilv_node_as_string(lab);
                            if (s !is null)
                                spt.label = fromStringz(s).idup;
                        }
                        auto val = lilv_scale_point_get_value(p);
                        if (val !is null)
                        {
                            if (lilv_node_is_float(val))
                                spt.value = lilv_node_as_float(val);
                            else if (lilv_node_is_int(val))
                                spt.value = cast(float) lilv_node_as_int(val);
                            else
                                continue;
                        }
                        else
                            continue;
                        pi.scalePoints ~= spt;
                    }
                    if (pi.scalePoints.length > 0 && !pi.hasRange)
                    {
                        // Derive range from enumeration values.
                        float lo2 = pi.scalePoints[0].value, hi2 = lo2;
                        foreach (ref s2; pi.scalePoints)
                        {
                            if (s2.value < lo2)
                                lo2 = s2.value;
                            if (s2.value > hi2)
                                hi2 = s2.value;
                        }
                        pi.min = lo2;
                        pi.max = hi2;
                        pi.hasRange = true;
                    }
                }
            }
            fillPortNames(plugin, port, pi);
            info.ports ~= pi;
            if (pi.isAudio && pi.isInput)
                info.audioInputs++;
            if (pi.isAudio && pi.isOutput)
                info.audioOutputs++;
            if (pi.isControl && pi.isInput)
                info.controlInputs++;
        }
        return info;
    }

    private static void fillPortNames(const(LilvPlugin)* plugin, const(LilvPort)* port, ref Lv2PortInfo pi)
    {
        import std.string : fromStringz;

        auto sym = lilv_port_get_symbol(plugin, port);
        if (sym !is null)
        {
            auto s = lilv_node_as_string(sym);
            if (s !is null)
                pi.symbol = fromStringz(s).idup;
        }
        auto nm = lilv_port_get_name(plugin, port);
        if (nm !is null)
        {
            auto s = lilv_node_as_string(nm);
            if (s !is null)
                pi.name = fromStringz(s).idup;
        }
        if (pi.name.length == 0)
            pi.name = pi.symbol;
    }

    /// Instantiate a plugin at `rate`. Returns invalid handle + error text
    /// instead of throwing into audio code (caller converts to slot state).
    Lv2Handle instantiate(string uri, double rate)
    {
        Lv2Handle h;
        try
        {
            import std.string : toStringz;
            import std.exception : enforce;

            enforce(_world !is null, "LV2 unavailable");
            auto all = lilv_world_get_all_plugins(_world);
            enforce(all !is null, "LV2 plugin list unavailable");
            auto key = lilv_new_uri(_world, uri.toStringz);
            enforce(key !is null, "out of memory");
            scope (exit)
                lilv_node_free(key);
            auto plugin = lilv_plugins_get_by_uri(all, key);
            enforce(plugin !is null, "plugin not installed: " ~ uri);
            auto inst = lilv_plugin_instantiate(plugin, rate, gFeaturePtrs.ptr);
            enforce(inst !is null, "instantiation failed: " ~ uri);
            auto impl = cast(const(LilvInstanceImpl)*) inst;
            enforce(impl !is null && impl.descriptor !is null, "bad instance");
            h.instance = inst;
            h.lv2handle = cast(void*) impl.handle;
            h.run = cast(typeof(h.run)) impl.descriptor.run;
            h.connect = cast(typeof(h.connect)) impl.descriptor.connectPort;
            enforce(h.run !is null, "plugin has no run()");
            // Activate on the control thread (may be null = no-op).
            if (impl.descriptor.activate !is null)
                impl.descriptor.activate(cast(void*) impl.handle);
            h.valid = true;
        }
        catch (Exception e)
        {
            if (h.instance !is null)
            {
                lilv_instance_free(h.instance);
                h.instance = null;
            }
            h.valid = false;
            h.error = e.msg;
        }
        return h;
    }

    /// Deactivate + free (control thread only, never RT).
    static void closeInstance(ref Lv2Handle h) nothrow
    {
        try
        {
            if (h.instance !is null)
            {
                auto impl = cast(const(LilvInstanceImpl)*) h.instance;
                if (impl !is null && impl.descriptor !is null && impl.descriptor.deactivate !is null)
                {
                    try
                        impl.descriptor.deactivate(cast(void*) impl.handle);
                    catch (Exception)
                    {
                    }
                }
                lilv_instance_free(h.instance);
            }
        }
        catch (Exception)
        {
        }
        h.instance = null;
        h.lv2handle = null;
        h.valid = false;
    }
}

unittest
{
    Lv2PluginInfo a;
    a.uri = "http://example.org/compressor";
    a.name = "Example Compressor";
    a.vendor = "Example";
    a.audioInputs = 1;
    a.audioOutputs = 1;
    Lv2PluginInfo b;
    b.uri = "http://example.org/reverb";
    b.name = "Big Reverb";
    b.audioInputs = 2;
    b.audioOutputs = 2;
    auto all = [a, b];
    assert(searchPlugins(all, "").length == 2);
    assert(searchPlugins(all, "compressor").length == 1);
    assert(searchPlugins(all, "COMPRESSOR").length == 1);
    assert(searchPlugins(all, "nope").length == 0);
    assert(a.supportedForMvp());
    Lv2PluginInfo bad;
    bad.audioInputs = 8;
    bad.audioOutputs = 8;
    assert(!bad.supportedForMvp());
    Lv2PluginInfo atom;
    atom.audioInputs = 1;
    atom.audioOutputs = 1;
    atom.hasUnsupportedPorts = true;
    assert(!atom.supportedForMvp());
}
