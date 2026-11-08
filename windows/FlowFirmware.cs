// Port of mac/FlowFirmware.m. IOKit USB -> WinUSB bulk pipes on the WB32 bootloader (VID 0x342d, PID 0xdfa0).
// Every safety gate of the mac host is kept: catalog SHA-256 pinning, model identity checks, two matching
// full reads, durable verified backups before any write, page allow-list, write/verify/rollback transaction.
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Flow2Studio;

sealed class FirmwarePackage
{
    public string Model; public bool Enabled;
    public Dictionary<string, byte[]> Images = new(); public Dictionary<string, string> Labels = new();
    public uint[] Pages; public string Target, Factory, OEM14; public HashSet<string> PreviousStudio = new();
}

sealed class RecoveryRecord
{
    public JsonObject Values; public string Folder; public DateTime CreatedAt;
    public byte[] RollbackImage, TargetImage, BeforeImage;
    public string Get(string key) => J.Str(Values[key]);
}

static class FlowFirmware
{
    static void Fail(ErrorSlot e, string message) { if (e != null) e.Value = new FlowError("Flow2Firmware", 1, message); }
    public static string Sha256(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    public static string BackupRoot => Path.Combine(FlowPreferences.Root, "FirmwareBackups");
    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    /* Present bootloaders keyed by their USB port location (IOKit locationID equivalent). */
    static Dictionary<string, uint> DfuServices()
    {
        var found = new Dictionary<string, uint>();
        foreach (uint node in Native.DeviceNodes("USB"))
        {
            string id = Native.DeviceID(node).ToUpperInvariant();
            if (!id.StartsWith(@"USB\VID_342D&PID_DFA0") || id.Contains("&MI_")) continue;
            string location = Native.LocationPath(node);
            if (location != null && !found.ContainsKey(location)) found[location] = node;
        }
        return found;
    }
    /* True when Windows has already bound WinUSB to a WB32 bootloader instance seen on this PC. */
    static bool WinUsbBound()
    {
        try
        {
            using var root = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\USB\VID_342D&PID_DFA0");
            if (root == null) return false;
            foreach (string name in root.GetSubKeyNames())
            {
                using var instance = root.OpenSubKey(name);
                if (string.Equals(instance?.GetValue("Service") as string, "WinUSB", StringComparison.OrdinalIgnoreCase)) return true;
            }
        }
        catch { }
        return false;
    }
    public static JsonArray Devices()
    {
        var devices = new JsonArray();
        foreach (var location in DfuServices().Keys)
        {
            string key = "dfu-" + location;
            devices.Add(J.O(("id", key), ("key", key), ("name", "Устройство USB · восстановление"), ("connection", "USB"), ("model", ""), ("vendor", false), ("bootloader", true), ("location", location)));
        }
        return devices;
    }
    static string FirmwareFolder => Program.ResourcePath("firmware");
    static FirmwarePackage CatalogForModel(uint model, ErrorSlot error)
    {
        string expected = FlowFlashCore.CatalogSha(model); if (expected == null) { Fail(error, "Неизвестная модель клавиатуры"); return null; }
        byte[] raw = null; try { raw = File.ReadAllBytes(Path.Combine(FirmwareFolder, $"model-{model}-v14.json")); } catch { }
        if (raw == null || Sha256(raw) != expected) { Fail(error, "Каталог модели повреждён. Запись запрещена."); return null; }
        JsonObject meta; try { meta = JsonNode.Parse(raw) as JsonObject; } catch (Exception e) { Fail(error, e.Message); return null; }
        string metaModel = meta?["model"] is JsonValue mv ? (J.IsString(mv) ? J.Str(mv) : J.Int(mv).ToString()) : null;
        if (metaModel != model.ToString()) { Fail(error, "Каталог другой модели. Запись запрещена."); return null; }
        if (meta["pages"] is not JsonArray pages || pages.Count == 0 || pages.Count > 300) { Fail(error, "Неверная карта страниц модели"); return null; }
        var package = new FirmwarePackage { Model = metaModel, Enabled = J.Bool(meta["enabled"]), Pages = new uint[pages.Count] };
        for (int i = 0; i < pages.Count; i++)
        {
            uint page = J.UInt(pages[i]);
            if (page % 256 != 0 || page + 256 > FlowFlashCore.FlashSize || (i > 0 && page <= package.Pages[i - 1])) { Fail(error, "Неверные границы страниц модели"); return null; }
            package.Pages[i] = page;
        }
        foreach (var item in (meta["images"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            byte[] image = null; string file = J.Str(item["file"]), hash = J.Str(item["sha256"]);
            try { if (file != null && Path.GetFileName(file) == file) image = File.ReadAllBytes(Path.Combine(FirmwareFolder, file)); } catch { }
            if (image == null || image.Length != FlowFlashCore.FlashSize || Sha256(image) != hash || !FlowFlashCore.FirmwareModelMatches(image, model, J.UInt(item["usbRelease"]))) { Fail(error, "Образ модели повреждён. Запись запрещена."); return null; }
            package.Images[hash] = image;
            string label = J.Str(item["description"]) ?? J.Str(item["id"]);
            if (J.Same(item["id"], meta["target"])) { package.Target = hash; label = $"Studio 0.10 · Flow 2 {model} · база 0.14"; }
            if (J.Same(item["id"], meta["factory"])) { package.Factory = hash; label = $"Заводская Flow 2 {model} USB 0.14"; }
            package.Labels[hash] = label;
        }
        if (package.Target == null || package.Factory == null || package.Images.Count > 32) { Fail(error, "Неполный каталог модели"); return null; }
        package.OEM14 = package.Factory;
        foreach (var h in (meta["previousStudio"] as JsonArray ?? new JsonArray())) if (J.Str(h) is string s) package.PreviousStudio.Add(s);
        return package;
    }
    static void FlushFile(string path) { using var s = new FileStream(path, FileMode.Open, FileAccess.ReadWrite); s.Flush(true); }
    static bool ReadBack(string path, byte[] expected) { try { return File.ReadAllBytes(path).AsSpan().SequenceEqual(expected); } catch { return false; } }
    static string Utc(DateTime t) => t.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

    /* A separate immutable source archive, independent of transaction backups.
       Known Studio images are not mislabeled as pre-Studio originals. */
    static bool ArchiveInitial(byte[] data, FirmwarePackage package, string location, ErrorSlot error)
    {
        string hash = Sha256(data); bool factory = package.Labels.TryGetValue(hash, out var l) && l.StartsWith("Заводская");
        if ((package.Images.ContainsKey(hash) && !factory) || package.PreviousStudio.Contains(hash)) return true;
        string device = $"Flow2-{package.Model}-USB-{Safe(location ?? "0")}";
        string folder = Path.Combine(BackupRoot, "Original", device, hash);
        try { Directory.CreateDirectory(folder); } catch (Exception e) { Fail(error, e.Message); return false; }
        string path = Path.Combine(folder, "original.bin");
        if (FlowFlashCore.BackupWriteOnce(path, data) == 0 || !ReadBack(path, data)) { Fail(error, "Исходная копия не прошла проверку. Существующий файл не перезаписан; запись прошивки не начата."); return false; }
        string metadata = Path.Combine(folder, "info.json");
        if (File.Exists(metadata))
        {
            JsonObject info = null; try { info = JsonNode.Parse(File.ReadAllBytes(metadata)) as JsonObject; } catch { }
            if (info == null || J.Str(info["sha256"]) != hash || J.Str(info["location"]) != (location ?? "0")) { Fail(error, "Сведения об исходной копии повреждены. Запись прошивки не начата."); return false; }
            return true;
        }
        FlowFlashCore.Identify(data, out uint release);
        var record = J.O(("model", package.Model), ("usbRelease", release), ("location", location ?? "0"), ("sha256", hash), ("bytes", data.Length), ("createdAt", Utc(DateTime.UtcNow)),
            ("kind", factory ? "verified-factory" : "initial-image"), ("label", factory ? package.Labels[hash] : $"Исходная прошивка перед Studio · USB 0x{release:x4}"));
        byte[] raw = JsonSerializer.SerializeToUtf8Bytes(record, Pretty);
        if (FlowFlashCore.BackupWriteOnce(metadata, raw) == 0) { Fail(error, "Не удалось сохранить сведения об исходной копии. Запись прошивки не начата."); return false; }
        return true;
    }
    static string Safe(string s) { foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_'); return s.Replace('#', '_'); }

    /* Returns image/sha256/label/model/file for an explicit restore from a local file. */
    public static JsonObject ReadBackup(string path, out byte[] image, ErrorSlot error)
    {
        image = null;
        FileInfo info; try { info = new FileInfo(path); } catch { Fail(error, "Выберите локальный файл резервной копии .bin."); return null; }
        if (!info.Exists || info.Length != FlowFlashCore.FlashSize) { Fail(error, "Копия должна быть полным образом прошивки размером 256 КБ."); return null; }
        try { image = File.ReadAllBytes(path); } catch (Exception e) { Fail(error, e.Message); return null; }
        string hash = Sha256(image); uint model = FlowFlashCore.Identify(image, out uint release);
        if (model == 0) { image = null; Fail(error, "Копия не является полным образом обычной Flow 2 68/84/100: модель или таблица запуска не подтверждены."); return null; }
        var package = CatalogForModel(model, error); if (package == null) { image = null; return null; }
        string label = package.Labels.TryGetValue(hash, out var known) ? known : $"Личная копия Flow 2 {model} · USB 0x{release:x4}";
        return J.O(("sha256", hash), ("label", label), ("model", model.ToString()), ("file", path));
    }
    static bool SaveUnsupportedSnapshot(byte[] data, string location)
    {
        try
        {
            string folder = Path.Combine(BackupRoot, "unsupported-" + Sha256(data)); Directory.CreateDirectory(folder);
            string path = Path.Combine(folder, "before.bin");
            File.WriteAllBytes(path, data); FlushFile(path);
            if (!ReadBack(path, data)) return false;
            var info = J.O(("sha256", Sha256(data)), ("location", location ?? "0"), ("status", "unsupported-no-writes"), ("bytes", data.Length));
            File.WriteAllBytes(Path.Combine(folder, "info.json"), JsonSerializer.SerializeToUtf8Bytes(info, Pretty));
            return true;
        }
        catch { return false; }
    }
    static byte[] RecordImage(JsonObject record, string folder, string key, string filename, FirmwarePackage package)
    {
        string hash = J.Str(record[key]); if (hash == null) return null;
        byte[] data = package.Images.TryGetValue(hash, out var known) ? known : null;
        if (data == null) try { data = File.ReadAllBytes(Path.Combine(folder, filename)); } catch { }
        if (data == null || data.Length != FlowFlashCore.FlashSize || Sha256(data) != hash || FlowFlashCore.Identify(data) != uint.Parse(package.Model)) return null;
        return data;
    }
    static RecoveryRecord RecordForKey(string key, FirmwarePackage package, string location)
    {
        if (location == null) return null;
        var records = new List<RecoveryRecord>();
        string[] children; try { children = Directory.GetDirectories(BackupRoot); } catch { return null; }
        foreach (string path in children)
        {
            JsonObject record = null; try { record = JsonNode.Parse(File.ReadAllBytes(Path.Combine(path, "record.json"))) as JsonObject; } catch { }
            if (record == null || J.Str(record["location"]) != location || J.Str(record["model"]) != package.Model) continue;
            if (!DateTime.TryParse(J.Str(record["createdAt"]), null, System.Globalization.DateTimeStyles.RoundtripKind, out var created)) continue;
            byte[] rollback = RecordImage(record, path, "rollbackSHA256", "rollback.bin", package), target = RecordImage(record, path, "targetSHA256", "target.bin", package);
            if (rollback == null || target == null) continue;
            string operation = J.Str(record["operation"]);
            bool beforeIsRollback = J.Str(record["beforeSHA256"]) == J.Str(record["rollbackSHA256"]);
            if (key == "oem14Rollback" && (!(operation == "install-oem14" || operation == "prepare-v14") || !beforeIsRollback)) continue;
            if (key == "firmwareRestoreRecord" && (operation != "prepare" || !beforeIsRollback)) continue;
            byte[] before = null; try { before = File.ReadAllBytes(Path.Combine(path, "before.bin")); } catch { }
            if (before == null || before.Length != FlowFlashCore.FlashSize || Sha256(before) != J.Str(record["beforeSHA256"])) continue;
            records.Add(new RecoveryRecord { Values = record, Folder = path, CreatedAt = created, RollbackImage = rollback, TargetImage = target, BeforeImage = before });
        }
        records.Sort((a, b) => b.CreatedAt.CompareTo(a.CreatedAt));
        if (records.Count == 0) return null;
        return key == "firmwareRestoreRecord" ? records[^1] : records[0];
    }
    static string Location(JsonObject device) => J.Str(device["usbLocation"]) ?? J.Str(device["location"]);
    static FirmwarePackage PackageForDevice(JsonObject device, ErrorSlot error)
    {
        uint model = (uint)J.Int(device["model"]); if (Flow.ModelFor((int)model).Number != 0) return CatalogForModel(model, error);
        string location = Location(device); RecoveryRecord latest = null; FirmwarePackage selected = null;
        foreach (uint candidate in new uint[] { 68, 84, 100 })
        {
            var package = CatalogForModel(candidate, error); if (package == null) return null;
            var record = RecordForKey("firmwareRecoveryRecord", package, location);
            if (record != null && (latest == null || record.CreatedAt > latest.CreatedAt)) { latest = record; selected = package; }
        }
        return selected ?? CatalogForModel(68, error);
    }
    public static JsonObject Status(JsonObject device)
    {
        var error = new ErrorSlot(); var package = PackageForDevice(device, error);
        if (package == null) return J.O(("available", false), ("message", error.Value?.Message ?? "Пакет подготовки недоступен"));
        bool dfu = J.Bool(device["bootloader"]); var shape = Flow.ModelFor(J.Int(device["model"]));
        bool wired = shape.Number != 0 && J.Str(device["connection"]) == "USB" && J.Int(device["vid"]) == 0x388d && J.UInt(device["pid"]) == shape.Pid;
        string location = Location(device);
        bool verifiedRecovery = dfu && RecordForKey("firmwareRecoveryRecord", package, location) != null, rollback = RecordForKey("oem14Rollback", package, location) != null;
        return J.O(("canInstallOEM14", false), ("base14Target", true), ("model", package.Model), ("canRollbackOEM14", (wired || dfu) && rollback), ("oem14Installed", wired && J.Int(device["version"]) == 0x14),
            ("available", true), ("wired", wired), ("recovery", dfu), ("canPrepare", (wired || verifiedRecovery) && package.Enabled), ("canRestoreFactory", wired || verifiedRecovery), ("canRestore", wired || dfu),
            ("backupExists", Directory.Exists(BackupRoot)),
            ("message", dfu ? "Клавиатура в режиме восстановления. Подключение USB сохранено." : wired ? "Можно проверить совместимость и подготовить клавиатуру." : "Подключите обычную Flow 2 68, 84 или 100 кабелем в проводном USB-режиме."));
    }

    sealed class DFU : IDisposable
    {
        public Native.WinUsbDevice Device;
        public bool ChipVerified, Restore;
        public Dictionary<string, byte[]> Images; public Dictionary<string, string> Labels;
        public string Folder, RollbackHash, TargetHash, Location, Model, Operation, LastError;
        public uint SourceRelease; public uint[] PageOffsets;
        public Action<JsonObject> Progress;

        public bool OpenLocation(string location, ErrorSlot error)
        {
            var services = DfuServices();
            if (services.Count == 0) { Fail(error, "Загрузчик WB32 не обнаружен по USB. Запись прошивки не начиналась. Для расширений 3.9/3.10 войдите вручную: удерживайте Fn, затем левый Shift, затем нажмите Esc и выберите появившееся устройство восстановления."); return false; }
            if (services.Count != 1) { Fail(error, $"Найдено устройств восстановления USB: {services.Count}. Оставьте подключённой одну клавиатуру для восстановления."); return false; }
            var (actual, node) = services.First();
            if (location != null && actual != location) { Fail(error, "Загрузчик появился на другом USB-порту. Запись запрещена."); return false; }
            Location = actual;
            var path = Native.Interfaces(Native.UsbDeviceInterface).FirstOrDefault(i => i.DevInst == node)?.Path;
            if (path == null) { Fail(error, "Windows did not open the USB bootloader interface. Install the WinUSB driver for the WB32 bootloader (VID 342D, PID DFA0), then try again. No firmware was written."); return false; }
            Device = Native.WinUsbDevice.Open(path, out string problem);
            if (Device == null)
            {
                Fail(error, problem switch
                {
                    "busy" => "Загрузчик USB занят. Закройте VIA и другие утилиты.",
                    "driver" => "Windows did not open the USB bootloader interface. Install the WinUSB driver for the WB32 bootloader (VID 342D, PID DFA0), then try again. No firmware was written.",
                    "interface" => "Неоднозначный интерфейс загрузчика",
                    _ => "Неизвестные конечные точки загрузчика. Запись запрещена.",
                });
                return false;
            }
            return true;
        }
        public byte[] Exchange(byte[] packet, uint expected)
        {
            var images = Images.Values.Take(32).ToList();
            uint[] pages = PageOffsets ?? System.Array.Empty<uint>();
            if (pages.Length > FlowFlashCore.MaxPages) { LastError = "Неверная карта страниц"; return null; }
            if (!FlowFlashCore.DfuAllowed(packet, expected, ChipVerified, images, pages, pages.Length)) { LastError = "Команда вне разрешённых областей памяти отклонена"; return null; }
            if (!Device.Write(packet)) { LastError = "Ошибка передачи USB: " + Native.WinUsbDevice.LastError(); return null; }
            byte[] response = Device.Read(512);
            if (response == null || response.Length != expected || response.Length < 2 || response[1] != 0)
            {
                LastError = response != null && response.Length >= 2 && response[1] == 0x1a ? "Загрузчик сообщил защиту памяти. Защита не изменяется." : "Загрузчик не подтвердил операцию USB";
                return null;
            }
            return response;
        }
        public bool Read(uint address, byte[] bytes, int size)
        {
            var p = new byte[10]; p[0] = 0x72; FlowFlashCore.Put32(p.AsSpan(4), address); p[8] = (byte)size; p[9] = (byte)(size >> 8);
            var reply = Exchange(p, (uint)size + 2); if (reply == null) return false;
            System.Array.Copy(reply, 2, bytes, 0, size); return true;
        }
        public bool Page(uint address, byte[] source, int offset)
        {
            var p = new byte[12]; p[0] = 0x5e; FlowFlashCore.Put32(p.AsSpan(4), address); FlowFlashCore.Put32(p.AsSpan(8), 1);
            if (Exchange(p, 2) == null) return false;
            var w = new byte[268]; w[0] = 0x6a; FlowFlashCore.Put32(w.AsSpan(4), address); FlowFlashCore.Put32(w.AsSpan(8), 256); System.Array.Copy(source, offset, w, 12, 256);
            return Exchange(w, 2) != null;
        }
        public bool Save(byte[] data)
        {
            try
            {
                Folder = Path.Combine(BackupRoot, Guid.NewGuid().ToString().ToUpperInvariant());
                Directory.CreateDirectory(Folder);
            }
            catch { LastError = "Не удалось создать резервную копию. Запись не начата."; return false; }
            string path = Path.Combine(Folder, "before.bin");
            try { File.WriteAllBytes(path, data); } catch { LastError = "Не удалось сохранить резервную копию. Запись не начата."; return false; }
            bool durable; try { FlushFile(path); durable = true; } catch { durable = false; }
            if (!durable || !ReadBack(path, data)) { LastError = "Резервная копия не прошла проверку. Запись не начата."; return false; }
            foreach (var name in new[] { "rollback", "target" })
            {
                string hash = name == "rollback" ? RollbackHash : TargetHash; Images.TryGetValue(hash, out var image); string file = Path.Combine(Folder, name + ".bin");
                if (image == null || image.Length != FlowFlashCore.FlashSize || Sha256(image) != hash || FlowFlashCore.BackupWriteOnce(file, image) == 0 || !ReadBack(file, image)) { LastError = "Не удалось сохранить и проверить образы восстановления. Запись не начата."; return false; }
            }
            string beforeHash = Sha256(data);
            var record = J.O(("model", Model), ("usbRelease", SourceRelease), ("beforeFirmware", Labels.TryGetValue(beforeHash, out var bl) ? bl : "Неизвестная версия"),
                ("targetFirmware", Labels.TryGetValue(TargetHash, out var tl) ? tl : "Неизвестная версия"), ("beforeSHA256", beforeHash), ("rollbackSHA256", RollbackHash), ("targetSHA256", TargetHash),
                ("location", Location), ("createdAt", DateTime.UtcNow.ToString("O")), ("operation", Operation ?? (Restore ? "restore" : "prepare")));
            string recordPath = Path.Combine(Folder, "record.json");
            try
            {
                string temp = recordPath + ".tmp";
                File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(record, Pretty)); FlushFile(temp); File.Move(temp, recordPath);
            }
            catch { LastError = "Не удалось сохранить сведения для восстановления. Запись не начата."; return false; }
            JsonObject saved = null; try { saved = JsonNode.Parse(File.ReadAllBytes(recordPath)) as JsonObject; } catch { }
            foreach (var key in new[] { "beforeSHA256", "rollbackSHA256", "targetSHA256", "location", "operation" })
                if (saved == null || !J.Same(saved[key], record[key])) { LastError = "Сведения для отката не прошли проверку чтением. Запись не начата."; return false; }
            try { FlushFile(recordPath); } catch { LastError = "Не удалось зафиксировать сведения восстановления"; return false; }
            FlowPreferences.Set("firmwareRecoveryRecord", Folder);
            if (!Restore && RollbackHash == beforeHash) FlowPreferences.Set("firmwareRestoreRecord", Folder);
            Report("backup-saved", 1, 1); return true;
        }
        public void Report(string phase, uint done, uint total) => Progress?.Invoke(J.O(("phase", phase), ("done", done), ("total", total)));
        public bool Reset() => Exchange(new byte[] { 0x83, 0, 0, 0, 0xe8, 3, 0, 0 }, 2) != null;
        public void Dispose() => Device?.Dispose();
    }

    public static JsonObject Prepare(JsonObject selected, uint restoreMode, byte[] restoreImage, Action<JsonObject> progress, ErrorSlot error)
    {
        bool restore = restoreMode != 0;
        if (restoreMode > 4) { Fail(error, "Неизвестный режим восстановления"); return null; }
        var package = PackageForDevice(selected, error); if (package == null) return null;
        if (restoreMode == 2)
        {
            uint model = FlowFlashCore.Identify(restoreImage);
            if (model == 0 || (!J.Bool(selected["bootloader"]) && model != (uint)J.Int(selected["model"]))) { Fail(error, "Копия не соответствует модели клавиатуры. Запись не начата."); return null; }
            package = CatalogForModel(model, error); if (package == null) return null;
        }
        if (restoreMode == 0 && !package.Enabled) { Fail(error, "Пакет модели недоступен. Запись заблокирована."); return null; }
        string chosenHash = restoreImage != null ? Sha256(restoreImage) : null;
        try { Directory.CreateDirectory(BackupRoot); } catch { Fail(error, "Не удалось подготовить папку резервных копий. Запись не начата."); return null; }
        long free; try { free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(BackupRoot))).AvailableFreeSpace; } catch { free = 0; }
        if (free < 8 * 1024 * 1024) { Fail(error, "Для резервных копий нужно минимум 8 МБ свободного места. Запись не начата."); return null; }
        JsonObject device = null;
        if (J.Bool(selected["bootloader"])) { foreach (var d in Devices().OfType<JsonObject>()) if (J.Same(d["id"], selected["id"])) device = d; }
        else { foreach (var d in FlowTransport.Devices().OfType<JsonObject>()) if (J.Same(d["id"], selected["id"])) device = d; }
        if (device == null) { Fail(error, "Клавиатура отключена"); return null; }
        string location = Location(device);
        var recoveryRecord = RecordForKey("firmwareRecoveryRecord", package, location);
        if (restoreMode == 4)
        {
            var record = RecordForKey("oem14Rollback", package, location); chosenHash = record?.Get("beforeSHA256");
            if (chosenHash == null || !record.BeforeImage.AsSpan().SequenceEqual(record.RollbackImage)) { Fail(error, "Проверенная копия перед 0.14 для этого USB-порта не найдена. Выберите before.bin через «Выбрать копию прошивки»."); return null; }
            restoreImage = record.RollbackImage;
        }
        bool recovery = J.Bool(device["bootloader"]);
        if (!recovery)
        {
            if (!J.Bool(Status(device)["canPrepare"]) || DfuServices().Count > 0) { Fail(error, "Нужно подключить выбранную Flow 2 кабелем в проводном режиме. Другие устройства восстановления должны быть отключены."); return null; }
            int wired = FlowTransport.Devices().OfType<JsonObject>().Count(d => J.Bool(Status(d)["canPrepare"]));
            if (wired != 1) { Fail(error, "На время подготовки оставьте одну проводную Flow 2."); return null; }
            if (location == null) { Fail(error, "Не удалось подтвердить USB-порт устройства"); return null; }
            // Windows-only gate: without WinUSB on the bootloader the keyboard would be left in recovery mode unreachable.
            if (!WinUsbBound()) { Fail(error, "The WB32 bootloader has no WinUSB driver on this PC yet. Enter recovery manually (hold Fn, then left Shift, then press Esc), install WinUSB for USB ID 342D:DFA0 (for example with Zadig), reconnect the keyboard normally and try again. Nothing was written."); return null; }
            progress?.Invoke(J.O(("phase", "entering"), ("done", 0), ("total", 1)));
            bool sent = false;
            string path = J.Str(device["path"]);
            using (var hid = path == null ? null : Native.HidPort.Open(path, out _))
            {
                if (hid != null && hid.OutputLength == 33)
                {
                    var command = new byte[33]; System.Array.Fill(command, (byte)0xfe); command[0] = 0; command[1] = 0x0b;
                    sent = hid.Write(command, 2000);
                }
            }
            if (!sent) { Fail(error, "Не удалось начать подготовку. Закройте VIA и проверьте доступ к клавиатуре."); return null; }
            for (int n = 0; n < 60 && DfuServices().Count == 0; n++) Thread.Sleep(250);
        }
        using var dfu = new DFU { Images = package.Images, Labels = package.Labels, Progress = progress, Restore = restore, Model = package.Model, PageOffsets = package.Pages };
        if (!dfu.OpenLocation(location, error)) return null;
        byte[] info = dfu.Exchange(new byte[] { 1, 0 }, 16);
        if (info == null || info[2] != 13 || info[3] != 4 || FlowFlashCore.U32(info.AsSpan(4)) != 0x3a50e980 || FlowFlashCore.U32(info.AsSpan(8)) != FlowFlashCore.FlashSize || FlowFlashCore.U32(info.AsSpan(12)) != 36864)
        { Fail(error, "Модель контроллера не подтверждена. Запись не выполнялась; устройство оставлено в режиме восстановления."); return null; }
        dfu.ChipVerified = true;
        var io = new FlowFlashCore.IOPort { Read = dfu.Read, Page = dfu.Page, Backup = dfu.Save, Progress = dfu.Report };
        byte[] before = new byte[FlowFlashCore.FlashSize], second = new byte[FlowFlashCore.FlashSize];
        if (!FlowFlashCore.ReadAll(io, before, "reading") || !FlowFlashCore.ReadAll(io, second, "checking-backup") || !before.AsSpan().SequenceEqual(second))
        { Fail(error, "Две копии памяти не совпали или чтение прервано. Запись не выполнялась. Повторите проверку по USB."); return null; }
        string sourceHash = Sha256(before); uint sourceModel = FlowFlashCore.Identify(before, out uint sourceRelease);
        uint modelNumber = uint.Parse(package.Model); bool intact = sourceModel == modelNumber;
        var images = new Dictionary<string, byte[]>(package.Images); var labels = new Dictionary<string, string>(package.Labels);
        if (restoreImage != null) { images[chosenHash] = restoreImage; labels.TryAdd(chosenHash, "Личная резервная копия"); }
        byte[] recordSource = recoveryRecord?.RollbackImage, recordTarget = recoveryRecord?.TargetImage;
        var recordPages = new uint[FlowFlashCore.MaxPages];
        int recordCount = recordSource != null && recordTarget != null ? FlowFlashCore.MigrationPages(recordSource, recordTarget, recordSource, recordPages) : 0;
        bool interrupted = recovery && recordCount > 0 && !before.AsSpan().SequenceEqual(recordSource) && !before.AsSpan().SequenceEqual(recordTarget) && FlowFlashCore.InterruptedMatches(before, recordSource, recordTarget, recordPages, recordCount);
        if (interrupted) intact = false;
        if (!intact && !interrupted)
        {
            bool snapshot = SaveUnsupportedSnapshot(before, dfu.Location); if (!recovery) dfu.Reset();
            Fail(error, snapshot ? "Модель исходного образа не подтверждена или память повреждена. Снимок сохранён, запись не начата. Для прерванной записи используйте тот же USB-порт и сохранённые сведения восстановления." : "Исходный образ не подтверждён. Запись не начата.");
            return null;
        }
        if (interrupted && !restore) { Fail(error, "Обнаружена прерванная запись. Сначала восстановите сохранённую прошивку."); return null; }
        if (intact) { images[sourceHash] = before; labels.TryAdd(sourceHash, $"Исходная Flow 2 {modelNumber} · USB 0x{sourceRelease:x4}"); }
        else { images[recoveryRecord.Get("rollbackSHA256")] = recordSource; images[recoveryRecord.Get("targetSHA256")] = recordTarget; }
        string desiredHash = restoreMode == 1 ? package.Factory : (restoreMode == 2 || restoreMode == 4) ? chosenHash : restoreMode == 3 ? package.OEM14 : package.Target;
        images.TryGetValue(desiredHash ?? "", out var desired);
        string rollbackHash = intact ? sourceHash : recoveryRecord.Get("rollbackSHA256"); images.TryGetValue(rollbackHash ?? "", out var rollback);
        if (desired?.Length != FlowFlashCore.FlashSize || rollback?.Length != FlowFlashCore.FlashSize || FlowFlashCore.Identify(desired) != modelNumber || FlowFlashCore.Identify(rollback) != modelNumber)
        { Fail(error, "Модель образа восстановления не совпала. Запись не начата."); return null; }
        dfu.Images = new Dictionary<string, byte[]> { [rollbackHash] = rollback, [desiredHash] = desired };
        dfu.Labels = labels; dfu.SourceRelease = sourceRelease; dfu.RollbackHash = rollbackHash; dfu.TargetHash = desiredHash;
        dfu.Operation = !restore && sourceHash != desiredHash ? "prepare-v14" : restore ? "restore" : "prepare";
        if (!restore && !ArchiveInitial(before, package, dfu.Location, error)) { if (intact) dfu.Reset(); return null; }
        if (before.AsSpan().SequenceEqual(desired))
        {
            if (!dfu.Save(before)) { if (intact) dfu.Reset(); Fail(error, dfu.LastError); return null; }
            bool resetDone = dfu.Reset();
            return J.O(("verified", true), ("already", true), ("resetAcknowledged", resetDone), ("location", dfu.Location), ("restored", restore));
        }
        var pageStorage = new uint[FlowFlashCore.MaxPages];
        int pageCount = FlowFlashCore.MigrationPages(before, desired, rollback, pageStorage);
        dfu.PageOffsets = pageStorage.Take(pageCount).ToArray();
        int status = FlowFlashCore.TransactionBounded(io, before, desired, rollback, pageStorage, pageCount, pageCount);
        bool safe = status == FlowFlashCore.OK || status == FlowFlashCore.Already || status == FlowFlashCore.RolledBack
            || ((status == FlowFlashCore.BackupFailed || status == FlowFlashCore.Invalid || status == FlowFlashCore.IO) && intact);
        bool reset = safe && dfu.Reset();
        if (status != FlowFlashCore.OK && status != FlowFlashCore.Already)
        {
            string message = status == FlowFlashCore.RolledBack ? "Подготовка не завершилась. Прежняя прошивка восстановлена и проверена."
                : status == FlowFlashCore.Unsafe ? "Связь прервалась. Не удалось подтвердить восстановление. Подключите клавиатуру по USB и выберите «Восстановить»."
                : dfu.LastError ?? "Подготовка остановлена до записи.";
            Fail(error, message); return null;
        }
        return J.O(("verified", true), ("resetAcknowledged", reset), ("backup", dfu.Folder ?? ""), ("location", dfu.Location), ("restored", restore));
    }
}
