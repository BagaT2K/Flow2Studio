// Port of mac/FlowUpdates.m. Release checks use the bundled ui/update-config.json repository configuration.
using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Flow2Studio;

static class FlowUpdates
{
    const string CheckFailed = "Не удалось проверить обновления. Попробуйте позже.";
    static string releaseURL;
    static JsonObject cachedResult;
    static DateTime lastCheck;
    static bool checking;
    static readonly List<Action<JsonObject, string>> waiters = new();

    static string[] Parts(string value)
    {
        if (value == null) return null;
        if (value.StartsWith('v')) value = value[1..];
        var items = value.Split('.');
        if (items.Length < 2 || items.Length > 3) return null;
        foreach (var item in items) if (item.Length == 0 || item.Length > 6 || !item.All(c => c >= '0' && c <= '9')) return null;
        return items;
    }
    public static int CompareVersions(string left, string right)
    {
        string[] a = Parts(left), b = Parts(right); if (a == null || b == null) return 0;
        for (int i = 0; i < 3; i++) { long x = i < a.Length ? long.Parse(a[i]) : 0, y = i < b.Length ? long.Parse(b[i]) : 0; if (x != y) return x > y ? 1 : -1; }
        return 0;
    }
    static void Finish(JsonObject result, string error)
    {
        checking = false; if (result != null) { cachedResult = result; lastCheck = DateTime.UtcNow; }
        var callbacks = waiters.ToList(); waiters.Clear();
        foreach (var callback in callbacks) callback((JsonObject)result?.DeepClone(), error);
    }
    /* Called on the UI thread; completions run on the UI thread. */
    public static async void Check(bool force, Action<JsonObject, string> completion)
    {
        if (!force && cachedResult != null && (DateTime.UtcNow - lastCheck).TotalSeconds < 21600) { completion((JsonObject)cachedResult.DeepClone(), null); return; }
        waiters.Add(completion);
        if (checking) return; checking = true;
        JsonObject config = null;
        try { config = JsonNode.Parse(File.ReadAllText(Program.ResourcePath("ui", "update-config.json"))) as JsonObject; } catch { }
        config ??= new JsonObject();
        string repo = J.Str(config["repository"]) ?? "";
        var components = repo.Split('/');
        bool valid = components.Length == 2 && components.All(c => c.Length > 0 && !c.StartsWith('.') && c.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '-' or '_' or '.'));
        if (!valid) { Finish(J.O(("configured", false), ("preview", J.Bool(config["preview"]))), null); return; }
        JsonArray payload;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{repo}/releases?per_page=20");
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.UserAgent.ParseAdd("Flow2Studio");
            request.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            if ((int)response.StatusCode != 200 || response.Content.Headers.ContentLength > 2 * 1024 * 1024) { Finish(null, CheckFailed); return; }
            var data = await response.Content.ReadAsByteArrayAsync();
            if (data.Length > 2 * 1024 * 1024) { Finish(null, CheckFailed); return; }
            payload = JsonNode.Parse(data) as JsonArray;
        }
        catch { payload = null; }
        if (payload == null) { Finish(null, CheckFailed); return; }
        string current = Program.Version, latest = current, tag = null;
        foreach (var item in payload.OfType<JsonObject>())
        {
            if (!J.IsNumber(item["draft"]) || !J.IsNumber(item["prerelease"])) continue;
            if (J.Bool(item["draft"]) || (J.Bool(item["prerelease"]) && J.Str(config["channel"]) != "prerelease")) continue;
            string version = J.Str(item["tag_name"]);
            if (Parts(version) != null && CompareVersions(version, latest) > 0) { latest = version.StartsWith('v') ? version[1..] : version; tag = version; }
        }
        // Construct the browser link from the configured repository, never from remote release text.
        releaseURL = $"https://github.com/{repo}/releases" + (tag != null ? "/tag/" + tag : "");
        Finish(J.O(("configured", true), ("available", tag != null), ("version", latest), ("preview", false)), null);
    }
    public static bool OpenUpdate()
    {
        if (!J.Bool(cachedResult?["available"]) || releaseURL == null) return false;
        return Program.OpenUrl(releaseURL);
    }
}
