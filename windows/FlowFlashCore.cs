// Byte-level port of FlowFlashCore.h, FlowDFUWire.h, FlowFirmwareModel.h, FlowFirmwareMigration.h,
// FlowFirmwareConsent.h, FlowV14Registry.h and FlowBackupFile.h. No OS calls except the backup file.
namespace Flow2Studio;

static class FlowFlashCore
{
    public const int FlashSize = 262144, PageSize = 256, MaxPages = FlashSize / PageSize;
    public const uint FlashBase = 0x08000000u;
    public const int OK = 1, Already = 2, IO = -1, RolledBack = -2, Unsafe = -3, Invalid = -4, BackupFailed = -5;

    /* All mutations go through a bounded page callback. */
    public sealed class IOPort
    {
        public Func<uint, byte[], int, bool> Read;      // address, destination, size
        public Func<uint, byte[], int, bool> Page;      // address, source, offset
        public Func<byte[], bool> Backup;
        public Action<string, uint, uint> Progress;
    }

    public static bool PageAllowed(uint offset, uint[] pages, int count) { for (int i = 0; i < count; i++) if (pages[i] == offset) return true; return false; }
    static bool PageEqual(byte[] a, int ao, byte[] b, int bo) => a.AsSpan(ao, PageSize).SequenceEqual(b.AsSpan(bo, PageSize));
    public static bool OutsideMatches(byte[] image, byte[] reference, uint[] pages, int count)
    {
        for (uint offset = 0; offset < FlashSize; offset += PageSize)
            if (!PageAllowed(offset, pages, count) && !PageEqual(image, (int)offset, reference, (int)offset)) return false;
        return true;
    }
    public static bool InterruptedMatches(byte[] current, byte[] source, byte[] target, uint[] pages, int count)
    {
        if (current == null || source == null || target == null || pages == null || count == 0 || count > MaxPages) return false;
        for (int p = 0; p < count; p++) if (pages[p] % PageSize != 0 || pages[p] > FlashSize - PageSize || (p > 0 && pages[p] <= pages[p - 1])) return false;
        if (!OutsideMatches(current, source, pages, count) || !OutsideMatches(source, target, pages, count)) return false;
        for (int p = 0; p < count; p++) for (uint i = 0; i < PageSize; i++) { uint o = pages[p] + i; byte b = current[o]; if (b != source[o] && b != target[o] && b != 255) return false; }
        return true;
    }
    public static bool ReadAll(IOPort io, byte[] image, string phase)
    {
        var page = new byte[PageSize];
        for (uint offset = 0; offset < FlashSize; offset += PageSize)
        {
            if (!io.Read(FlashBase + offset, page, PageSize)) return false;
            Array.Copy(page, 0, image, offset, PageSize);
            if (io.Progress != null && (offset + PageSize) % 16384 == 0) io.Progress(phase, offset + PageSize, FlashSize);
        }
        return true;
    }
    static bool Apply(IOPort io, byte[] target, uint[] pages, int count, string phase)
    {
        byte[] current = new byte[PageSize], zero = new byte[PageSize]; uint completed = 0;
        /* Restore hooks before clearing removed stubs; install nonempty bodies before hooks. */
        for (uint stageIndex = 0; stageIndex < 3; stageIndex++)
            for (int n = count; n > 0; n--)
            {
                uint offset = pages[n - 1];
                uint stage = offset >= 0xf000u ? (target.AsSpan((int)offset, PageSize).SequenceEqual(zero) ? 2u : 0u) : 1u;
                if (stage != stageIndex) continue;
                if (!io.Read(FlashBase + offset, current, PageSize)) return false;
                if (!PageEqual(current, 0, target, (int)offset))
                {
                    if (!io.Page(FlashBase + offset, target, (int)offset)) return false;
                    if (!io.Read(FlashBase + offset, current, PageSize) || !PageEqual(current, 0, target, (int)offset)) return false;
                }
                completed++; io.Progress?.Invoke(phase, completed, (uint)count);
            }
        return true;
    }
    /* Host authenticates the packaged target and verified local source/backup before use. */
    public static int TransactionBounded(IOPort io, byte[] before, byte[] desired, byte[] rollback, uint[] pages, int count, int maximum)
    {
        if (io?.Read == null || io.Page == null || io.Backup == null || before == null || desired == null || rollback == null || count == 0 || maximum > MaxPages || count > maximum) return Invalid;
        for (int i = 0; i < count; i++) if (pages[i] % PageSize != 0 || pages[i] + PageSize > FlashSize || (i > 0 && pages[i] <= pages[i - 1])) return Invalid;
        if (!OutsideMatches(before, desired, pages, count) || !OutsideMatches(rollback, desired, pages, count)) return Invalid;
        if (!io.Backup(before)) return BackupFailed;
        if (before.AsSpan().SequenceEqual(desired)) return Already;
        var verified = new byte[FlashSize];
        bool ok = Apply(io, desired, pages, count, "writing") && ReadAll(io, verified, "verifying") && verified.AsSpan().SequenceEqual(desired);
        if (ok) return OK;
        bool restored = Apply(io, rollback, pages, count, "rollback") && ReadAll(io, verified, "rollback-verifying") && verified.AsSpan().SequenceEqual(rollback);
        return restored ? RolledBack : Unsafe;
    }

