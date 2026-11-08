// Port of mac/FlowBLESerial.m and mac/FlowBLEBattery.m. CoreBluetooth -> Windows.Devices.Bluetooth GATT.
// Both only use an already connected, uniquely named keyboard. Never scan, pair or change firmware.
using System.Text;
using System.Text.Json.Nodes;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;
using Windows.Devices.Radios;
using Windows.Security.Cryptography;
using Windows.Storage.Streams;

namespace Flow2Studio;

static class FlowBluetooth
{
    static readonly object Sync = new();
    static List<(string name, string address)> cache = new();
    static double cachedAt = -100;
    static bool refreshing;
    static string Selector => BluetoothLEDevice.GetDeviceSelectorFromConnectionStatus(BluetoothConnectionStatus.Connected);

    /* Connected Bluetooth LE devices. Enumeration runs on every scan, so it is refreshed in the
       background and the last result is returned immediately (never blocks the UI thread). */
    public static List<(string name, string address)> ConnectedDevices()
    {
        lock (Sync)
        {
            if (FlowHID.Uptime - cachedAt >= 5 && !refreshing) { refreshing = true; _ = Refresh(); }
            return cache;
        }
    }
    static async Task Refresh()
    {
        var list = new List<(string, string)>();
        try { foreach (var d in await DeviceInformation.FindAllAsync(Selector)) list.Add((d.Name, d.Id.Contains('-') ? d.Id[(d.Id.LastIndexOf('-') + 1)..] : d.Id)); }
        catch { }
        lock (Sync) { cache = list; cachedAt = FlowHID.Uptime; refreshing = false; }
    }
    /* The unique connected peripheral with this exact name, or an error message. */
    public static async Task<(BluetoothLEDevice device, string problem)> Connected(string name, string several, string missing)
    {
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        Radio radio = adapter == null ? null : await adapter.GetRadioAsync();
        if (adapter == null || !adapter.IsLowEnergySupported || radio?.State != RadioState.On) return (null, "Bluetooth выключен или недоступен.");
        var matches = (await DeviceInformation.FindAllAsync(Selector)).Where(d => d.Name == name).ToList();
        // A HID path cannot be translated into a GATT identity; with two identical names do not pick one.
        if (matches.Count != 1) return (null, matches.Count > 0 ? several : missing);
        var device = await BluetoothLEDevice.FromIdAsync(matches[0].Id);
        return device == null ? (null, missing) : (device, null);
    }
    public static Guid Uuid16(ushort value) => new($"0000{value:x4}-0000-1000-8000-00805f9b34fb");
    public static byte[] Bytes(IBuffer buffer) { CryptographicBuffer.CopyToByteArray(buffer, out byte[] bytes); return bytes ?? Array.Empty<byte>(); }
}

sealed class SerialException(string message) : Exception(message);

/* Called on the HID worker; GATT callbacks run on the thread pool under one lock. */
static class FlowBLESerial
{
    static readonly object Sync = new();
    static readonly Guid OutputUuid = new("0783B03E-8535-B5A0-7140-A304D2495CB8"), InputUuid = new("0783B03E-8535-B5A0-7140-A304D2495CBA");
    enum Stage { Idle, Wake, WakeWait, Payload }
    static string deviceID, name;
    static BluetoothLEDevice peripheral;
    static readonly List<GattDeviceService> services = new();
    static GattCharacteristic output, input;
    static TaskCompletionSource<byte[]> completion;
    static byte[] request, pendingReply;
    static bool writeAcked, ready;
    static Stage stage;
    static ulong generation;
    static Action<byte[]> touchObserver;

    public static void SetTouchObserver(Action<byte[]> observer) { lock (Sync) touchObserver = observer; }
    public static void Reset() { lock (Sync) Finish(null, "Bluetooth-сеанс закрыт: устройство сменилось, отключилось или Mac засыпает."); }
    public static byte[] Exchange(JsonObject device, byte[] packet, ErrorSlot error) => Run(device, packet, false, error);
    public static byte[] ExchangeConnected(JsonObject device, byte[] packet, ErrorSlot error) => Run(device, packet, true, error);

