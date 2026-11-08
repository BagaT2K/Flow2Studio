// Byte-level port of the mac protocol headers:
// FlowProtocol.h, FlowPackets.h, FlowHIDResponse.h, FlowSerialProtocol.h, FlowTouchProtocol.h,
// FlowControl.h, FlowWake.h, FlowBluetooth.h, FlowEditing.h, FlowEditingPolicy.h,
// FlowKeymapCore.h, FlowLayerIO.h, FlowModels.h, FlowUSBBattery.h.
// Keep these in lockstep with the headers; they define what is sent to the keyboard.
namespace Flow2Studio;

static class Flow
{
    static readonly byte[] LFB = { 0x4c, 0x46, 0x42 };
    static readonly byte[] TouchRequest = { 0x18, (byte)'L', (byte)'F', (byte)'T', 0x02 };
    static readonly byte[] TouchReply = { 0x18, (byte)'L', (byte)'F', (byte)'T', 0x81 };
    static readonly byte[] TouchLive = { 0x18, (byte)'L', (byte)'F', (byte)'T', 0x82 };
    static readonly byte[] TC2 = { (byte)'T', (byte)'C', (byte)'2', 0 }; // memcmp(...,"TC2",4) includes the NUL
    static readonly byte[] F2S1 = { (byte)'F', (byte)'2', (byte)'S', (byte)'1' };
    static readonly byte[] RadioWake = { 0x16, (byte)'L', (byte)'F', (byte)'C', 0x03, 0x06, 0x01 };

    static bool Eq(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b) => a.SequenceEqual(b);

    // ---- FlowProtocol.h ----
    /* 1: response, 0: unrelated, -1: old firmware, -2: invalid fields. */
    public static int ValidateCommand(ReadOnlySpan<byte> p, ReadOnlySpan<byte> nonce, int command)
    {
        if (command != 1 && command != 2) return 0;
        if (p.Length == 33 && p[0] == 0) p = p[1..];
        if (p.Length != 32 || !Eq(p.Slice(8, 4), nonce[..4])) return 0;
        if (p[0] == 0xff && Eq(p.Slice(1, 3), LFB) && p[4] == command) return -1;
        if (p[0] != 0x15 || !Eq(p.Slice(1, 3), LFB) || p[4] != (0x80 | command)) return 0;
        if ((p[5] & ~7) != 0 || ((p[5] & 1) != 0 && p[6] > 100)) return -2;
        return 1;
    }
    public static int Validate(ReadOnlySpan<byte> p, ReadOnlySpan<byte> nonce) => ValidateCommand(p, nonce, 1);
    public static byte[] Request(ReadOnlySpan<byte> nonce)
    {
        var p = new byte[32];
        p[0] = 0x15; p[1] = 0x4c; p[2] = 0x46; p[3] = 0x42; p[4] = 1;
        nonce[..4].CopyTo(p.AsSpan(8));
        return p;
    }

    // ---- FlowPackets.h ----
    public static uint BrightnessLevel(uint value) => value <= 255 ? (value * 4 + 127) / 255 : 5;
    public static bool BufferRequest(byte[] p, bool macro, uint offset, uint count)
    {
        if (count == 0 || count > 28 || offset > 65535 || offset + count > 65536) return false;
        Array.Clear(p, 0, 32); p[0] = (byte)(macro ? 0x0e : 0x12); p[1] = (byte)(offset >> 8); p[2] = (byte)offset; p[3] = (byte)count; return true;
    }
    public static bool KeyRequestSized(byte[] p, bool write, uint layer, uint row, uint col, uint code, uint rows, uint cols)
    {
        if (layer >= 16 || rows == 0 || rows > 6 || cols == 0 || cols > 18 || row >= rows || col >= cols || code > 65535) return false;
        Array.Clear(p, 0, 32); p[0] = (byte)(write ? 5 : 4); p[1] = (byte)layer; p[2] = (byte)row; p[3] = (byte)col;
        if (write) { p[4] = (byte)(code >> 8); p[5] = (byte)code; }
        return true;
    }