    // ---- FlowDFUWire.h ----
    public static uint U32(ReadOnlySpan<byte> b) => (uint)b[0] | ((uint)b[1] << 8) | ((uint)b[2] << 16) | ((uint)b[3] << 24);
    public static void Put32(Span<byte> b, uint n) { for (int i = 0; i < 4; i++) b[i] = (byte)(n >> (8 * i)); }
    static readonly byte[] ResetCommand = { 0x83, 0, 0, 0, 0xe8, 3, 0, 0 };
    public static bool DfuAllowed(byte[] b, uint expected, bool chipVerified, IReadOnlyList<byte[]> images, uint[] pages, int pageCount)
    {
        int n = b?.Length ?? 0;
        if (b == null || n < 2) return false;
        if (n == 2 && b[0] == 1 && b[1] == 0) return expected == 16;
        if (n == 8 && b.AsSpan().SequenceEqual(ResetCommand)) return expected == 2;
        if (!chipVerified || n < 10 || b[1] != 0 || b[2] != 0 || b[3] != 0) return false;
        uint address = U32(b.AsSpan(4));
        if (n == 10 && b[0] == 0x72) { uint count = (uint)(b[8] | (b[9] << 8)); return count > 0 && count <= 256 && address >= FlashBase && address <= FlashBase + FlashSize - count && expected == count + 2; }
        if (expected != 2 || (n != 12 && n != 268) || address < FlashBase || !PageAllowed(address - FlashBase, pages, pageCount)) return false;
        uint c = U32(b.AsSpan(8));
        if (n == 12 && b[0] == 0x5e) return c == 1;
        if (n == 268 && b[0] == 0x6a && c == 256)
            foreach (var image in images) if (image != null && b.AsSpan(12, 256).SequenceEqual(image.AsSpan((int)(address - FlashBase), 256))) return true;
        return false;
    }

    // ---- FlowFirmwareModel.h ----
    static bool Descriptor(byte[] image, int n) => image[n] == 18 && image[n + 1] == 1 && image[n + 8] == 0x8d && image[n + 9] == 0x38;
    public static bool FirmwareModelMatches(byte[] image, uint model, uint release)
    {
        var shape = Flow.ModelFor((int)model);
        if (image == null || image.Length != FlashSize || shape.Number == 0 || (release != 9 && release != 20)) return false;
        uint matches = 0;
        for (int n = 0; n + 18 <= image.Length; n++)
            if (Descriptor(image, n))
            {
                if ((uint)(image[n + 10] | image[n + 11] << 8) != shape.Pid || (uint)(image[n + 12] | image[n + 13] << 8) != release) return false;
                matches++;
            }
        return matches == 1;
    }

    // ---- FlowFirmwareMigration.h ---- Model identity is independent of bcdDevice/version and catalog membership.
    public static uint Identify(byte[] image, out uint release)
    {
        release = 0;
        if (image == null || image.Length != FlashSize) return 0;
        uint sp = U32(image), pc = U32(image.AsSpan(4));
        if (sp <= 0x20000000u || sp > 0x20009000u || (sp & 7) != 0 || (pc & 1) == 0 || pc < FlashBase || pc >= FlashBase + (uint)image.Length) return 0;
        uint count = 0, model = 0, value = 0;
        for (int n = 0; n + 18 <= image.Length; n++)
        {
            if (!Descriptor(image, n)) continue;
            uint pid = (uint)(image[n + 10] | image[n + 11] << 8); model = pid == 1 ? 68u : pid == 2 ? 84u : pid == 3 ? 100u : 0; value = (uint)(image[n + 12] | image[n + 13] << 8); count++;
        }
        if (count != 1 || model == 0) return 0;
        release = value;
        return model;
    }
    public static uint Identify(byte[] image) => Identify(image, out _);
    /* Exact transaction-specific page union, not a blanket erase permission. */
    public static int MigrationPages(byte[] before, byte[] desired, byte[] rollback, uint[] pages)
    {
        if (before == null || desired == null || rollback == null || pages == null) return 0;
        int count = 0;
        for (uint o = 0; o < FlashSize; o += PageSize)
            if (!PageEqual(before, (int)o, desired, (int)o) || !PageEqual(rollback, (int)o, desired, (int)o)) pages[count++] = o;
        return count;
    }

    // ---- FlowFirmwareConsent.h ----
    public static bool ConsentValid(double now, double deadline, ulong generation, ulong expectedGeneration, bool tokenMatches, bool deviceAndActionMatch) =>
        tokenMatches && deviceAndActionMatch && generation == expectedGeneration && double.IsFinite(now) && double.IsFinite(deadline) && now >= 0 && deadline > now && deadline - now <= 120;
    /* Only explicit file restore carries a chosen backup. */
    public static bool BackupSelectionValid(uint mode, bool bootloader, uint backupModel, uint selectedModel, bool hasImage)
    {
        if (mode != 2) return true;
        if (!hasImage || (backupModel != 68 && backupModel != 84 && backupModel != 100)) return false;
        return bootloader || backupModel == selectedModel;
    }

    // ---- FlowV14Registry.h ----
    public static string CatalogSha(uint model) => model switch
    {
        68 => "9cc5deac6b9fa59062657d40904ec9e2eede0ca75c44a0350701021ba319b6ee",
        84 => "f30dfdbc4d2104dd25e3e67ad6e5b2a167a0e3f95f86806e60077c0640aa3594",
        100 => "6ab307f3964416d001cc10e9c7b30dab5d38744f76d7443080f0526c35f0f738",
        _ => null,
    };

    // ---- FlowBackupFile.h ---- Never truncates/replaces an existing original. Existing bytes must match.
    /* 1: written and flushed, 2: existing identical file, 0: failure. */
    public static int BackupWriteOnce(string path, byte[] bytes)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(bytes);
            stream.Flush(true);
            return 1;
        }
        catch (IOException) when (File.Exists(path))
        {
            try
            {
                var info = new FileInfo(path);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length != bytes.Length) return 0;
                return File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes) ? 2 : 0;
            }
            catch { return 0; }
        }
        catch { return 0; }
    }
}