    static bool Connected() => peripheral?.ConnectionStatus == BluetoothConnectionStatus.Connected;
    static void CloseConnection()
    {
        if (output != null) output.ValueChanged -= OnValue;
        if (input != null) input.ValueChanged -= OnValue;
        if (peripheral != null) peripheral.ConnectionStatusChanged -= OnStatus;
        foreach (var s in services) s.Dispose();
        services.Clear(); peripheral?.Dispose();
        peripheral = null; ready = false; touchObserver = null; output = null; input = null; deviceID = null; name = null;
    }
    /* Caller holds Sync. */
    static void Finish(byte[] data, string error)
    {
        var complete = completion; completion = null; request = null;
        pendingReply = null; writeAcked = false; stage = Stage.Idle; ulong current = ++generation;
        if (error != null) CloseConnection();
        else _ = Task.Delay(60000).ContinueWith(_ => { lock (Sync) if (current == generation && completion == null && touchObserver == null) Finish(null, "Bluetooth-сеанс закрыт: устройство сменилось, отключилось или Mac засыпает."); });
        if (error != null) complete?.TrySetException(new SerialException(error)); else complete?.TrySetResult(data);
    }
    static void FinishIf(ulong expected, byte[] data, string error) { lock (Sync) if (expected == generation && completion != null) Finish(data, error); }