    // ---- FlowTouchProtocol.h ----
    public static uint TouchBits(ReadOnlySpan<byte> p, uint i) { uint bit = i * 9, b = bit / 8; return (((uint)p[(int)b] | (uint)p[(int)b + 1] << 8) >> (int)(bit % 8)) & 511; }
    public static void TouchPack(Span<byte> p, uint i, uint value)
    {
        for (uint j = 0; j < 9; j++) { uint bit = i * 9 + j; byte mask = (byte)(1u << (int)(bit % 8)); p[(int)(bit / 8)] = (byte)((p[(int)(bit / 8)] & ~mask) | (((value >> (int)j) & 1) != 0 ? mask : 0)); }
    }
    public static bool TouchAction(uint id) => (id <= 10 && id != 8) || (id >= 68 && id <= 179) || (id >= 288 && id <= 295) || (id >= 320 && id <= 339);
    public static bool TouchMatch(ReadOnlySpan<byte> p, ReadOnlySpan<byte> r) =>
        Eq(p[..5], TouchRequest) && Eq(r[..5], TouchReply) && Eq(p.Slice(22, 4), r.Slice(22, 4)) && p[6] == r[6] && r[5] <= 3 && r[27] == 3
        && (p[21] == 68 || p[21] == 84 || p[21] == 100) && r[21] == p[21] && Eq(r.Slice(28, 4), TC2);
    public static uint TouchLivePosition(ReadOnlySpan<byte> packet, uint model, uint token)
    {
        if (packet.Length != 32 || token == 0 || !Eq(packet[..5], TouchLive) || packet[21] != model || packet[27] != 3 || !Eq(packet.Slice(28, 4), TC2)) return 0;
        uint received = (uint)packet[22] | (uint)packet[23] << 8 | (uint)packet[24] << 16 | (uint)packet[25] << 24;
        return received == token && packet[7] >= 1 && packet[7] <= 50 ? packet[7] : 0u;
    }

    // ---- FlowControl.h ----
    public static byte[] ControlRequest(uint op, uint flags, uint brightness, uint seconds, ReadOnlySpan<byte> nonce)
    {
        var p = new byte[32];
        p[0] = 0x16; p[1] = (byte)'L'; p[2] = (byte)'F'; p[3] = (byte)'C'; p[4] = 3; p[5] = (byte)op; p[6] = (byte)flags; p[7] = (byte)brightness; p[8] = (byte)(seconds >> 8); p[9] = (byte)seconds;
        nonce[..4].CopyTo(p.AsSpan(12));
        return p;
    }
    /* Public release numbers are independent of the legacy feature-generation counter. */
    public static uint ControlGeneration(ReadOnlySpan<byte> r)
    {
        if (r[21] == 0 && (r[22] == 9 || r[22] == 10) && r[23] == 0x14) return 19;
        return r[21] == 3 ? r[22] : 0u;
    }
    public static bool ControlModelMatches(ReadOnlySpan<byte> r, uint model) => ControlGeneration(r) == 19 ? r[20] == model : model == 68;
    public static bool ControlMatch(ReadOnlySpan<byte> p, ReadOnlySpan<byte> r)
    {
        uint version = ControlGeneration(r);
        // "F2S1\x44\x03\x02\x00" with capability 127, or "F2S1\x44\x03\xNN\x00" for NN in 0x03..0x12 with capability 255.
        bool f2s1Legacy = Eq(r.Slice(16, 4), F2S1) && r[20] == 0x44 && r[21] == 0x03 && r[23] == 0x00;
        bool supported = (r[10] == 127 && f2s1Legacy && r[22] == 0x02) || (r[10] == 255 && f2s1Legacy && r[22] >= 0x03 && r[22] <= 0x12);
        supported = supported || (r[10] == 255 && Eq(r.Slice(16, 4), F2S1) && (r[20] == 68 || r[20] == 84 || r[20] == 100)
            && ((r[21] == 3 && r[22] == 19) || (r[21] == 0 && (r[22] == 9 || r[22] == 10))) && r[23] == 0x14);
        return Eq(p[..4], r[..4]) && r[4] == 0x81 && Eq(p.Slice(12, 4), r.Slice(12, 4)) && r[5] <= 2 && r[6] <= 15 && ((r[8] << 8) | r[9]) <= 3600 && supported && r[11] == 3 && r[24] <= 100
            && (version < 8 || (r[25] <= 100 && r[26] <= 1))
            && (version < 10 || (version < 15 ? r[28] <= 3 : ((r[28] & 15) <= (version >= 16 ? 5 : 4) && (r[28] >> 4) <= 3)));
    }

