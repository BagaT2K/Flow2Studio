// Port of mac/FlowTransport.m and mac/FlowTouchTransport.inc.
// IOKit HID -> Win32 HID (setupapi/hid.dll). All HID work runs on one dedicated worker thread
// (FlowHID), which also delivers input reports, like the mac FlowHIDThread run loop.
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Flow2Studio;

sealed record FlowError(string Domain, int Code, string Message);
/* NSError ** equivalent. A null slot discards the error like passing NULL. */
sealed class ErrorSlot { public FlowError Value; }

/* The serial HID worker: one thread for device creation, input delivery, I/O and teardown. */
static class FlowHID
{
    static readonly List<Session> Attached = new();
    static readonly ConcurrentQueue<Action> Queue = new();
    static readonly AutoResetEvent Signal = new(false);
    static readonly object StartLock = new();
    static Thread worker;

    public static double Uptime => Environment.TickCount64 / 1000.0;
    public static void Enqueue(Action action)
    {
        lock (StartLock)
            if (worker == null) { worker = new Thread(Run) { IsBackground = true, Name = "Flow2Studio HID" }; worker.Start(); }
        Queue.Enqueue(action); Signal.Set();
    }
    static void Run()
    {
        for (; ; )
        {
            while (Queue.TryDequeue(out var action))
            {
                try { action(); }
                catch (Exception e) { System.Diagnostics.Trace.WriteLine("Flow2Studio HID worker: " + e); }
            }
            Pump(Timeout.Infinite, Signal);
        }
    }
    public static void Attach(Session s) { Attached.Add(s); s.Reading = s.Port.StartRead(); }
    public static void Detach(Session s) => Attached.Remove(s);
    /* Deliver at most one input report; returns early when `wake` is signaled. Worker thread only. */
    public static void Pump(int milliseconds, WaitHandle wake = null)
    {
        var live = Attached.Where(s => s.Reading).ToList();
        var handles = new List<WaitHandle>();
        if (wake != null) handles.Add(wake);
        handles.AddRange(live.Select(s => s.Port.ReadReady));
        if (handles.Count == 0) { Thread.Sleep(Math.Max(milliseconds, 0)); return; }
        int index = WaitHandle.WaitAny(handles.ToArray(), milliseconds);
        if (index == WaitHandle.WaitTimeout) return;
        index -= wake != null ? 1 : 0;
        if (index < 0) return;
        var session = live[index];
        byte[] report = session.Port.FinishRead();
        // A failed read means the device went away; stop reading instead of spinning.
        session.Reading = report != null && session.Port.StartRead();
        if (report != null) session.AcceptReport(report);
    }
    public static void Wait(int milliseconds)
    {
        double until = Uptime + milliseconds / 1000.0;
        while (Uptime < until) Pump(20);
    }
}

sealed class Session : IDisposable
{
    readonly Flow.WakeScope wake = new();
    readonly Flow.HIDResponse response = new();
    public Native.HidPort Port;
    public bool Reading, Ble, Serial, WindowLease, EditingDark, ProfileBase14, TouchClosing;
    public uint TouchToken;
    public Action<uint> TouchPoint;
    public JsonObject Device;

    public void AcceptTouchPacket(ReadOnlySpan<byte> bytes)
    {
        uint position = Flow.TouchLivePosition(bytes, (uint)J.Int(Device["model"]), TouchToken);
        if (position != 0) TouchPoint?.Invoke(position);
    }
    /* Windows input reports carry the report ID byte; unnumbered reports arrive as 33 bytes with a leading 0. */
    public void AcceptReport(byte[] bytes)
    {
        if (!Ble)
        {
            ReadOnlySpan<byte> payload = bytes;
            if (payload.Length == 33 && payload[0] == 0) payload = payload[1..];
            AcceptTouchPacket(payload);
        }
        response.Accept(true, true, 0, bytes);
    }
    public bool Packet(byte[] request, byte[] reply, ErrorSlot error)
    {
        double now = FlowHID.Uptime;
        if (Flow.WakeDue(wake, now))
        {
            byte[] nonce = FlowTransport.Nonce(); bool renewed;
            if (WindowLease)
            {
                byte[] p = Flow.ControlRequest(8, EditingDark ? 2u : 1u, 0, 0, nonce), r = new byte[32];
                renewed = RawPacket(p, r, error) && Flow.ControlMatch(p, r) && r[5] == 0;
                if (renewed) wake.RenewedAt = now;
            }
            else renewed = Flow.WakeRefresh(wake, now, nonce, (p, r) => RawPacket(p, r, error));
            if (!renewed)
            {
                if (error == null || error.Value == null) FlowTransport.Fail(error, "Клавиатура не подтвердила продолжение операции. Команда не отправлена.");
                return false;
            }
        }
        return RawPacket(request, reply, error);
    }
    public bool RawPacket(byte[] request, byte[] reply, ErrorSlot error)
    {
        if (Serial)
        {
            byte[] data = TouchClosing ? FlowBLESerial.ExchangeConnected(Device, request, error) : FlowBLESerial.Exchange(Device, request, error);
            if (data == null || data.Length != 32) return false;
            Array.Copy(data, reply, 32); return true;
        }
        // One stable reader per open collection; the worker thread pumps input while waiting.
        byte[] wire = new byte[32];
        if (Ble && !Flow.BleEncode(request, wire)) { FlowTransport.Fail(error, "Пакет не помещается в служебный BLE-отчёт"); return false; }
        response.Begin(request, Ble);
        // Report ID prefix: 0 for the unnumbered USB vendor report, 3 for the BLE vendor report.
        var report = new byte[Port.OutputLength];
        if (Ble) Array.Copy(wire, 0, report, 0, Math.Min(32, report.Length));
        else Array.Copy(request, 0, report, 1, Math.Min(32, report.Length - 1));
        bool written = Port.Write(report, 2000);
        double deadline = FlowHID.Uptime + (Ble ? 3 : 2);
        while (written && response.Done == 0 && FlowHID.Uptime < deadline) FlowHID.Pump(20);
        // A report arriving after timeout/completion is ignored until a new request.
        response.End();
        if (!written || response.Done != 1)
        {
            if (Ble) FlowTransport.Fail(error, $"BLE: нет подтверждённого ответа на 0x{request[0]:x2} (SetReport={(written ? 0 : 1)}, отчётов ID 3: {response.Reports}, последняя длина: {response.LastLength}, проверка: {response.Done}).");
            else FlowTransport.Fail(error, response.Done == -1 ? "Эта команда не поддерживается прошивкой" : "Нет корректного ответа. Нажми клавишу, закрой VIA и обнови устройство.");
            return false;
        }
        Array.Copy(response.Reply, reply, 32); return true;
    }
    public void ReleaseEditing()
    {
        WindowLease = false;
        Flow.WakeReleaseEditing(wake, FlowTransport.Nonce(), (p, r) => RawPacket(p, r, new ErrorSlot()));
    }
    public bool BeginOperation(ErrorSlot error)
    {
        bool ok = Flow.WakeBegin(wake, FlowHID.Uptime, FlowTransport.Nonce(), (p, r) => RawPacket(p, r, error));
        if (!ok && (error == null || error.Value == null)) FlowTransport.Fail(error, "Клавиатура не подтвердила запрос пробуждения.");
        return ok;
    }
    public void EndOperation()
    {
        if (WindowLease) return;
        Flow.WakeEnd(wake, FlowTransport.Nonce(), (p, r) => RawPacket(p, r, new ErrorSlot()));
    }
    public void Dispose()
    {
        response.End();
        if (Port != null) { FlowHID.Detach(this); Port.Dispose(); Port = null; Reading = false; }
    }
}