    static byte[] Run(JsonObject device, byte[] packet, bool connectedOnly, ErrorSlot error)
    {
        Task<byte[]> task; ulong current; bool reuse;
        lock (Sync)
        {
            string id = J.Str(device["id"]);
            if (connectedOnly && (deviceID != id || !ready || !Connected())) return null;
            if (completion != null) { if (error != null) error.Value = new FlowError("Flow2BLESerial", 1, "Предыдущая Bluetooth-команда ещё выполняется."); return null; }
            if (packet.Length != 32) { if (error != null) error.Value = new FlowError("Flow2BLESerial", 1, "Некорректная длина команды Bluetooth."); return null; }
            if (deviceID != id) Finish(null, "Bluetooth-сеанс закрыт: устройство сменилось, отключилось или Mac засыпает.");
            reuse = ready && Connected();
            // A failed previous connection is never reused. Name/ID and this pending packet remain intact.
            if (!reuse) CloseConnection();
            deviceID = id; name = J.Str(device["name"]);
            request = (byte[])packet.Clone();
            completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
            task = completion.Task; current = ++generation;
        }
        _ = Task.Delay(reuse ? 7000 : 25000).ContinueWith(_ => FinishIf(current, null, "Нет ответа Bluetooth. Разбудите клавиатуру и обновите устройство. Неподтверждённая команда не повторяется автоматически."));
        _ = Task.Run(async () =>
        {
            try { if (!reuse) await Open(current); await Send(current); }
            catch (Exception e) { FinishIf(current, null, e.Message); }
        });
        try { return task.GetAwaiter().GetResult(); }
        catch (Exception e) { if (error != null) error.Value = new FlowError("Flow2BLESerial", 1, e.Message); return null; }
    }
    static async Task<string> ReadString(GattCharacteristic c)
    {
        var value = await c.ReadValueAsync(BluetoothCacheMode.Uncached);
        return value.Status == GattCommunicationStatus.Success ? Encoding.UTF8.GetString(FlowBluetooth.Bytes(value.Value)) : null;
    }
    static async Task Open(ulong current)
    {
        string wanted; lock (Sync) wanted = name;
        var (device, problem) = await FlowBluetooth.Connected(wanted, "Несколько Bluetooth-клавиатур с одинаковым именем. Оставьте подключённой одну для настройки.", "Выбранная клавиатура не видна через Bluetooth.");
        if (device == null) throw new SerialException(problem);
        lock (Sync)
        {
            if (current != generation) { device.Dispose(); return; }
            peripheral = device; device.ConnectionStatusChanged += OnStatus;
        }
        string manufacturer = null, revision = null;
        var information = await device.GetGattServicesAsync(BluetoothCacheMode.Uncached);
        if (information.Status != GattCommunicationStatus.Success) throw new SerialException("Не удалось открыть Bluetooth-канал.");
        lock (Sync) services.AddRange(information.Services);
        foreach (var s in information.Services.Where(s => s.Uuid == FlowBluetooth.Uuid16(0x180a)))
        {
            var characteristics = await s.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
            foreach (var c in characteristics.Characteristics)
            {
                if (!c.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Read)) continue;
                if (c.Uuid == FlowBluetooth.Uuid16(0x2a29)) manufacturer = await ReadString(c);
                else if (c.Uuid == FlowBluetooth.Uuid16(0x2a26)) revision = await ReadString(c);
            }
        }
        if (!new[] { "flow2-68@lofree", "flow2-84@lofree", "flow2-100@lofree" }.Contains(wanted?.ToLowerInvariant()) || manufacturer != "Freqchip" || revision != "0.2.6")
            throw new SerialException("Для Bluetooth-настройки нужна обычная Flow 2 с Freqchip 0.2.6. Заряд доступен отдельно.");
        var channels = information.Services.Where(s => s.Uuid == FlowBluetooth.Uuid16(0xfff0)).ToList();
        if (channels.Count != 1) throw new SerialException("Не найден однозначный Bluetooth-канал FFF0.");
        var all = (await channels[0].GetCharacteristicsAsync(BluetoothCacheMode.Uncached)).Characteristics;
        var a = all.Where(c => c.Uuid == OutputUuid).ToList(); var b = all.Where(c => c.Uuid == InputUuid).ToList();
        if (all.Count != 2 || a.Count != 1 || b.Count != 1) throw new SerialException("Bluetooth-профиль отличается от проверенного.");
        GattCharacteristic outChar = a[0], inChar = b[0];
        // macOS allows 512-byte long writes with response; Windows performs the same long write, so no MTU gate here.
        if (!outChar.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write) || !outChar.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify) || !inChar.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify))
            throw new SerialException("Bluetooth-канал не поддерживает проверенный формат пакета.");
        lock (Sync) { if (current != generation) return; output = outChar; input = inChar; outChar.ValueChanged += OnValue; inChar.ValueChanged += OnValue; }
        foreach (var c in new[] { outChar, inChar })
            if (await c.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.Notify) != GattCommunicationStatus.Success)
                throw new SerialException("Не удалось включить ответы Bluetooth.");
        lock (Sync) { if (current != generation) return; ready = true; }
    }
    static async Task Write(GattCharacteristic c, byte[] bytes)
    {
        var result = await c.WriteValueWithResultAsync(CryptographicBuffer.CreateFromByteArray(bytes), GattWriteOption.WriteWithResponse);
        if (result.Status != GattCommunicationStatus.Success) throw new SerialException($"Bluetooth: {result.Status}");
    }
    static async Task Send(ulong current)
    {
        byte[] packet; GattCharacteristic target;
        lock (Sync) { if (current != generation || completion == null || !ready) return; packet = request; target = output; writeAcked = false; pendingReply = null; }
        if (Flow.SerialNeedsRadioWake(packet))
        {
            lock (Sync) stage = Stage.Wake;
            await Write(target, Flow.SerialRadioWake());
            lock (Sync) { if (current != generation || completion == null) return; stage = Stage.WakeWait; }
            // v028 wake path includes 200 ms + 10 ms UART signaling. Wait before VIA.
            await Task.Delay(300);
        }
        lock (Sync) { if (current != generation || completion == null) return; stage = Stage.Payload; writeAcked = false; pendingReply = null; }
        await Write(target, Flow.SerialWrap(packet));
        lock (Sync)
        {
            if (current != generation || completion == null || stage != Stage.Payload) return;
            writeAcked = true; if (pendingReply != null) Finish(pendingReply, null);
        }
    }
    static void OnValue(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        byte[] reply = Flow.SerialUnwrap(FlowBluetooth.Bytes(args.CharacteristicValue)); if (reply == null) return;
        Action<byte[]> observer = null;
        lock (Sync)
        {
            if (sender != output && sender != input) return;
            if (touchObserver != null && reply[0] == 0x18 && reply[4] == 0x82) observer = touchObserver;
            else
            {
                if (request == null || completion == null || stage != Stage.Payload) return;
                int matched = Flow.SerialMatch(request, reply);
                if (matched < 0) Finish(null, "Эта команда не поддерживается прошивкой клавиатуры.");
                else if (matched == 1) { pendingReply = reply; if (writeAcked) Finish(pendingReply, null); }
            }
        }
        observer?.Invoke(reply);
    }
    static void OnStatus(BluetoothLEDevice sender, object args)
    {
        lock (Sync) if (sender == peripheral && sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected) Finish(null, "Bluetooth-клавиатура отключена.");
    }
}

