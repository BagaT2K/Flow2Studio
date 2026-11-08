// Port of mac/FlowLocalization.m. Reads the same catalog the web UI uses: ui/locales.json.
using System.Text;
using System.Text.Json.Nodes;

namespace Flow2Studio;

static class FlowLocalization
{
    static readonly string[] Languages = { "en", "zh", "ja", "ko", "es", "de", "ru" };
    static JsonObject catalog;
    static List<string> keys;
    static Dictionary<string, string> reverse;

    public static bool LanguageSupported(string language) => language != null && Languages.Contains(language);
    public static string CurrentLanguage() { string language = FlowPreferences.String("language"); return LanguageSupported(language) ? language : "en"; }
    static void Load()
    {
        if (catalog != null) return;
        try { catalog = JsonNode.Parse(File.ReadAllText(Program.ResourcePath("ui", "locales.json"))) as JsonObject; } catch { }
        catalog ??= new JsonObject();
        keys = catalog.Select(p => p.Key).OrderByDescending(k => k.Length).ThenBy(k => k, StringComparer.Ordinal).ToList();
        reverse = new Dictionary<string, string>();
        foreach (var key in keys)
            if (catalog[key] is JsonObject values)
                foreach (var (_, value) in values) if (J.Str(value) is string v) reverse.TryAdd(v, key);
    }
    static string Lookup(string key, string language) => J.Str(catalog[key]?[language]) ?? J.Str(catalog[key]?["en"]);
    public static string Localized(string source)
    {
        if (string.IsNullOrEmpty(source)) return source;
        Load();
        string language = CurrentLanguage();
        string key = catalog.ContainsKey(source) ? source : reverse.GetValueOrDefault(source);
        if (key != null) return Lookup(key, language) ?? source;
        /* Protect replacements from being translated again by scanning the source once. */
        var result = new StringBuilder(); int offset = 0;
        while (offset < source.Length)
        {
            int best = -1, length = 0; string found = null;
            foreach (var candidate in keys)
            {
                int index = source.IndexOf(candidate, offset, StringComparison.Ordinal);
                if (index >= 0 && (best < 0 || index < best || (index == best && candidate.Length > length))) { best = index; length = candidate.Length; found = candidate; }
            }
            if (found == null) { result.Append(source, offset, source.Length - offset); break; }
            result.Append(source, offset, best - offset).Append(Lookup(found, language) ?? found);
            offset = best + found.Length;
        }
        return result.ToString();
    }
}