static class FlowTransport
{
    public static void Fail(ErrorSlot error, string message) { if (error != null) error.Value = new FlowError("Flow2Studio", 1, message); }
    static void Offline(ErrorSlot error) { if (error != null) error.Value = new FlowError("Flow2Studio", 2, "Клавиатура спит или не отвечает. Изменения можно сохранить до восстановления связи."); }
    public static byte[] Nonce() => RandomNumberGenerator.GetBytes(4);
    static uint Model(JsonObject device) => (uint)J.Int(device["model"]);

    static string ModelName(string name, int pid)
    {
        foreach (var count in new[] { "68", "84", "100" }) if (name.Contains(count)) return count;
        return pid switch { 1 => "68", 2 => "84", 3 => "100", _ => "" };
    }
    public static bool FlowName(string name) => name != null && string.Concat(name.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c))).Contains("flow2");
    static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value.ToLowerInvariant())))[..16].ToLowerInvariant();

    /* Transport of a HID collection: a Bluetooth enumerator above it, otherwise USB. */
    static string Transport(uint devInst, out string node)
    {
        node = null;
        for (uint n = Native.Parent(devInst); n != 0; n = Native.Parent(n))
        {
            string id = Native.DeviceID(n), upper = id.ToUpperInvariant();
            if (upper.StartsWith(@"BTHLEDEVICE\") || upper.StartsWith(@"BTHENUM\")) { node = id; return "Bluetooth"; }
            if (!upper.StartsWith(@"HID\")) { node = id; return "USB"; }
        }
        return "USB";
    }

    public static JsonArray Devices()
    {
        var connections = new Dictionary<string, JsonObject>();
        foreach (var hid in Native.Interfaces(Native.HidGuid()))
        {
            var info = Native.QueryHid(hid.Path);
            if (info == null || !FlowName(info.Name)) continue;
            string transport = Transport(hid.DevInst, out string parentNode);
            bool bleTransport = transport == "Bluetooth";
            string name = info.Name, model = ModelName(name, 0);
            // Windows has no raw report descriptor; the vendor collection shape stands in for flow_ble_descriptor.
            bool ble = bleTransport && info.UsagePage == 0xff00 && info.InputLength == 32 && info.OutputLength == 32;
            bool vendor = (bleTransport && Flow.ModelFor(J.Int(model)).Number != 0) || (!bleTransport && info.UsagePage == 0xff60 && info.Usage == 0x61);
            uint usbNode = bleTransport ? 0 : Native.UsbAncestor(hid.DevInst);
            string usbLocation = usbNode != 0 ? Native.LocationPath(usbNode) : null;
            string location = usbLocation ?? parentNode ?? Hash(hid.Path);
            string serial = info.Serial ?? "", usable = serial.Trim('0', ' ', '-');
            string key = $"{info.Product}-{transport}-{(usable.Length > 0 ? serial : location)}";
            if (connections.ContainsKey(key) && !vendor) continue;
            string route = bleTransport ? "Bluetooth" : info.Version == 0x2004 ? "2.4 ГГц" : "USB";
            var d = J.O(("id", "hid-" + Hash(hid.Path)), ("key", key), ("name", name), ("model", ModelName(name, info.Product)), ("connection", route),
                ("vendor", vendor), ("ble", ble), ("pid", (int)info.Product), ("version", (int)info.Version), ("serial", serial), ("vid", (int)info.Vendor), ("path", hid.Path));
            if (usbLocation != null) d["usbLocation"] = usbLocation;
            connections[key] = d;
        }
        // Read already connected paired devices only. Never initiate a connection.
        // This fallback is view-only until a matching configuration HID service exists.
        foreach (var (btName, address) in FlowBluetooth.ConnectedDevices())
        {
            if (!FlowName(btName)) continue;
            if (connections.Values.Any(d => J.Str(d["connection"]) == "Bluetooth" && J.Str(d["name"]) == btName)) continue;
            string key = "Bluetooth-" + (address ?? btName), model = ModelName(btName, 0);
            connections[key] = J.O(("id", key), ("key", key), ("name", btName), ("model", model), ("connection", "Bluetooth"),
                ("vendor", Flow.ModelFor(J.Int(model)).Number != 0), ("pid", 0), ("version", 0), ("serial", ""));
        }
        return J.A(connections.Values.OrderBy(d => J.Str(d["key"]), StringComparer.Ordinal));
    }

    // ---- FlowTouchTransport.inc ---- Requests are serialized by Studio.
    static bool TouchArguments(JsonNode node)
    {
        if (node is not JsonObject v) return false;
        foreach (var name in new[] { "count", "b1", "b2" }) if (!J.IsNumber(v[name])) return false;
        int count = J.Int(v["count"]), b1 = J.Int(v["b1"]), b2 = J.Int(v["b2"]);
        if (count < 1 || count > 3 || b1 < 15 || b1 > 85 || b2 < 30 || b2 > 85 || (count == 3 && b2 < b1 + 15)) return false;
        if (v["actions"] is not JsonArray modes || modes.Count != 2) return false;
        foreach (var mode in modes)
        {
            if (mode is not JsonArray values || values.Count != 9) return false;
            foreach (var value in values) { if (!J.IsNumber(value)) return false; int n = J.Int(value); if (n < 0 || !Flow.TouchAction((uint)n)) return false; }
        }
        return true;
    }
    static JsonObject TouchReply(byte[] r)
    {
        var actions = new JsonArray();
        for (uint i = 0; i < 9; i++) actions.Add((int)Flow.TouchBits(r.AsSpan(10), i));
        return J.O(("count", r[7]), ("b1", r[8]), ("b2", r[9]), ("mode", r[6]), ("actions", actions));
    }
    static bool TouchExchange(Session s, uint op, uint mode, uint slot, JsonObject config, uint token, byte[] output, ErrorSlot error)
    {
        var p = new byte[32];
        p[0] = 0x18; p[1] = (byte)'L'; p[2] = (byte)'F'; p[3] = (byte)'T'; p[4] = 2; p[5] = (byte)op; p[6] = (byte)mode; p[7] = (byte)slot;
        if (config != null)
        {
            p[7] = (byte)J.UInt(config["count"]); p[8] = (byte)J.UInt(config["b1"]); p[9] = (byte)J.UInt(config["b2"]);
            for (uint i = 0; i < 9; i++) Flow.TouchPack(p.AsSpan(10), i, J.UInt(config["actions"][(int)mode][(int)i]));
        }
        p[21] = (byte)J.Int(s.Device["model"]); RandomNumberGenerator.Fill(p.AsSpan(22, 4)); BitConverter.TryWriteBytes(p.AsSpan(26, 4), token);
        if (!s.Packet(p, output, error)) return false;
        if (Flow.TouchMatch(p, output) && output[5] == 3) { Fail(error, "Touch Bar: could not save settings to the keyboard. The previous assignment is still active."); return false; }
        if (!Flow.TouchMatch(p, output) || output[5] != 0) { Fail(error, "Touch Bar: the keyboard did not confirm the settings. Check the connection and try again."); return false; }
        return true;
    }
    static JsonObject TouchReadConfig(Session s, uint slot, uint known, ErrorSlot error)
    {
        byte[] a = new byte[32], b = new byte[32]; uint op = slot != 0 ? 3u : 0u;
        if (!TouchExchange(s, op, 0, slot, null, 0, a, error)) return null;
        if (known != 0 && known == a[7]) return J.O(("count", known));
        if (!TouchExchange(s, op, 1, slot, null, 0, b, error)) return null;
        JsonObject first = TouchReply(a), second = TouchReply(b);
        var v = J.O(("count", first["count"]), ("b1", first["b1"]), ("b2", first["b2"]), ("actions", J.A(new object[] { first["actions"], second["actions"] })));
        if (a[26] <= 7 && a[26] == b[26]) v["savedProfiles"] = (int)a[26];
        if ((slot != 0 && a[7] != slot) || a[7] != b[7] || a[8] != b[8] || a[9] != b[9] || !TouchArguments(v)) { Fail(error, "Touch Bar: invalid device response."); return null; }
        return v;
    }
    static JsonObject TouchReadProfile(Session s, uint slot, ErrorSlot error) => TouchReadConfig(s, slot, 0, error);
    static JsonObject TouchRead(Session s, ErrorSlot error) => TouchReadProfile(s, 0, error);
    static JsonObject TouchSelect(Session s, JsonObject arguments, ErrorSlot error)
    {
        var count = arguments["count"]; int slot = J.IsNumber(count) ? J.Int(count) : 0; var r = new byte[32];
        if (slot < 1 || slot > 3) { Fail(error, "Touch Bar: invalid zones or assignments."); return null; }
        if (!TouchExchange(s, 4, 0, (uint)slot, null, 0, r, error)) return null;
        var value = TouchRead(s, error);
        if (value != null && J.Int(value["count"]) != slot) { Fail(error, "Touch Bar: retrieved settings differ from the settings sent."); return null; }
        return value;
    }
    static JsonObject TouchSet(Session s, JsonObject config, ErrorSlot error)
    {
        if (!TouchArguments(config)) { Fail(error, "Touch Bar: invalid zones or assignments."); return null; }
        uint token = BitConverter.ToUInt32(RandomNumberGenerator.GetBytes(4)); var r = new byte[32];
        bool keepActive = J.IsYes(config["keepActive"]);
        if (!TouchExchange(s, 1, 0, 0, config, token, r, error) || !TouchExchange(s, 1, 1, 0, config, token, r, error) || !TouchExchange(s, keepActive ? 5u : 2u, 0, 0, null, token, r, error)) return null;
        var v = TouchReadProfile(s, keepActive ? J.UInt(config["count"]) : 0, error); if (v == null) return null;
        foreach (var key in new[] { "count", "b1", "b2", "actions" })
            if (!J.Same(v[key], config[key])) { Fail(error, "Touch Bar: retrieved settings differ from the settings sent."); return null; }
        return v;
    }

    // ---- FlowTransport.m helpers ----
    static bool Query(Session s, byte command, byte[] reply, ErrorSlot error) { var p = new byte[32]; p[0] = command; return s.Packet(p, reply, error); }
    static byte[] ReadBuffer(Session s, bool macro, uint offset, int size, ErrorSlot error)
    {
        var data = new byte[size];
        for (int n = 0; n < size;)
        {
            uint count = Math.Min(Flow.ReadChunk(s.Ble && !s.Serial), (uint)(size - n)), o = offset + (uint)n; byte[] p = new byte[32], r = new byte[32];
            if (!Flow.BufferRequest(p, macro, o, count)) { Fail(error, "Некорректная область чтения"); return null; }
            if (!s.Packet(p, r, error)) return null;
            Array.Copy(r, 4, data, n, count); n += (int)count;
        }
        return data;
    }
    static void Backup(JsonObject device, string kind, byte[] data, ErrorSlot error)
    {
        try
        {
            string folder = Path.Combine(FlowPreferences.Root, "Backups");
            Directory.CreateDirectory(folder);
            string id = J.Str(device["id"]) ?? device["id"]?.ToJsonString() ?? "0";
            foreach (char c in Path.GetInvalidFileNameChars()) id = id.Replace(c, '_');
            string path = Path.Combine(folder, $"{kind}-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}-{id}.bin"), temp = path + ".tmp";
            File.WriteAllBytes(temp, data);
            File.Move(temp, path, true);
        }
        catch (Exception e) { if (error != null) error.Value = new FlowError("IO", 1, e.Message); }
    }
    static JsonObject Control(Session s, uint op, uint flags, uint brightness, uint seconds, ErrorSlot error)
    {
        byte[] nonce = Nonce(), p = Flow.ControlRequest(op, flags, brightness, seconds, nonce), r = new byte[32];
        if (!s.Packet(p, r, error)) return null;
        if (!Flow.ControlMatch(p, r) || !Flow.ControlModelMatches(r, Model(s.Device))) { Fail(error, $"Ответ не прошёл проверку LFC {op}/{flags} (версия {r[21]}.{r[22]}, статус {r[5]})."); return null; }
        if (r[5] != 0)
        {
            string reason = r[5] == 2 ? "Область профиля занята или команда временно недоступна. Настройки не перезаписаны." : "Клавиатура отклонила условия команды.";
            Fail(error, $"{reason} [LFC {op}/{flags}; код {r[5]}; Studio {r[21]}.{r[22]}; яркость {r[24]}%; этап {r[29]}]"); return null;
        }
        uint g = Flow.ControlGeneration(r);
        s.ProfileBase14 = g == 19 && r[23] == 0x14;
        return J.O(("base14", s.ProfileBase14), ("rf", (r[6] & 1) != 0), ("bluetooth", (r[6] & 2) != 0), ("indicatorBrightness", r[7]), ("timeout", (r[8] << 8) | r[9]),
            ("touchWake", (r[6] & 4) != 0), ("bootEntryPreserved", g >= 11), ("animationsSupported", g >= 15), ("zoneAnimationsSupported", g >= 15), ("fillAnimationSupported", g >= 16),
            ("animationMode", g >= 15 ? r[28] & 15 : 0), ("animationSpeed", g >= 15 ? r[28] >> 4 : 1), ("legacyAnimationMode", g >= 10 && g < 15 ? r[28] : 0),
            ("usbBatteryRefreshSupported", g >= 9), ("zoneTestSupported", g >= 12), ("zoneDiagnosticsSupported", g >= 13), ("zoneChargingSupported", g >= 14),
            ("zoneBlockMask", g >= 13 ? r[27] : 0), ("sleepState", g >= 13 ? r[30] : 0), ("powerState", g >= 13 ? r[31] : 0), ("zoneTestStage", g >= 12 ? r[29] : 0),
            ("independentIndicatorSupported", g >= 18), ("independentSyncBrightnessSupported", g >= 17), ("firmwareVersion", $"{r[21]}.{r[22]}"),
            ("editingSleepSupported", r[10] == 255 && g >= 3), ("fullLightSleepSupported", r[10] == 255 && g >= 4), ("rfLightGateSupported", r[10] == 255 && g >= 5),
            ("packedStateSupported", r[10] == 255 && g >= 6), ("quietReleaseSupported", r[10] == 255 && g >= 7), ("advancedSupported", g >= 8),
            ("lowBatteryThreshold", g >= 8 ? r[25] : 0), ("syncBrightness", g >= 8 && r[26] == 1), ("syncBreathing", (r[6] & 8) != 0), ("mainBrightness", r[24]),
            ("fineBrightness", true), ("keepAwakeSupported", true), ("capabilityBits", r[10]), ("model", s.Device["model"]));
    }
    static bool WriteBuffer(Session s, bool macro, byte[] data, ErrorSlot error)
    {
        int size = data.Length; var shape = Flow.ModelFor((int)Model(s.Device));
        if (shape.Number == 0 || (macro && size != shape.MacroBytes) || (!macro && size != shape.KeyBytes)) { Fail(error, "Некорректный размер памяти"); return false; }
        byte[] p = new byte[32], r = new byte[32];
        // Last byte is the stock macro-validity guard: disable invocation during transfer.
        if (macro) { Flow.BufferRequest(p, true, (uint)size - 1, 1); p[0] = 0xf; p[4] = 255; if (!s.Packet(p, r, error)) return false; }
        for (int n = 0; n < size;)
        {
            int count = Math.Min(28, size - n); Flow.BufferRequest(p, macro, (uint)n, (uint)count); p[0] = (byte)(macro ? 0xf : 0x13);
            Array.Copy(data, n, p, 4, count); if (!s.Packet(p, r, error)) return false; n += count;
        }
        var actual = ReadBuffer(s, macro, 0, size, error); if (actual == null) return false;
        if (!actual.AsSpan().SequenceEqual(data)) { Fail(error, "Проверка записанной памяти не совпала"); return false; }
        return true;
    }
    static bool SetAnimation(Session s, JsonObject profile, uint mode, uint speed, ErrorSlot error)
    {
        if (mode == 5 && !J.Bool(profile["fillAnimationSupported"])) { Fail(error, "Для режима «Водопад» обновите расширение по USB."); return false; }
        if (J.Bool(profile["zoneAnimationsSupported"]))
        {
            if (J.UInt(profile["animationMode"]) != mode || J.UInt(profile["animationSpeed"]) != speed) return Control(s, 11, mode, speed, 0, error) != null;
            return true;
        }
        if (mode != 0) { Fail(error, "Для волн и перелива обновите расширение до 3.15 по USB."); return false; }
        if (J.UInt(profile["legacyAnimationMode"]) != 0) return Control(s, 11, 0, 0, 0, error) != null;
        return true;
    }
    static bool LightingSet(Session s, uint brightness, uint effect, uint speed, ErrorSlot error)
    {
        if (effect > 6 || speed > 3) return false;
        var profile = Control(s, 1, 0, 0, 0, error); if (profile == null) return false;
        uint animation = effect > 1 ? effect - 1 : 0;
        if (!SetAnimation(s, profile, animation, speed, error)) return false;
        byte[] p = new byte[32], r = new byte[32]; p[0] = 7; p[1] = 1; p[2] = 2; p[3] = (byte)(effect != 0 ? 1 : 0);
        if (!s.Packet(p, r, error)) return false;
        p[0] = 8; if (!s.Packet(p, r, error) || (r[3] != 0) != (effect != 0)) return false;
        if (Control(s, 5, 0, brightness, 0, error) == null) return false;
        Array.Clear(p); p[0] = 9; p[1] = 1; return s.Packet(p, r, error);
    }
    static JsonArray KeyArray(ReadOnlySpan<byte> b)
    {
        var keys = new JsonArray();
        for (int i = 0; i < b.Length / 2; i++) keys.Add((b[i * 2] << 8) | b[i * 2 + 1]);
        return keys;
    }
    static byte[] KeyData(JsonNode node, Flow.Model shape, ErrorSlot error)
    {
        if (node is not JsonArray array || array.Count != shape.Positions) { Fail(error, "Число позиций не соответствует модели клавиатуры."); return null; }
        var b = new byte[shape.LayerBytes];
        for (int i = 0; i < shape.Positions; i++)
        {
            var value = array[i];
            if (!J.IsNumber(value) || J.Double(value) != J.Int(value) || J.Int(value) < 0 || J.Int(value) > 65535) { Fail(error, "Неверный код клавиши."); return null; }
            uint code = J.UInt(value); b[i * 2] = (byte)(code >> 8); b[i * 2 + 1] = (byte)code;
        }
        return b;
    }
    static bool WriteLayer(Session s, uint layer, byte[] data, ErrorSlot error)
    {
        bool Write(uint offset, byte[] chunk)
        {
            byte[] p = new byte[32], r = new byte[32];
            if (chunk.Length == 0 || chunk.Length > 28 || !Flow.BufferRequest(p, false, offset, (uint)chunk.Length)) return false;
            p[0] = 0x13; Array.Copy(chunk, 0, p, 4, chunk.Length); return s.Packet(p, r, error);
        }
        return Flow.LayerWriteVerifySized((offset, length) => ReadBuffer(s, false, offset, length, error), Write, layer, data, Flow.ModelFor((int)Model(s.Device)).LayerBytes);
    }
    static bool Equal(byte[] a, byte[] b) => a != null && b != null && a.AsSpan().SequenceEqual(b);
    static byte[] Slice(byte[] data, int offset, int length) => data.AsSpan(offset, length).ToArray();

    static JsonObject PerformAction(Session s, JsonObject device, string action, JsonObject arguments, ErrorSlot error)
    {
        byte[] r = new byte[32], p = new byte[32];
        if (action == "status")
        {
            p = Flow.Request(Nonce());
            if (!s.Packet(p, r, error)) return null;
            string reason = ""; bool queried = false;
            int version = J.Int(device["version"]);
            if (J.Str(device["connection"]) == "USB" && Flow.ModelFor((int)Model(device)).Number != 0 && (version == 9 || version == 20))
            {
                // The legacy status only reads a radio-fed RAM byte. Ask the proven
                // 3.9 extension to enqueue OEM A6/53; never send it to a USB endpoint.
                var refreshError = new ErrorSlot(); var profile = Control(s, 1, 0, 0, 0, refreshError);
                if (J.Bool(profile?["usbBatteryRefreshSupported"]))
                {
                    var got = Flow.USBBatteryRefresh((pp, rr) => s.Packet(pp, rr, refreshError), Nonce, FlowHID.Wait, r); queried = got.requested;
                    reason = got.state switch
                    {
                        Flow.USBBatteryState.Valid => "",
                        Flow.USBBatteryState.RefreshFailed => "usb-battery-refresh-failed",
                        Flow.USBBatteryState.NotWired => "usb-mode-not-confirmed",
                        Flow.USBBatteryState.QueueFull => "usb-battery-queue-unavailable",
                        Flow.USBBatteryState.Pending => "usb-radio-battery-pending",
                        _ => "usb-battery-read-failed",
                    };
                }
                else reason = "usb-extension-update";
            }
            return J.O(("valid", (r[5] & 1) != 0 && r[6] <= 100), ("percent", r[6]), ("power", (r[5] & 2) != 0), ("full", (r[5] & 6) == 6), ("usbBatteryRequested", queried), ("batteryReason", reason));
        }
        if (action == "syncTouchProfile")
        {
            var model = Flow.ModelFor((int)Model(device));
            var known = arguments["known"]; int count = J.IsNumber(known) ? J.Int(known) : 0;
            if (model.Number == 0 || (!s.Ble && J.UInt(device["pid"]) != model.Pid) || count < 1 || count > 3) { Fail(error, "Touch Bar: invalid zones or assignments."); return null; }
            return TouchReadConfig(s, 0, (uint)count, error);
        }
        // A USB receiver alone is not proof that the keyboard is online.
        // Require the nonce-correlated keyboard response before enabling configuration.
        var alive = Flow.Request(Nonce());
        if (!s.Packet(alive, r, new ErrorSlot()))
        {
            // Retry only a nonce read. Never replay a settings write after an ambiguous result.
            alive = Flow.Request(Nonce());
            if (!s.Packet(alive, r, new ErrorSlot())) { Offline(error); return null; }
        }
        if (action == "wake") return J.O(("online", true));
        if (!Query(s, 1, r, error)) return null;
        int protocol = (r[1] << 8) | r[2];
        var shape = Flow.ModelFor((int)Model(device));
        if (shape.Number == 0 || (!s.Ble && J.UInt(device["pid"]) != shape.Pid) || protocol != 12) { Fail(error, "Настройка этой модели ещё не проверена. Доступен просмотр устройства."); return null; }
        int LB = shape.LayerBytes;
        if (action == "importTouchProfile")
        {
            if (!TouchArguments(arguments)) { Fail(error, "Touch Bar: invalid zones or assignments."); return null; }
            uint slot = J.UInt(arguments["count"]);
            var current = TouchReadProfile(s, slot, error);
            if (current == null || current["savedProfiles"] == null || (J.UInt(current["savedProfiles"]) & (1u << (int)(slot - 1))) != 0) return current;
            var config = (JsonObject)arguments.DeepClone(); config["keepActive"] = true;
            return TouchSet(s, config, error);
        }
        if (action == "selectTouchProfile") return TouchSelect(s, arguments, error);
        if (action == "readTouch" || action == "setTouch") return action == "setTouch" ? TouchSet(s, arguments, error) : TouchRead(s, error);
        if (action == "capabilities")
        {
            var result = J.O(("protocol", protocol), ("rows", shape.Rows), ("cols", shape.Cols), ("positions", shape.Positions));
            if (!Query(s, 0x11, r, error)) return null;
            if (r[1] == 0 || r[1] > 16) { Fail(error, "Неизвестная структура слоёв"); return null; }
            result["layers"] = (int)r[1];
            if (!Query(s, 0xc, r, error)) return null; result["macros"] = (int)r[1];
            if (!Query(s, 0xd, r, error)) return null; result["macroBytes"] = (r[1] << 8) | r[2];
            p[0] = 8; p[1] = 1; p[2] = 1; if (!s.Packet(p, r, error)) return null; result["brightness"] = Flow.BrightnessLevel(r[3]) * 25;
            p[2] = 2; if (!s.Packet(p, r, error)) return null; result["effect"] = r[3] != 0;
            var profile = Control(s, 1, 0, 0, 0, new ErrorSlot());
            result["profileSupported"] = profile != null;
            if (profile != null)
            {
                result["profile"] = profile; result["brightness"] = J.Own(profile["mainBrightness"]); result["waveSpeed"] = J.Own(profile["animationSpeed"]); result["effectFamily"] = "zones-v1";
                if (J.Bool(result["effect"]) && J.UInt(profile["animationMode"]) != 0) result["effect"] = J.UInt(profile["animationMode"]) + 1;
                if (J.Str(profile["firmwareVersion"]) == "0.10")
                {
                    var current = TouchRead(s, null);
                    if (current != null) result["touch"] = current;
                }
            }
            return result;
        }
        // The native boundary rechecks a fresh nonce-correlated feature reply before every mutation.
        JsonObject mutationProfile = null;
        if (new[] { "lighting", "profile", "advanced", "setKey", "setLayer", "resetLayer", "layerTemplate", "initializeLayers", "saveMacros", "resetKeys", "resetAll" }.Contains(action))
        {
            mutationProfile = Control(s, 1, 0, 0, 0, new ErrorSlot());
            if (mutationProfile == null) { Fail(error, "Расширение Studio не подтверждено. Подготовьте клавиатуру по USB; настройки не записаны."); return null; }
        }
        if (J.UInt(mutationProfile?["zoneTestStage"]) != 0) { Fail(error, "Клавиатура временно занята. Повторите настройку."); return null; }
        if (action == "lighting")
        {
            int level = J.Int(arguments["brightness"]), effect = J.Int(arguments["effect"]);
            int speed = arguments.ContainsKey("waveSpeed") ? J.Int(arguments["waveSpeed"]) : J.Int(mutationProfile["animationSpeed"]);
            if (level < 0 || level > 100 || effect < 0 || effect > 6 || speed < 0 || speed > 3) { Fail(error, "Яркость 0–100%; неизвестный эффект"); return null; }
            uint animation = effect > 1 ? (uint)effect - 1 : 0;
            if (animation != 0 && J.Str(arguments["effectFamily"]) != "zones-v1") { Fail(error, "Прежние глобальные эффекты удалены. Выберите волну заново."); return null; }
            if (!SetAnimation(s, mutationProfile, animation, (uint)speed, error)) return null;
            p[0] = 7; p[1] = 1; p[2] = 2; p[3] = (byte)(effect != 0 ? 1 : 0); if (!s.Packet(p, r, error)) return null;
            p[0] = 8; if (!s.Packet(p, r, error) || (r[3] != 0) != (effect != 0)) { Fail(error, "Клавиатура не подтвердила эффект"); return null; }
            bool persist = J.Bool(arguments["persist"]);
            var v = Control(s, persist ? 5u : 4u, 0, (uint)level, 0, error); if (v == null) return null;
            if (J.Int(v["mainBrightness"]) != level || (J.Bool(mutationProfile["zoneAnimationsSupported"]) && (J.UInt(v["animationMode"]) != animation || J.UInt(v["animationSpeed"]) != (uint)speed))) { Fail(error, "Клавиатура не подтвердила яркость"); return null; }
            if (persist) { Array.Clear(p); p[0] = 9; p[1] = 1; if (!s.Packet(p, r, error)) return null; }
            return J.O(("brightness", level), ("effect", effect), ("waveSpeed", speed), ("effectFamily", "zones-v1"));
        }
        if (action == "profile")
        {
            int brightness = J.Int(arguments["indicatorBrightness"]), seconds = J.Int(arguments["timeout"]);
            if (brightness < 0 || brightness > 255 || seconds < 0 || seconds > 3600) { Fail(error, "Яркость 0–255; время 0–3600 секунд"); return null; }
            uint flags = (J.Bool(arguments["rf"]) ? 1u : 0) | (J.Bool(arguments["bluetooth"]) ? 2u : 0) | (J.Bool(arguments["touchWake"]) ? 4u : 0) | (J.Bool(arguments["syncBreathing"]) ? 8u : 0);
            var v = Control(s, J.Bool(arguments["persist"]) ? 2u : 7u, flags, (uint)brightness, (uint)seconds, error); if (v == null) return null;
            if (J.Int(v["indicatorBrightness"]) != brightness || J.Int(v["timeout"]) != seconds || J.Bool(v["rf"]) != J.Bool(arguments["rf"]) || J.Bool(v["bluetooth"]) != J.Bool(arguments["bluetooth"])
                || J.Bool(v["touchWake"]) != J.Bool(arguments["touchWake"]) || J.Bool(v["syncBreathing"]) != J.Bool(arguments["syncBreathing"])) { Fail(error, "Значения профиля не подтверждены"); return null; }
            return v;
        }
        if (action == "advanced")
        {
            var before = Control(s, 1, 0, 0, 0, error);
            if (!J.Bool(before?["advancedSupported"])) { Fail(error, "Для этих настроек требуется расширение Studio 3.8. Обновите расширение по USB."); return null; }
            int threshold = J.Int(arguments["lowBatteryThreshold"]); if (threshold < 0 || threshold > 100) { Fail(error, "Порог заряда должен быть 0–100%."); return null; }
            bool sync = J.Bool(arguments["syncBrightness"]);
            var v = Control(s, J.Bool(arguments["persist"]) ? 10u : 9u, sync ? 1u : 0, (uint)threshold, 0, error);
            if (v == null) return null;
            if (J.Int(v["lowBatteryThreshold"]) != threshold || J.Bool(v["syncBrightness"]) != sync) { Fail(error, "Настройки индикатора не подтверждены."); return null; }
            return v;
        }
        if (action == "readMacros" || action == "saveMacros")
        {
            if (!Query(s, 0xc, r, error) || r[1] != 16) { Fail(error, "Неизвестное число макросов"); return null; }
            if (!Query(s, 0xd, r, error) || ((r[1] << 8) | r[2]) != shape.MacroBytes) { Fail(error, "Неизвестный размер памяти макросов"); return null; }
            var old = ReadBuffer(s, true, 0, shape.MacroBytes, error); if (old == null) return null;
            if (action == "saveMacros")
            {
                byte[] Decode(JsonNode n) { try { return Convert.FromBase64String(J.Str(n) ?? ""); } catch (FormatException) { return null; } }
                byte[] expected = Decode(arguments["expected"]), next = Decode(arguments["data"]);
                if (Equal(old, next)) return J.O(("data", Convert.ToBase64String(old)), ("count", 16), ("size", shape.MacroBytes));
                if (!Equal(old, expected)) { Fail(error, "Макросы изменились с момента чтения. Прочитай их заново."); return null; }
                if (next == null || !Flow.MacrosValidSized(next, shape.MacroBytes)) { Fail(error, "Неподдерживаемый или повреждённый формат макросов"); return null; }
                Backup(device, "macros", old, error); if (error?.Value != null) return null;
                if (!WriteBuffer(s, true, next, new ErrorSlot()))
                {
                    bool restored = WriteBuffer(s, true, old, new ErrorSlot());
                    Fail(error, restored ? "Запись макросов не подтверждена; прежние восстановлены и проверены." : "Запись и откат макросов не подтверждены. Не запускай макросы до повторного чтения. Резервная копия сохранена."); return null;
                }
                old = next;
            }
            return J.O(("data", Convert.ToBase64String(old)), ("count", 16), ("size", shape.MacroBytes));
        }
        if (action == "layerTemplate")
        {
            int layer = J.Int(arguments["layer"]); string kind = J.Str(arguments["template"]); byte[] data;
            if (layer < 0 || !Flow.LayerValid(layer) || !new[] { "factory", "normal", "fkeys" }.Contains(kind)) { Fail(error, "Неизвестный шаблон слоя."); return null; }
            if (kind == "factory") data = Slice(Flow.ModelKeys(shape, s.ProfileBase14), layer * LB, LB);
            else if (kind == "normal") data = Flow.ModelDefault(shape, s.ProfileBase14, layer);
            else if ((data = Flow.ModelFn(shape, s.ProfileBase14, layer)) == null) { Fail(error, "Шаблон F1–F12 доступен для Fn-слоёв."); return null; }
            return J.O(("layer", layer), ("keys", KeyArray(data)));
        }
        if (action == "initializeLayers")
        {
            if (!Query(s, 0x11, r, error) || r[1] != 6) { Fail(error, "Неизвестная структура слоёв."); return null; }
            var before = ReadBuffer(s, false, 0, shape.KeyBytes, error); if (before == null) return null;
            var desired = (byte[])before.Clone(); var changed = new List<int>();
            for (int layer = 0; layer < 6; layer++)
                if (Flow.ModelInitializable(shape, s.ProfileBase14, layer, before.AsSpan(layer * LB)))
                {
                    var next = Flow.ModelDefault(shape, s.ProfileBase14, layer);
                    if (!next.AsSpan().SequenceEqual(before.AsSpan(layer * LB, LB))) { Array.Copy(next, 0, desired, layer * LB, LB); changed.Add(layer); }
                }
            if (changed.Count > 0)
            {
                Backup(device, "layers-before-initialization", before, error); if (error?.Value != null) return null;
                bool ok = true; var change = new ErrorSlot();
                foreach (int layer in changed) if (!WriteLayer(s, (uint)layer, Slice(desired, layer * LB, LB), change)) { ok = false; break; }
                if (ok) ok = Equal(ReadBuffer(s, false, 0, shape.KeyBytes, change), desired);
                if (!ok)
                {
                    bool restored = true;
                    foreach (int layer in changed) restored = WriteLayer(s, (uint)layer, Slice(before, layer * LB, LB), new ErrorSlot()) && restored;
                    Fail(error, restored ? "Подготовка слоёв не подтверждена; прежние восстановлены." : "Не удалось подтвердить подготовку и восстановление слоёв. Копия сохранена."); return null;
                }
            }
            var layers = new JsonArray(); for (int layer = 0; layer < 6; layer++) layers.Add(KeyArray(desired.AsSpan(layer * LB, LB)));
            return J.O(("initialized", true), ("changedLayers", J.A(changed.Cast<object>())), ("layers", layers));
        }
        if (action == "setLayer" || action == "resetLayer")
        {
            if (!Query(s, 0x11, r, error) || r[1] != 6) { Fail(error, "Неизвестная структура слоёв."); return null; }
            int layer = J.Int(arguments["layer"]); if (layer < 0 || !Flow.LayerValid(layer)) { Fail(error, "Неизвестный слой."); return null; }
            var before = ReadBuffer(s, false, (uint)(layer * LB), LB, error); if (before == null) return null;
            bool reset = action == "resetLayer";
            var next = reset ? Slice(Flow.ModelKeys(shape, s.ProfileBase14), layer * LB, LB) : KeyData(arguments["keys"], shape, error); if (next == null) return null;
            if (!reset)
            {
                var expected = KeyData(arguments["expected"], shape, error); if (expected == null) return null;
                if (!Equal(before, expected) && !Equal(before, next)) { Fail(error, "Слой изменился с момента чтения. Прочитайте его заново; ожидающее изменение не перезаписало чужие назначения."); return null; }
            }
            if (!Equal(before, next))
            {
                Backup(device, $"layer-{layer}-before-replace", before, error); if (error?.Value != null) return null;
                if (!WriteLayer(s, (uint)layer, next, new ErrorSlot()))
                {
                    bool restored = WriteLayer(s, (uint)layer, before, new ErrorSlot());
                    Fail(error, restored ? "Изменение слоя не подтверждено; прежний слой восстановлен." : "Запись и откат слоя не подтверждены. Резервная копия сохранена."); return null;
                }
            }
            return J.O(("layer", layer), ("keys", KeyArray(next)), ("before", KeyArray(before)), ("reset", reset));
        }
        if (action == "resetKeys" || action == "resetAll")
        {
            bool all = action == "resetAll";
            if (!Query(s, 0x11, r, error) || r[1] != 6) { Fail(error, "Неизвестная структура слоёв"); return null; }
            var keys = ReadBuffer(s, false, 0, shape.KeyBytes, error); if (keys == null) return null;
            Backup(device, "all-layers-before-reset", keys, error); if (error?.Value != null) return null;
            byte[] macros = null; JsonObject profile = null; uint level = 0, effect = 0, speed = 1;
            if (all)
            {
                macros = ReadBuffer(s, true, 0, shape.MacroBytes, error); if (macros == null) return null;
                Backup(device, "macros-before-reset", macros, error); if (error?.Value != null) return null;
                var q = new byte[32]; q[0] = 8; q[1] = 1; q[2] = 1; if (!s.Packet(q, r, error)) return null; level = Flow.BrightnessLevel(r[3]) * 25;
                q[2] = 2; if (!s.Packet(q, r, error)) return null; effect = r[3] != 0 ? 1u : 0;
                profile = Control(s, 1, 0, 0, 0, new ErrorSlot());
                if (profile != null)
                {
                    level = J.UInt(profile["mainBrightness"]); speed = J.UInt(profile["animationSpeed"]);
                    if (effect != 0 && J.UInt(profile["animationMode"]) != 0) effect = J.UInt(profile["animationMode"]) + 1;
                }
                var settings = J.O(("brightness", level), ("effect", effect), ("profile", (JsonNode)profile ?? new JsonObject()));
                Backup(device, "settings-before-reset-json", Encoding.UTF8.GetBytes(settings.ToJsonString(new JsonSerializerOptions { WriteIndented = true })), error); if (error?.Value != null) return null;
            }
            var change = new ErrorSlot(); bool ok = Query(s, 6, r, change);
            if (ok) ok = Equal(ReadBuffer(s, false, 0, shape.KeyBytes, change), Slice(Flow.ModelKeys(shape, s.ProfileBase14), 0, shape.KeyBytes));
            if (ok && all)
            {
                ok = WriteBuffer(s, true, new byte[shape.MacroBytes], change) && LightingSet(s, 75, 0, 1, change);
                if (ok && profile != null) ok = Control(s, 3, 0, 0, 0, change) != null;
            }
            if (!ok)
            {
                bool restored = WriteBuffer(s, false, keys, new ErrorSlot());
                if (all)
                {
                    bool m = WriteBuffer(s, true, macros, new ErrorSlot()), l = LightingSet(s, level, effect, speed, new ErrorSlot()), c = true;
                    if (profile != null)
                    {
                        uint f = (J.Bool(profile["rf"]) ? 1u : 0) | (J.Bool(profile["bluetooth"]) ? 2u : 0) | (J.Bool(profile["touchWake"]) ? 4u : 0) | (J.Bool(profile["syncBreathing"]) ? 8u : 0);
                        c = Control(s, 2, f, J.UInt(profile["indicatorBrightness"]), J.UInt(profile["timeout"]), new ErrorSlot()) != null;
                    }
                    if (profile != null && J.Bool(profile["advancedSupported"])) c = c && Control(s, 10, J.Bool(profile["syncBrightness"]) ? 1u : 0, J.UInt(profile["lowBatteryThreshold"]), 0, new ErrorSlot()) != null;
                    restored = restored && m && l && c;
                }
                Fail(error, restored ? "Сброс не подтверждён. Прежние настройки восстановлены и проверены." : "Сброс и откат не удалось полностью подтвердить. Резервные копии сохранены в Application Support/Flow2Studio/Backups."); return null;
            }
            return J.O(("reset", true), ("all", all), ("profileReset", all && profile != null));
        }
        if (action == "readLayer" || action == "setKey")
        {
            int layer = J.Int(arguments["layer"]);
            if (!Query(s, 0x11, r, error)) return null;
            if (layer < 0 || layer >= r[1] || layer > 15) { Fail(error, "Неизвестный слой"); return null; }
            var data = ReadBuffer(s, false, (uint)(layer * LB), LB, error); if (data == null) return null;
            var beforeChange = data;
            if (action == "setKey")
            {
                int row = J.Int(arguments["row"]), col = J.Int(arguments["col"]), code = J.Int(arguments["code"]);
                if (row < 0 || row >= shape.Rows || col < 0 || col >= shape.Cols || code < 0 || code > 65535) { Fail(error, "Некорректное назначение клавиши"); return null; }
                Backup(device, $"layer-{layer}", data, error); if (error?.Value != null) return null;
                int pos = 2 * (row * (int)shape.Cols + col); int old = (data[pos] << 8) | data[pos + 1];
                if (J.IsNumber(arguments["expectedCode"]) && old != J.Int(arguments["expectedCode"]) && old != code) { Fail(error, "Назначение изменилось с момента чтения. Прочитайте слой заново."); return null; }
                byte[] set = new byte[32], get = new byte[32];
                Flow.KeyRequestSized(set, true, (uint)layer, (uint)row, (uint)col, (uint)code, shape.Rows, shape.Cols); Flow.KeyRequestSized(get, false, (uint)layer, (uint)row, (uint)col, 0, shape.Rows, shape.Cols);
                s.Packet(set, r, new ErrorSlot());
                if (!s.Packet(get, r, new ErrorSlot()) || ((r[4] << 8) | r[5]) != code)
                {
                    Flow.KeyRequestSized(set, true, (uint)layer, (uint)row, (uint)col, (uint)old, shape.Rows, shape.Cols); s.Packet(set, r, new ErrorSlot());
                    bool restored = s.Packet(get, r, new ErrorSlot()) && ((r[4] << 8) | r[5]) == old;
                    Fail(error, restored ? "Новое назначение не подтверждено. Прежнее восстановлено и проверено." : "Назначение и откат не удалось подтвердить. Обнови слой; резервная копия сохранена."); return null;
                }
                data = ReadBuffer(s, false, (uint)(layer * LB), LB, error); if (data == null) return null;
            }
            return J.O(("keys", KeyArray(data.AsSpan(0, (int)shape.Positions * 2))), ("layer", layer), ("before", KeyArray(beforeChange)));
        }
        Fail(error, "Неизвестное действие"); return null;
    }

    // Accessed only on the HID worker. No packet-level parallelism.
    static Session editingSession, touchLiveSession;
    public static void EditingEnd()
    {
        var s = editingSession; editingSession = null;
        if (s == null) return;
        s.ReleaseEditing(); s.Dispose();
    }
    static Session OpenSession(JsonObject device, ErrorSlot error)
    {
        bool bluetooth = J.Str(device["connection"]) == "Bluetooth";
        var s = new Session { Device = device, Ble = bluetooth, Serial = bluetooth };
        if (!bluetooth)
        {
            string path = J.Str(device["path"]);
            var port = path == null ? null : Native.HidPort.Open(path, out int code);
            if (port == null) { Fail(error, path == null || !Devices().Any(d => J.Same(d["id"], device["id"])) ? "Устройство отключено" : "No access to the keyboard. Close VIA and other keyboard utilities, then try again."); return null; }
            // The vendor endpoint is 32-byte unnumbered reports; Windows adds the report ID byte.
            if (port.InputLength != 33 || port.OutputLength != 33) { port.Dispose(); Fail(error, $"Unexpected HID report size ({port.InputLength}/{port.OutputLength}). Settings channel not opened."); return null; }
            s.Port = port;
            FlowHID.Attach(s);
        }
        return s;
    }
    static bool EndTouchTest(bool discardOnFailure, ErrorSlot error)
    {
        var s = touchLiveSession;
        if (s == null) return true;
        s.TouchClosing = true;
        var r = new byte[32];
        bool stopped = TouchExchange(s, 8, 0, 0, null, s.TouchToken, r, error);
        if (stopped || discardOnFailure)
        {
            touchLiveSession = null;
            s.TouchPoint = null;
            if (s.Serial) FlowBLESerial.SetTouchObserver(null);
            s.Dispose();
        }
        return stopped;
    }
    public static void TouchLiveEnd() => EndTouchTest(true, null);
    public static bool TouchTestStop(ErrorSlot error) => EndTouchTest(false, error);
    public static bool TouchLiveStart(JsonObject device, Action<uint> point, ErrorSlot error)
    {
        var model = Flow.ModelFor((int)Model(device));
        if (!J.Bool(device["vendor"]) || model.Number == 0) return false;
        TouchLiveEnd();
        var s = OpenSession(device, error); if (s == null) return false;
        s.TouchPoint = point;
        s.TouchToken = (uint)(BitConverter.ToUInt32(RandomNumberGenerator.GetBytes(4)) % uint.MaxValue) + 1;
        var reply = new byte[32];
        touchLiveSession = s;
        if (!TouchExchange(s, 9, 0, 0, null, s.TouchToken, reply, error)) { TouchLiveEnd(); return false; }
        if (s.Serial)
        {
            uint sku = model.Number, token = s.TouchToken;
            FlowBLESerial.SetTouchObserver(packet =>
            {
                uint position = Flow.TouchLivePosition(packet, sku, token);
                if (position != 0) point(position);
            });
        }
        return true;
    }
    public static JsonObject EditingTick(JsonObject device, double idleSeconds, ErrorSlot error)
    {
        if (J.Str(device["connection"]) != "2.4 ГГц" || Flow.ModelFor((int)Model(device)).Number == 0 || !J.Bool(device["vendor"])) { EditingEnd(); return J.O(("state", "unsupported")); }
        if (editingSession != null && !J.Same(editingSession.Device["id"], device["id"])) EditingEnd();
        var s = editingSession ?? OpenSession(device, error); if (s == null) return null;
        if (editingSession == null && !s.BeginOperation(error)) { s.Dispose(); return null; }
        var profile = Control(s, 1, 0, 0, 0, error);
        if (!J.Bool(profile?["quietReleaseSupported"]))
        {
            if (editingSession != null) EditingEnd(); else { s.EndOperation(); s.Dispose(); }
            if (profile == null) return null;
            return J.O(("state", "upgrade"));
        }
        uint timeout = J.UInt(profile["timeout"]);
        bool dark = Flow.EditingDark(idleSeconds, 0, timeout);
        s.EditingDark = dark;
        if (Control(s, 8, dark ? 2u : 1u, 0, 0, error) == null)
        {
            // Even an ambiguous reply may have applied the RAM lease. Best effort release;
            // firmware expiry remains authoritative if the keyboard cannot answer.
            s.ReleaseEditing(); editingSession = null; s.Dispose(); return null;
        }
        s.WindowLease = true; editingSession = s;
        return J.O(("state", dark ? "dark" : "active"), ("dark", dark), ("timeout", timeout));
    }
    public static JsonObject Perform(JsonObject device, string action, JsonObject arguments, ErrorSlot error)
    {
        try { return PerformUnguarded(device, action, arguments, error); }
        catch (Exception e) { Fail(error, e.Message); return null; }
    }
    static JsonObject PerformUnguarded(JsonObject device, string action, JsonObject arguments, ErrorSlot error)
    {
        if (!J.Bool(device["vendor"]))
        {
            if (action == "status")
                foreach (var fresh in Devices().OfType<JsonObject>())
                    if (J.Same(fresh["id"], device["id"]))
                    {
                        var level = fresh["systemBattery"];
                        return J.O(("valid", level != null), ("percent", (JsonNode)level ?? 0), ("system", true), ("power", false));
                    }
            Fail(error, "Bluetooth подключён, но служебный HID-канал настроек не найден. Для настройки используйте USB или 2.4 ГГц."); return null;
        }
        bool retained = editingSession != null && J.Same(editingSession.Device["id"], device["id"]);
        var s = retained ? editingSession : OpenSession(device, error);
        if (s == null) return null;
        try
        {
            bool bluetooth = s.Ble;
            bool passive = action == "status" || action == "syncTouchProfile";
            if (retained && !passive)
            {
                s.EditingDark = false;
                if (Control(s, 8, 1, 0, 0, error) == null) { Offline(error); return null; }
            }
            var operationModel = Flow.ModelFor((int)Model(device));
            bool eligible = operationModel.Number != 0 && (bluetooth || J.UInt(device["pid"]) == operationModel.Pid) && !passive;
            if (eligible && !retained)
            {
                // Send the wake request BEFORE ordinary liveness reads, including after sleep.
                // This is volatile: firmware limits it to 15 seconds if the app/link fails.
                bool awake = s.BeginOperation(new ErrorSlot());
                if (!awake && action != "capabilities") { Offline(error); return null; }
                // A factory/unsupported extension can still be inspected; setters retain their fresh proof gate.
            }
            var result = PerformAction(s, device, action, arguments, error);
            s.EndOperation();
            // A lost release ACK does not invalidate an already verified write; expiry is <=15 seconds.
            return result;
        }
        finally { if (!retained) s.Dispose(); }
    }
}
