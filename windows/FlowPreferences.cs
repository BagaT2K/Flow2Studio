// NSUserDefaults replacement: one JSON document in %APPDATA%\Flow2Studio\preferences.json,
// plus JSON helpers that reproduce the NSNumber/NSDictionary semantics the mac host relies on.
// FlowMigratePreferences (import from older macOS bundle identifiers) has no Windows counterpart.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Flow2Studio;

static class FlowPreferences
{
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Flow2Studio");
    static readonly string FilePath = Path.Combine(Root, "preferences.json");
    static readonly object Sync = new();
    static JsonObject values;
    static readonly Dictionary<string, JsonNode> Defaults = new()
    {
        ["theme"] = "dark", ["batteryStyle"] = "keyboardPercent", ["autoCharge"] = true, ["editingConnection"] = true,
    };

    static JsonObject Values()
    {
        if (values != null) return values;
        try { values = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject; } catch { }
        return values ??= new JsonObject();
    }
    /* Returns a detached copy, like an NSUserDefaults read. */
    public static JsonNode Get(string key)
    {
        lock (Sync) return (Values()[key] ?? (Defaults.TryGetValue(key, out var d) ? d : null))?.DeepClone();
    }
    public static void Set(string key, JsonNode value)
    {
        lock (Sync)
        {
            var all = Values();
            if (value == null) all.Remove(key); else all[key] = J.Own(value);
            Directory.CreateDirectory(Root);
            string temp = FilePath + ".tmp";
            using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write))
            {
                JsonSerializer.Serialize(stream, all, new JsonSerializerOptions { WriteIndented = true });
                stream.Flush(true);
            }
            File.Move(temp, FilePath, true);
        }
    }
    public static string String(string key) => Get(key) is JsonValue v && v.TryGetValue(out string s) ? s : null;
    public static bool Bool(string key) => J.Bool(Get(key));
    public static JsonObject Dictionary(string key) => Get(key) as JsonObject;
    public static JsonArray Array(string key) => Get(key) as JsonArray;
}

/* NSNumber/NSString/NSDictionary helpers. JSON numbers and booleans are both "NSNumber". */
static class J
{
    public static JsonNode Own(JsonNode n) => n == null ? null : n.Parent == null ? n : n.DeepClone();
    public static JsonNode V(object v) => v switch
    {
        null => null,
        JsonNode n => Own(n),
        string s => JsonValue.Create(s),
        bool b => JsonValue.Create(b),
        int i => JsonValue.Create(i),
        uint u => JsonValue.Create(u),
        long l => JsonValue.Create(l),
        ulong ul => JsonValue.Create(ul),
        double d => JsonValue.Create(d),
        byte by => JsonValue.Create((int)by),
        _ => throw new ArgumentException(v.GetType().Name),
    };
    public static JsonObject O(params (string key, object value)[] pairs)
    {
        var o = new JsonObject();
        foreach (var (k, v) in pairs) o[k] = V(v);
        return o;
    }
    public static JsonArray A(IEnumerable<object> items)
    {
        var a = new JsonArray();
        foreach (var item in items) a.Add(V(item));
        return a;
    }
    public static bool IsNumber(JsonNode n) => n is JsonValue v && (v.GetValueKind() is JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False);
    public static bool IsString(JsonNode n) => n is JsonValue v && v.GetValueKind() == JsonValueKind.String;
    public static string Str(JsonNode n) => IsString(n) ? n.GetValue<string>() : null;
    public static double Double(JsonNode n)
    {
        if (n is not JsonValue v) return 0;
        switch (v.GetValueKind())
        {
            // Values built in C# keep their CLR type (int, long...), so GetValue<double> throws; parse the JSON text instead.
            case JsonValueKind.Number: return double.Parse(v.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);
            case JsonValueKind.True: return 1;
            case JsonValueKind.String:
                var s = v.GetValue<string>().TrimStart(); int end = 0;
                while (end < s.Length && (char.IsDigit(s[end]) || (end == 0 && (s[0] == '-' || s[0] == '+')) || s[end] == '.')) end++;
                return double.TryParse(s[..end], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double d) ? d : 0;
            default: return 0;
        }
    }
    /* -[NSNumber intValue]: truncation toward zero. */
    public static int Int(JsonNode n) { double d = Double(n); return d >= int.MaxValue ? int.MaxValue : d <= int.MinValue ? int.MinValue : (int)d; }
    public static uint UInt(JsonNode n) => unchecked((uint)(long)Double(n));
    public static bool Bool(JsonNode n)
    {
        if (n is JsonValue v && v.GetValueKind() == JsonValueKind.String)
        {
            var s = v.GetValue<string>().TrimStart();
            return s.Length > 0 && ("YyTt".Contains(s[0]) || (char.IsDigit(s[0]) && Double(n) != 0));
        }
        return Double(n) != 0;
    }
    /* [x isEqual:@YES] */
    public static bool IsYes(JsonNode n) => IsNumber(n) && Double(n) == 1;
    /* -[NSObject isEqual:] for property-list values. */
    public static bool Same(JsonNode a, JsonNode b)
    {
        if (a == null || b == null) return a == null && b == null;
        if (IsNumber(a) || IsNumber(b)) return IsNumber(a) && IsNumber(b) && Double(a) == Double(b);
        if (IsString(a) || IsString(b)) return IsString(a) && IsString(b) && a.GetValue<string>() == b.GetValue<string>();
        if (a is JsonArray x && b is JsonArray y) { if (x.Count != y.Count) return false; for (int i = 0; i < x.Count; i++) if (!Same(x[i], y[i])) return false; return true; }
        if (a is JsonObject p && b is JsonObject q) { if (p.Count != q.Count) return false; foreach (var (k, v) in p) if (!q.TryGetPropertyValue(k, out var w) || !Same(v, w)) return false; return true; }
        return false;
    }
    public static bool Contains(IEnumerable<string> list, JsonNode n) => Str(n) is string s && list.Contains(s);
    public static string Json(JsonNode n) => n?.ToJsonString() ?? "null";
}
