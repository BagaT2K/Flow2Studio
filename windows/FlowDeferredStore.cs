// Port of mac/FlowDeferredStore.m: settings queued while the keyboard sleeps, persisted under deferredSettings.v1.
using System.Text.Json.Nodes;

namespace Flow2Studio;

static class FlowDeferredStore
{
    const string Key = "deferredSettings.v1";
    static readonly string[] Accepted = { "lighting", "profile", "advanced", "setTouch", "setKey", "setLayer", "saveMacros" };
    public static bool Accepts(string action) => Accepted.Contains(action);

    static JsonObject NormalizedLighting(JsonObject args)
    {
        if (J.Str(args["effectFamily"]) == "zones-v1") return args;
        var safe = (JsonObject)args.DeepClone(); if (J.UInt(safe["effect"]) > 1) safe["effect"] = 1;
        safe["waveSpeed"] = 1; safe["effectFamily"] = "zones-v1"; return safe;
    }
    public static JsonArray Jobs(string key)
    {
        if (key == null || FlowPreferences.Dictionary(Key)?[key] is not JsonArray jobs) return new JsonArray();
        bool changed = false;
        for (int i = 0; i < jobs.Count; i++)
            if (jobs[i] is JsonObject job && J.Str(job["action"]) == "lighting" && J.Str(job["args"]?["effectFamily"]) != "zones-v1")
            { var m = (JsonObject)job.DeepClone(); m["args"] = J.Own(NormalizedLighting(job["args"] as JsonObject ?? new JsonObject())); jobs[i] = m; changed = true; }
        if (changed) Save(jobs, key);
        return jobs;
    }
    static void Save(JsonArray jobs, string key)
    {
        var all = FlowPreferences.Dictionary(Key) ?? new JsonObject();
        if (jobs.Count > 0) all[key] = J.Own(jobs); else all.Remove(key);
        FlowPreferences.Set(Key, all);
    }
    static JsonObject Args(JsonNode job) => job?["args"] as JsonObject ?? new JsonObject();
    public static JsonObject Enqueue(string action, JsonObject arguments, string key)
    {
        if (string.IsNullOrEmpty(key) || !Accepts(action)) return null;
        var args = (JsonObject)(action == "lighting" ? NormalizedLighting(arguments) : arguments).DeepClone();
        if (action is "lighting" or "profile" or "advanced") args["persist"] = true;
        var jobs = Jobs(key);
        string slot = action == "setKey" ? $"key:{Text(args["layer"])}:{Text(args["row"])}:{Text(args["col"])}" : action == "setLayer" ? $"layer:{Text(args["layer"])}" : action;
        if (action == "setTouch" && J.IsYes(args["keepActive"])) slot = $"touch-profile:{Text(args["count"])}";
        if (action == "setKey")
            foreach (var old in jobs.OfType<JsonObject>())
            {
                if (old["error"] != null || J.Str(old["action"]) != "setLayer" || !J.Same(Args(old)["layer"], args["layer"])) continue;
                var merged = (JsonObject)Args(old).DeepClone(); var keys = merged["keys"] as JsonArray ?? new JsonArray();
                int cols = keys.Count == 108 ? 18 : 15; int rows = keys.Count / cols;
                if (keys.Count != 75 && keys.Count != 90 && keys.Count != 108) continue;
                int row = J.Int(args["row"]), col = J.Int(args["col"]); if (row < 0 || col < 0 || row >= rows || col >= cols) continue;
                keys[row * cols + col] = J.Own(args["code"]); args = merged; action = "setLayer"; slot = J.Str(old["slot"]); break;
            }
        if (action == "saveMacros") foreach (var old in jobs.OfType<JsonObject>()) if (old["error"] == null && J.Str(old["slot"]) == slot) args["expected"] = J.Own(Args(old)["expected"]);
        if (action == "setKey")
            foreach (var old in jobs.OfType<JsonObject>())
                if (old["error"] == null && J.Str(old["slot"]) == slot)
                {
                    if (Args(old)["previous"] != null) args["previous"] = J.Own(Args(old)["previous"]);
                    if (Args(old)["expectedCode"] != null) args["expectedCode"] = J.Own(Args(old)["expectedCode"]);
                }
        if (action == "setLayer")
        {
            var expected = args["expected"]?.DeepClone() as JsonArray;
            foreach (var old in jobs.OfType<JsonObject>())
            {
                if (old["error"] != null || !J.Same(Args(old)["layer"], args["layer"])) continue;
                if (J.Str(old["action"]) == "setLayer") { expected = Args(old)["expected"]?.DeepClone() as JsonArray; break; }
                if (J.Str(old["action"]) == "setKey" && expected != null && (expected.Count == 75 || expected.Count == 90 || expected.Count == 108))
                {
                    int cols = expected.Count == 108 ? 18 : 15; long pos = (long)J.UInt(Args(old)["row"]) * cols + J.UInt(Args(old)["col"]);
                    if (pos < expected.Count && Args(old)["previous"] != null && J.Same(expected[(int)pos], Args(old)["code"])) expected[(int)pos] = J.Own(Args(old)["previous"]);
                }
            }
            if (expected != null) args["expected"] = expected;
        }
        for (int i = jobs.Count - 1; i >= 0; i--)
            if (J.Str(jobs[i]?["slot"]) == slot || (action == "setLayer" && J.Str(jobs[i]?["action"]) == "setKey" && J.Same(Args(jobs[i])["layer"], args["layer"]))) jobs.RemoveAt(i);
        var job = J.O(("id", Guid.NewGuid().ToString().ToUpperInvariant()), ("action", action), ("slot", slot), ("args", args));
        jobs.Add(job); Save(jobs, key); return (JsonObject)job.DeepClone();
    }
    /* NSString %@ formatting of a plist value. */
    static string Text(JsonNode n) => n == null ? "(null)" : J.IsString(n) ? J.Str(n) : n.ToJsonString();
    public static void Complete(string jobID, string key)
    {
        var jobs = Jobs(key);
        for (int i = jobs.Count - 1; i >= 0; i--) if (J.Str(jobs[i]?["id"]) == jobID) jobs.RemoveAt(i);
        Save(jobs, key);
    }
    public static void Block(string jobID, string message, string key)
    {
        var jobs = Jobs(key);
        for (int i = 0; i < jobs.Count; i++)
            if (J.Str(jobs[i]?["id"]) == jobID) { var blocked = (JsonObject)jobs[i].DeepClone(); blocked["error"] = message ?? "Изменение не подтверждено"; jobs[i] = blocked; break; }
        Save(jobs, key);
    }
    public static void Clear(string key) => Save(new JsonArray(), key);
}