    // ---- FlowWake.h ---- One scope per explicit operation; no background scheduler or persistent setting.
    public sealed class WakeScope { public bool Active; public double RenewedAt; }
    public delegate bool Exchange(byte[] request, byte[] reply);
    static bool WakeSend(bool active, ReadOnlySpan<byte> nonce, Exchange exchange)
    {
        byte[] p = ControlRequest(6, active ? 1u : 0u, 0, 0, nonce), r = new byte[32];
        return exchange(p, r) && ControlMatch(p, r) && r[5] == 0;
    }
    public static bool WakeBegin(WakeScope s, double now, ReadOnlySpan<byte> nonce, Exchange exchange) { s.Active = WakeSend(true, nonce, exchange); s.RenewedAt = now; return s.Active; }
    public static bool WakeDue(WakeScope s, double now) => s.Active && (now < s.RenewedAt || now - s.RenewedAt >= 5);
    public static bool WakeRefresh(WakeScope s, double now, ReadOnlySpan<byte> nonce, Exchange exchange)
    {
        if (!WakeDue(s, now)) return true;
        if (!WakeSend(true, nonce, exchange)) return false;
        s.RenewedAt = now; return true;
    }
    public static bool WakeEnd(WakeScope s, ReadOnlySpan<byte> nonce, Exchange exchange)
    {
        if (!s.Active) return true;
        s.Active = false; return WakeSend(false, nonce, exchange);
    }
    /* One raw release; do not renew a lease while trying to end it. */
    public static bool WakeReleaseEditing(WakeScope s, ReadOnlySpan<byte> nonce, Exchange exchange)
    {
        s.Active = false;
        byte[] p = ControlRequest(8, 0, 0, 0, nonce), r = new byte[32];
        return exchange(p, r) && ControlMatch(p, r) && r[5] == 0;
    }

    // ---- FlowBluetooth.h ---- (HID-over-BLE report 3 framing; Bluetooth settings use the GATT serial channel)
    public static bool BleEncode(ReadOnlySpan<byte> request, byte[] wire)
    {
        if (request[31] != 0) return false;
        wire[0] = 3; request[..31].CopyTo(wire.AsSpan(1)); return true;
    }
    public static bool BleDecode(uint reportID, ReadOnlySpan<byte> bytes, byte[] response)
    {
        if (reportID != 3) return false;
        if (bytes.Length == 32 && bytes[0] == 3) bytes = bytes[1..];
        if (bytes.Length != 31) return false;
        bytes.CopyTo(response); response[31] = 0; return true;
    }
    public static uint ReadChunk(bool ble) => ble ? 27u : 28u;