/* UI thread only. Reads 180F/2A19 from an already connected, uniquely named peripheral. */
sealed class FlowBLEBattery
{
    List<Action<JsonObject, string>> callbacks;
    string deviceID;
    ulong generation;
    BluetoothLEDevice peripheral;
    GattDeviceService service;

    void ClearSession() { service?.Dispose(); peripheral?.Dispose(); service = null; peripheral = null; }
    void Finish(JsonObject value, string error)
    {
        var pending = callbacks; callbacks = null;
        generation++; ClearSession(); deviceID = null;
        foreach (var callback in pending ?? new()) callback(value, error);
    }
    public void Cancel() => Finish(null, "Чтение заряда отменено: устройство сменилось или Mac засыпает.");
    public void ReadDevice(JsonObject device, Action<JsonObject, string> completion)
    {
        string id = J.Str(device["id"]);
        if (callbacks != null && deviceID == id) { callbacks.Add(completion); return; }
        Cancel();
        string name = J.Str(device["name"]); deviceID = id;
        callbacks = new() { completion };
        if (string.IsNullOrEmpty(name)) { Finish(null, "Неизвестно имя Bluetooth-клавиатуры."); return; }
        ulong current = generation;
        _ = Timeout(current);
        _ = Read(name, current);
    }
    async Task Timeout(ulong current)
    {
        await Task.Delay(18000);
        if (callbacks != null && generation == current) Finish(null, "Bluetooth: заряд не получен. Разбудите клавиатуру и нажмите «Обновить заряд».");
    }
    async Task Read(string name, ulong current)
    {
        try
        {
            var (device, problem) = await FlowBluetooth.Connected(name, "Подключены несколько клавиатур с одинаковым именем. Для чтения заряда оставьте одну Bluetooth Flow 2.", "Эта клавиатура не видна через Bluetooth. Проверьте подключение и разбудите её.");
            if (generation != current) { device?.Dispose(); return; }
            if (device == null) { Finish(null, problem); return; }
            peripheral = device;
            var found = await device.GetGattServicesForUuidAsync(FlowBluetooth.Uuid16(0x180f), BluetoothCacheMode.Uncached);
            if (generation != current) { foreach (var s in found.Services) s.Dispose(); return; }
            if (found.Status != GattCommunicationStatus.Success || found.Services.Count != 1) { foreach (var s in found.Services) s.Dispose(); Finish(null, "Не найдена однозначная служба заряда Bluetooth."); return; }
            service = found.Services[0];
            var characteristics = await service.GetCharacteristicsForUuidAsync(FlowBluetooth.Uuid16(0x2a19), BluetoothCacheMode.Uncached);
            if (generation != current) return;
            var levels = characteristics.Characteristics.Where(c => c.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Read)).ToList();
            if (levels.Count != 1) { Finish(null, "Характеристика заряда Bluetooth недоступна для чтения."); return; }
            var value = await levels[0].ReadValueAsync(BluetoothCacheMode.Uncached);
            if (generation != current) return;
            byte[] data = value.Status == GattCommunicationStatus.Success ? FlowBluetooth.Bytes(value.Value) : null;
            if (data == null || data.Length != 1 || data[0] > 100) { Finish(null, "Некорректный ответ Bluetooth-службы заряда."); return; }
            Finish(J.O(("valid", true), ("percent", (int)data[0]), ("source", "ble-standard"), ("peripheralID", device.BluetoothAddress.ToString("X12")),
                ("updatedAt", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0)), null);
        }
        catch (Exception e) { if (generation == current) Finish(null, e.Message); }
    }
}
