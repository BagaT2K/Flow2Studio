// Port of mac/FlowMacroRecorder.m. The mac local event monitor -> a WH_KEYBOARD_LL hook that is installed
// only while recording and only consumes keys while the Studio window is the foreground window.
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace Flow2Studio;

sealed class FlowMacroRecorder
{
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    const uint LLKHF_EXTENDED = 0x01;
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);

    readonly Action<JsonObject> sink;
    readonly HookProc proc;
    IntPtr hook;
    Form window;
    HashSet<uint> held;

    public FlowMacroRecorder(Action<JsonObject> sink) { this.sink = sink; proc = Callback; }

    /* Set-1 scan code (+extended flag) -> HID keyboard usage, the role FlowMacroKeys.h plays for mac key codes. */
    static uint Usage(uint scan, bool extended, uint vk)
    {
        if (vk == 0x90) return 83;   // Num Lock
        if (vk == 0x13) return 72;   // Pause
        if (extended)
            return scan switch
            {
                0x1c => 88, 0x1d => 228, 0x35 => 84, 0x37 => 70, 0x38 => 230, 0x47 => 74, 0x48 => 82, 0x49 => 75, 0x4b => 80, 0x4d => 79,
                0x4f => 77, 0x50 => 81, 0x51 => 78, 0x52 => 73, 0x53 => 76, 0x5b => 227, 0x5c => 231, 0x5d => 101, _ => 0,
            };
        return scan switch
        {
            0x01 => 41, >= 0x02 and <= 0x0a => 30 + (scan - 0x02), 0x0b => 39, 0x0c => 45, 0x0d => 46, 0x0e => 42, 0x0f => 43,
            0x10 => 20, 0x11 => 26, 0x12 => 8, 0x13 => 21, 0x14 => 23, 0x15 => 28, 0x16 => 24, 0x17 => 12, 0x18 => 18, 0x19 => 19, 0x1a => 47, 0x1b => 48,
            0x1c => 40, 0x1d => 224, 0x1e => 4, 0x1f => 22, 0x20 => 7, 0x21 => 9, 0x22 => 10, 0x23 => 11, 0x24 => 13, 0x25 => 14, 0x26 => 15, 0x27 => 51,
            0x28 => 52, 0x29 => 53, 0x2a => 225, 0x2b => 49, 0x2c => 29, 0x2d => 27, 0x2e => 6, 0x2f => 25, 0x30 => 5, 0x31 => 17, 0x32 => 16, 0x33 => 54,
            0x34 => 55, 0x35 => 56, 0x36 => 229, 0x37 => 85, 0x38 => 226, 0x39 => 44, 0x3a => 57, >= 0x3b and <= 0x44 => 58 + (scan - 0x3b), 0x46 => 71,
            0x47 => 95, 0x48 => 96, 0x49 => 97, 0x4a => 86, 0x4b => 92, 0x4c => 93, 0x4d => 94, 0x4e => 87, 0x4f => 89, 0x50 => 90, 0x51 => 91,
            0x52 => 98, 0x53 => 99, 0x56 => 100, 0x57 => 68, 0x58 => 69, 0x59 => 103, >= 0x64 and <= 0x6b => 104 + (scan - 0x64), _ => 0,
        };
    }
    void Emit(uint code, bool down, uint milliseconds)
    {
        if (down) { if (!held.Add(code)) return; } else if (!held.Remove(code)) return;
        sink(J.O(("macroKey", J.O(("code", code), ("down", down), ("milliseconds", (double)milliseconds)))));
    }
    IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0 || hook == IntPtr.Zero || window == null || GetForegroundWindow() != window.Handle || window.WindowState == FormWindowState.Minimized)
            return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        var e = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        int message = (int)wParam;
        uint usage = Usage(e.scanCode, (e.flags & LLKHF_EXTENDED) != 0, e.vkCode);
        // Unmapped keys are swallowed like the mac monitor; auto-repeat is absorbed by the held set.
        if (usage != 0) Emit(usage, message == WM_KEYDOWN || message == WM_SYSKEYDOWN, e.time);
        return (IntPtr)1;
    }
    void OnWindowChanged(object sender, EventArgs e)
    {
        if (window == null) return;
        if (Form.ActiveForm != window || !window.Visible || window.WindowState == FormWindowState.Minimized) Stop(true, "Запись остановлена: окно Studio потеряло фокус.");
    }
    public bool Start(Form form)
    {
        Stop(false, null);
        if (Form.ActiveForm != form || !form.Visible || form.WindowState == FormWindowState.Minimized) return false;
        held = new HashSet<uint>(); window = form;
        hook = SetWindowsHookExW(WH_KEYBOARD_LL, proc, GetModuleHandleW(null), 0);
        if (hook == IntPtr.Zero) { window = null; return false; }
        form.Deactivate += OnWindowChanged; form.Resize += OnWindowChanged; form.VisibleChanged += OnWindowChanged;
        return true;
    }
    public void Stop(bool notify, string reason)
    {
        bool active = hook != IntPtr.Zero;
        if (active) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        if (window != null) { window.Deactivate -= OnWindowChanged; window.Resize -= OnWindowChanged; window.VisibleChanged -= OnWindowChanged; }
        window = null; held = null;
        if (active && notify) sink(J.O(("macroStopped", J.O(("message", reason ?? "Запись остановлена.")))));
    }
}