    // ---- FlowSerialProtocol.h ----
    public static bool SerialNeedsRadioWake(ReadOnlySpan<byte> p) => Eq(p[..7], RadioWake);
    public static byte[] SerialRadioWake() => new byte[] { 0xaa, 3, 0xa2, 1 };
    public static byte[] SerialWrap(ReadOnlySpan<byte> request)
    {
        var wire = new byte[35]; wire[0] = 0xaa; wire[1] = 0x22; wire[2] = 0xa1; request[..32].CopyTo(wire.AsSpan(3)); return wire;
    }
    public static byte[] SerialUnwrap(ReadOnlySpan<byte> wire) => wire.Length != 34 || wire[0] != 5 || wire[1] != 0xaf ? null : wire.Slice(2, 32).ToArray();
    static int ReplyPrefix(byte command) => command switch { 7 or 8 => 3, 4 or 5 or 0x12 or 0xe or 0xf or 0x13 => 4, _ => 1 };
    /* 1: matching reply; -1: unsupported command; 0: unrelated. No retries. */
    public static int SerialMatch(ReadOnlySpan<byte> request, ReadOnlySpan<byte> reply)
    {
        if (request[0] == 0x18) return TouchMatch(request, reply) ? 1 : (reply[0] == 0xff ? -1 : 0);
        if (request[0] == 0x16) return ControlMatch(request, reply) ? 1 : (reply[0] == 0xff ? -1 : 0);
        if (request[0] == 0x15) return Validate(reply, request.Slice(8, 4)) == 1 ? 1 : 0;
        if (reply[0] == 0xff && Eq(reply.Slice(1, 3), request.Slice(1, 3))) return -1;
        if (reply[0] != request[0]) return 0;
        int prefix = ReplyPrefix(request[0]);
        return Eq(reply[..prefix], request[..prefix]) ? 1 : 0;
    }

    // ---- FlowHIDResponse.h ---- Owned by Session for its entire lifetime, never a request's stack frame.
    public sealed class HIDResponse
    {
        public byte[] Request = new byte[32], Reply = new byte[32];
        public int Done; public bool Active, Battery, Ble; public uint Reports; public long LastLength;
        public void Begin(byte[] request, bool ble)
        {
            Array.Copy(request, Request, 32); Array.Clear(Reply); Done = 0; Reports = 0; LastLength = 0;
            Battery = request[0] == 0x15; Ble = ble; Active = true;
        }
        public void End() => Active = false;
        public void Accept(bool success, bool input, uint reportID, ReadOnlySpan<byte> bytes)
        {
            if (!Active || !success || Done != 0 || !input) return;
            if (Ble)
            {
                if (reportID != 3) return;
                Reports++; LastLength = bytes.Length;
                var normalized = new byte[32];
                if (!BleDecode(reportID, bytes, normalized)) return;
                bytes = normalized;
            }
            if (bytes.Length == 33 && bytes[0] == 0) bytes = bytes[1..];
            if (bytes.Length != 32) return;
            if (Request[0] == 0x18) { if (TouchMatch(Request, bytes)) { bytes.CopyTo(Reply); Done = 1; } else if (bytes[0] == 0xff && Eq(bytes.Slice(1, 3), Request.AsSpan(1, 3))) Done = -1; return; }
            if (Request[0] == 0x16)
            {
                if (ControlMatch(Request, bytes)) { bytes.CopyTo(Reply); Done = 1; }
                else if (bytes[0] == 0xff) Done = -1;
                return;
            }
            if (Battery) { int valid = ValidateCommand(bytes, Request.AsSpan(8, 4), Request[4]); if (valid == 1) { bytes.CopyTo(Reply); Done = 1; } else if (valid < 0) Done = valid; return; }
            if (bytes[0] == 0xff && Eq(bytes.Slice(1, 3), Request.AsSpan(1, 3))) { Done = -1; return; }
            if (bytes[0] != Request[0]) return;
            int prefix = ReplyPrefix(bytes[0]);
            if (!Eq(bytes[..prefix], Request.AsSpan(0, prefix))) return;
            bytes.CopyTo(Reply); Done = 1;
        }
    }

