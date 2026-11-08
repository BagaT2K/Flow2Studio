// Win32 interop used in place of IOKit: SetupAPI/CfgMgr32 enumeration, hid.dll, overlapped
// HID file I/O and WinUSB bulk pipes for the WB32 bootloader.
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Flow2Studio;

static class Native
{
    const uint DIGCF_PRESENT = 0x2, DIGCF_ALLCLASSES = 0x4, DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    const int ERROR_IO_PENDING = 997;
    const uint CM_DRP_LOCATION_PATHS = 0x24;
    public static readonly Guid UsbDeviceInterface = new("A5DCBF10-6530-11D2-901F-00C04FB951ED");

    [StructLayout(LayoutKind.Sequential)] struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public uint cbSize; public Guid InterfaceClassGuid; public uint Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] struct HIDD_ATTRIBUTES { public uint Size; public ushort VendorID, ProductID, VersionNumber; }
    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 10)] public ushort[] Counts;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SetupDiGetClassDevsW(ref Guid g, string enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr SetupDiGetClassDevsW(IntPtr g, string enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid g, uint index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, uint size, out uint required, ref SP_DEVINFO_DATA info);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref SP_DEVINFO_DATA info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("cfgmgr32.dll")] static extern int CM_Get_Parent(out uint parent, uint devInst, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_IDW(uint devInst, char[] buffer, int length, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_DevNode_Registry_PropertyW(uint devInst, uint property, out uint type, byte[] buffer, ref uint length, uint flags);
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] static extern bool HidD_GetProductString(SafeFileHandle h, byte[] buffer, uint length);
    [DllImport("hid.dll")] static extern bool HidD_GetSerialNumberString(SafeFileHandle h, byte[] buffer, uint length);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(SafeFileHandle h, IntPtr buffer, uint length, IntPtr read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(SafeFileHandle h, IntPtr buffer, uint length, IntPtr written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetOverlappedResult(SafeFileHandle h, IntPtr overlapped, out uint transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CancelIoEx(SafeFileHandle h, IntPtr overlapped);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public sealed record Interface(string Path, uint DevInst);

    public static List<Interface> Interfaces(Guid guid)
    {
        var found = new List<Interface>();
        IntPtr set = SetupDiGetClassDevsW(ref guid, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return found;
        try
        {
            for (uint i = 0; ; i++)
            {
                var data = new SP_DEVICE_INTERFACE_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref data)) break;
                var info = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>() };
                SetupDiGetDeviceInterfaceDetailW(set, ref data, IntPtr.Zero, 0, out uint required, ref info);
                if (required == 0) continue;
                IntPtr detail = Marshal.AllocHGlobal((int)required);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetailW(set, ref data, detail, required, out _, ref info))
                        found.Add(new Interface(Marshal.PtrToStringUni(detail + 4), info.DevInst));
                }
                finally { Marshal.FreeHGlobal(detail); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }

    /* Present device nodes of one enumerator (e.g. "USB"), including nodes without a working driver. */
    public static List<uint> DeviceNodes(string enumerator)
    {
        var found = new List<uint>();
        IntPtr set = SetupDiGetClassDevsW(IntPtr.Zero, enumerator, IntPtr.Zero, DIGCF_PRESENT | DIGCF_ALLCLASSES);
        if (set == new IntPtr(-1)) return found;
        try
        {
            for (uint i = 0; ; i++)
            {
                var info = new SP_DEVINFO_DATA { cbSize = (uint)Marshal.SizeOf<SP_DEVINFO_DATA>() };
                if (!SetupDiEnumDeviceInfo(set, i, ref info)) break;
                found.Add(info.DevInst);
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return found;
    }

    public static string DeviceID(uint devInst)
    {
        var buffer = new char[400];
        return CM_Get_Device_IDW(devInst, buffer, buffer.Length, 0) == 0 ? new string(buffer).TrimEnd('\0') : "";
    }
    public static uint Parent(uint devInst) => CM_Get_Parent(out uint parent, devInst, 0) == 0 ? parent : 0;
    /* First entry of the port-specific location path, the equivalent of IOKit locationID. */
    public static string LocationPath(uint devInst)
    {
        uint length = 0;
        CM_Get_DevNode_Registry_PropertyW(devInst, CM_DRP_LOCATION_PATHS, out _, null, ref length, 0);
        if (length == 0) return null;
        var buffer = new byte[length];
        if (CM_Get_DevNode_Registry_PropertyW(devInst, CM_DRP_LOCATION_PATHS, out _, buffer, ref length, 0) != 0) return null;
        string first = Encoding.Unicode.GetString(buffer).Split('\0')[0];
        return first.Length > 0 ? first : null;
    }
    /* Walk from a HID collection to its USB device node (not a USB interface node). */
    public static uint UsbAncestor(uint devInst)
    {
        for (uint node = Parent(devInst); node != 0; node = Parent(node))
        {
            string id = DeviceID(node).ToUpperInvariant();
            if (id.StartsWith(@"USB\") && !id.Contains("&MI_")) return node;
            if (!id.StartsWith(@"USB\") && !id.StartsWith(@"HID\")) return 0;
        }
        return 0;
    }

    public static double KeyboardIdleSeconds(out uint lastInput)
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) { lastInput = 0; return -1; }
        lastInput = info.dwTime;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
    }

    // ---- HID ----
    public static Guid HidGuid() { HidD_GetHidGuid(out Guid g); return g; }
    public sealed record HidInfo(ushort Vendor, ushort Product, ushort Version, string Name, string Serial, ushort UsagePage, ushort Usage, int InputLength, int OutputLength);

    static string HidString(SafeFileHandle h, bool serial)
    {
        var buffer = new byte[256];
        bool ok = serial ? HidD_GetSerialNumberString(h, buffer, (uint)buffer.Length) : HidD_GetProductString(h, buffer, (uint)buffer.Length);
        return ok ? Encoding.Unicode.GetString(buffer).Split('\0')[0] : "";
    }
    static HidInfo Info(SafeFileHandle h)
    {
        var attributes = new HIDD_ATTRIBUTES { Size = (uint)Marshal.SizeOf<HIDD_ATTRIBUTES>() };
        if (!HidD_GetAttributes(h, ref attributes)) return null;
        var caps = new HIDP_CAPS();
        if (HidD_GetPreparsedData(h, out IntPtr data))
        {
            HidP_GetCaps(data, ref caps);
            HidD_FreePreparsedData(data);
        }
        return new HidInfo(attributes.VendorID, attributes.ProductID, attributes.VersionNumber, HidString(h, false), HidString(h, true), caps.UsagePage, caps.Usage, caps.InputReportByteLength, caps.OutputReportByteLength);
    }
    /* Query-only open (no read/write access) works for collections Windows keeps exclusive. */
    public static HidInfo QueryHid(string path)
    {
        using var h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        return h.IsInvalid ? null : Info(h);
    }

    /* One open HID collection with overlapped input and output, mirroring an opened IOHIDDevice. */
    public sealed class HidPort : IDisposable
    {
        public readonly SafeFileHandle Handle;
        public readonly int InputLength, OutputLength;
        readonly IntPtr readOverlapped, readBuffer, writeOverlapped, writeBuffer;
        readonly ManualResetEvent readEvent = new(false), writeEvent = new(false);
        bool reading, disposed;
        static int OverlappedSize => 2 * IntPtr.Size + 8 + IntPtr.Size;
        static int EventOffset => 2 * IntPtr.Size + 8;
        public WaitHandle ReadReady => readEvent;

        HidPort(SafeFileHandle handle, int input, int output)
        {
            Handle = handle; InputLength = input; OutputLength = output;
            readOverlapped = Marshal.AllocHGlobal(OverlappedSize); writeOverlapped = Marshal.AllocHGlobal(OverlappedSize);
            readBuffer = Marshal.AllocHGlobal(Math.Max(input, 1)); writeBuffer = Marshal.AllocHGlobal(Math.Max(output, 1));
        }
        /* Returns null with the Win32 error when the collection cannot be opened for I/O. */
        public static HidPort Open(string path, out int error)
        {
            var h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h.IsInvalid) { error = Marshal.GetLastWin32Error(); h.Dispose(); return null; }
            var info = Info(h);
            if (info == null) { error = Marshal.GetLastWin32Error(); h.Dispose(); return null; }
            error = 0;
            return new HidPort(h, info.InputLength, info.OutputLength);
        }
        void Arm(IntPtr overlapped, ManualResetEvent e)
        {
            for (int i = 0; i < OverlappedSize; i++) Marshal.WriteByte(overlapped, i, 0);
            e.Reset();
            Marshal.WriteIntPtr(overlapped, EventOffset, e.SafeWaitHandle.DangerousGetHandle());
        }
        public bool StartRead()
        {
            if (disposed || reading) return reading;
            Arm(readOverlapped, readEvent);
            if (!ReadFile(Handle, readBuffer, (uint)InputLength, IntPtr.Zero, readOverlapped) && Marshal.GetLastWin32Error() != ERROR_IO_PENDING) return false;
            reading = true; return true;
        }
        /* Call after ReadReady is signaled. Returns the report including the report ID byte. */
        public byte[] FinishRead()
        {
            if (!reading) return null;
            reading = false;
            if (!GetOverlappedResult(Handle, readOverlapped, out uint n, false)) return null;
            var bytes = new byte[n]; Marshal.Copy(readBuffer, bytes, 0, (int)n); return bytes;
        }
        public bool Write(byte[] report, int timeoutMs)
        {
            if (disposed || report.Length != OutputLength) return false;
            Marshal.Copy(report, 0, writeBuffer, report.Length);
            Arm(writeOverlapped, writeEvent);
            if (!WriteFile(Handle, writeBuffer, (uint)report.Length, IntPtr.Zero, writeOverlapped) && Marshal.GetLastWin32Error() != ERROR_IO_PENDING) return false;
            if (!writeEvent.WaitOne(timeoutMs)) { CancelIoEx(Handle, writeOverlapped); GetOverlappedResult(Handle, writeOverlapped, out _, true); return false; }
            return GetOverlappedResult(Handle, writeOverlapped, out uint written, false) && written == report.Length;
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (reading) { CancelIoEx(Handle, readOverlapped); GetOverlappedResult(Handle, readOverlapped, out _, true); reading = false; }
            Handle.Dispose();
            Marshal.FreeHGlobal(readOverlapped); Marshal.FreeHGlobal(writeOverlapped); Marshal.FreeHGlobal(readBuffer); Marshal.FreeHGlobal(writeBuffer);
            readEvent.Dispose(); writeEvent.Dispose();
        }
    }

    // ---- WinUSB (WB32 bootloader bulk pipes) ----
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct USB_INTERFACE_DESCRIPTOR { public byte bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting, bNumEndpoints, bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface; }
    [StructLayout(LayoutKind.Sequential)]
    struct WINUSB_PIPE_INFORMATION { public int PipeType; public byte PipeId; public ushort MaximumPacketSize; public byte Interval; }
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_Initialize(SafeFileHandle h, out IntPtr iface);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_Free(IntPtr iface);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_QueryInterfaceSettings(IntPtr iface, byte alternate, out USB_INTERFACE_DESCRIPTOR descriptor);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_GetAssociatedInterface(IntPtr iface, byte index, out IntPtr associated);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_QueryPipe(IntPtr iface, byte alternate, byte index, out WINUSB_PIPE_INFORMATION pipe);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_SetPipePolicy(IntPtr iface, byte pipe, uint policy, uint length, ref uint value);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_WritePipe(IntPtr iface, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);
    [DllImport("winusb.dll", SetLastError = true)] static extern bool WinUsb_ReadPipe(IntPtr iface, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);

    public sealed class WinUsbDevice : IDisposable
    {
        SafeFileHandle handle; IntPtr iface;
        public byte InputPipe, OutputPipe;
        /* Opens interface 0 only and requires exactly one bulk IN and OUT endpoint 1 with 64-byte packets. */
        public static WinUsbDevice Open(string path, out string problem)
        {
            problem = null;
            var d = new WinUsbDevice { handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero) };
            if (d.handle.IsInvalid) { problem = "busy"; d.Dispose(); return null; }
            if (!WinUsb_Initialize(d.handle, out d.iface)) { d.iface = IntPtr.Zero; problem = "driver"; d.Dispose(); return null; }
            if (!WinUsb_QueryInterfaceSettings(d.iface, 0, out var descriptor) || descriptor.bInterfaceNumber != 0 || WinUsb_GetAssociatedInterface(d.iface, 0, out _)) { problem = "interface"; d.Dispose(); return null; }
            for (byte i = 0; i < descriptor.bNumEndpoints; i++)
            {
                if (!WinUsb_QueryPipe(d.iface, 0, i, out var pipe)) continue;
                if ((pipe.PipeId & 0x0f) != 1 || pipe.PipeType != 2 || pipe.MaximumPacketSize != 64) continue;
                if ((pipe.PipeId & 0x80) != 0) d.InputPipe = pipe.PipeId; else d.OutputPipe = pipe.PipeId;
            }
            if (d.InputPipe == 0 || d.OutputPipe == 0) { problem = "endpoints"; d.Dispose(); return null; }
            uint timeout = 5000;
            WinUsb_SetPipePolicy(d.iface, d.InputPipe, 0x03, 4, ref timeout);
            WinUsb_SetPipePolicy(d.iface, d.OutputPipe, 0x03, 4, ref timeout);
            return d;
        }
        public bool Write(byte[] packet) => WinUsb_WritePipe(iface, OutputPipe, packet, (uint)packet.Length, out uint n, IntPtr.Zero) && n == packet.Length;
        public byte[] Read(int capacity)
        {
            var buffer = new byte[capacity];
            if (!WinUsb_ReadPipe(iface, InputPipe, buffer, (uint)capacity, out uint n, IntPtr.Zero)) return null;
            return buffer.AsSpan(0, (int)n).ToArray();
        }
        public static string LastError() => new Win32Exception(Marshal.GetLastWin32Error()).Message;
        public void Dispose()
        {
            if (iface != IntPtr.Zero) { WinUsb_Free(iface); iface = IntPtr.Zero; }
            handle?.Dispose();
        }
    }
}