    // ---- FlowEditing.h ---- Exact old send_string encoding verified in this device at 0x08008A9C.
    public static bool MacrosValidSized(byte[] b, int capacity)
    {
        int n = b?.Length ?? 0;
        if (b == null || n != capacity || (capacity != 3156 && capacity != 2976 && capacity != 2760) || b[n - 1] != 0) return false;
        int i = 0; uint slots = 0;
        while (i < n && slots < 16)
        {
            byte c = b[i++]; if (c == 0) { slots++; continue; }
            if (c != 1) continue;
            if (i >= n) return false;
            uint command = b[i++];
            if (command >= 1 && command <= 3) { if (i >= n || b[i++] == 0) return false; }
            else if (command == 4)
            {
                uint digits = 0, value = 0;
                while (i < n && b[i] >= '0' && b[i] <= '9') { if (++digits > 5) return false; value = value * 10 + (uint)(b[i++] - '0'); }
                if (digits == 0 || value > 60000 || i >= n || b[i++] != '|') return false;
            }
            else return false;
        }
        return slots == 16;
    }

    // ---- FlowEditingPolicy.h ---- Presence has its own clock. User inactivity only controls light.
    public struct EditingPresence { public bool Foreground, Grace; public double Deadline; }
    public static bool WindowForeground(bool active, bool key, bool visible, bool mini) => active && key && visible && !mini;
    public static bool EditingPresenceTick(ref EditingPresence p, double now, bool enabled, bool foreground, bool open, bool sleeping, bool busy, bool rf)
    {
        if (!enabled || !open || sleeping || busy || !rf) { p = default; return false; }
        if (foreground) { p.Foreground = true; p.Grace = false; p.Deadline = 0; return true; }
        if (p.Foreground) { p.Foreground = false; p.Grace = true; p.Deadline = now + 600.0; }
        if (p.Grace && now < p.Deadline) return true;
        p.Grace = false; return false;
    }
    public static uint BatteryPollInterval(bool foreground, bool automatic) => foreground ? (automatic ? 2u : 5u) : 300u;
    public static bool BatteryPollDue(double now, double last, bool foreground, bool automatic, bool changed) => changed || (now >= last && now - last >= BatteryPollInterval(foreground, automatic));
    public static bool EditingDark(double now, double activity, uint timeout) => timeout > 0 && now >= activity && now - activity >= timeout;
    /* Use only an aggregate keyboard-event count and age, never event contents. */
    public static double EditingKeyboardActivity(double now, double activity, bool changed, bool departed, double keyboardIdle)
    {
        if (!changed || departed || !(keyboardIdle >= 0 && keyboardIdle <= now)) return activity;
        double latest = now - keyboardIdle;
        return latest > activity ? latest : activity;
    }

    // ---- FlowKeymapCore.h ----
    public static bool LayerValid(int layer) => layer >= 0 && layer < 6;

    // ---- FlowLayerIO.h ----
    public static bool LayerWriteVerifySized(Func<uint, int, byte[]> read, Func<uint, byte[], bool> write, uint layer, byte[] data, int layerBytes)
    {
        if (read == null || write == null || layer >= 6 || data == null || (layerBytes != 150 && layerBytes != 180 && layerBytes != 216) || data.Length != layerBytes) return false;
        for (int n = 0; n < layerBytes;)
        {
            int count = Math.Min(layerBytes - n, 28);
            if (!write((uint)(layer * layerBytes + n), data.AsSpan(n, count).ToArray())) return false;
            n += count;
        }
        byte[] actual = read((uint)(layer * layerBytes), layerBytes);
        return actual != null && actual.AsSpan().SequenceEqual(data);
    }

    // ---- FlowModels.h ----
    public sealed record Model(uint Number, uint Rows, uint Cols, uint Positions, int LayerBytes, int KeyBytes, int MacroBytes, uint Pid, byte[] Factory);
    public static readonly Model NoModel = new(0, 0, 0, 0, 0, 0, 0, 0, null);
    public static Model ModelFor(int model) => model switch
    {
        68 => new(68, 5, 15, 75, 150, 900, 3156, 1, FlowTables.FlowV14Keys68),
        84 => new(84, 6, 15, 90, 180, 1080, 2976, 2, FlowTables.FlowV14Keys84),
        100 => new(100, 6, 18, 108, 216, 1296, 2760, 3, FlowTables.FlowV14Keys100),
        _ => NoModel,
    };
    public static byte[] ModelKeys(Model m, bool base14) => m.Number == 68 && !base14 ? FlowTables.FlowFactoryKeys : m.Factory;
    public static byte[] ModelDefault(Model m, bool base14, int layer)
    {
        if (m.Number == 0 || layer < 0 || layer >= 6) return null;
        byte[] keys = ModelKeys(m, base14); int b = layer == 2 || layer == 3 ? 2 : 0;
        var output = keys.AsSpan(b * m.LayerBytes, m.LayerBytes).ToArray();
        if (layer == 1 || layer == 3) return keys.AsSpan(layer * m.LayerBytes, m.LayerBytes).ToArray();
        if (layer >= 4)
            for (int i = 0; i < m.Positions; i++) { int p = layer * m.LayerBytes + i * 2; if (keys[p] != 0) { output[i * 2] = keys[p]; output[i * 2 + 1] = keys[p + 1]; } }
        return output;
    }
    public static bool ModelInitializable(Model m, bool base14, int layer, ReadOnlySpan<byte> data)
    {
        if (m.Number == 0 || layer < 0 || layer >= 6 || layer == 1 || layer == 3) return false;
        if (Eq(data[..m.LayerBytes], ModelKeys(m, base14).AsSpan(layer * m.LayerBytes, m.LayerBytes))) return true;
        for (int i = 0; i < m.Positions; i++) if (data[i * 2] != 0 || data[i * 2 + 1] != 1) return false;
        return true;
    }
    public static byte[] ModelFn(Model m, bool base14, int layer)
    {
        if (m.Number == 0 || (layer != 1 && layer != 3)) return null;
        var output = ModelKeys(m, base14).AsSpan(layer * m.LayerBytes, m.LayerBytes).ToArray();
        for (int col = 1; col <= 12; col++) { output[col * 2] = 0; output[col * 2 + 1] = (byte)(57 + col); }
        return output;
    }

    // ---- FlowUSBBattery.h ----
    public enum USBBatteryState { Valid, RefreshFailed, NotWired, QueueFull, Pending, ReadFailed }
    /* Caller has freshly verified the pinned 3.9 identity on the wired USB endpoint.
       One OEM request, at most five fresh status reads, no wake/configuration writes.
       The previous sample is replaced only by a nonce-validated status response. */
    public static (USBBatteryState state, bool requested, uint reads) USBBatteryRefresh(Exchange exchange, Func<byte[]> nonce, Action<int> wait, byte[] status)
    {
        var result = (state: USBBatteryState.RefreshFailed, requested: false, reads: 0u);
        byte[] n = nonce(), p = Request(n), r = new byte[32]; p[4] = 2;
        if (!exchange(p, r) || ValidateCommand(r, n, 2) != 1) return result;
        if (r[27] != 1) { result.state = r[27] == 2 ? USBBatteryState.NotWired : USBBatteryState.QueueFull; return result; }
        result.requested = true; result.state = USBBatteryState.Pending;
        for (int i = 0; i < 5; i++)
        {
            wait(80); n = nonce(); p = Request(n); result.reads++;
            if (!exchange(p, r) || Validate(r, n) != 1) { result.state = USBBatteryState.ReadFailed; return result; }
            Array.Copy(r, status, 32);
            if ((r[5] & 1) != 0 && r[6] <= 100) { result.state = USBBatteryState.Valid; return result; }
        }
        return result;
    }
}
