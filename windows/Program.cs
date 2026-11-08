using System.Diagnostics;

namespace Flow2Studio;

static class Program
{
    public static string Version => typeof(Program).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.1.0";
    /* Resources live next to the executable: ui\ (copy of resources/) and firmware\ (copy of firmware-bundle/). */
    public static string ResourcePath(params string[] parts) => Path.Combine(new[] { AppContext.BaseDirectory }.Concat(parts).ToArray());
    public static bool OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); return true; }
        catch { return false; }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool AttachConsole(int process);

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Contains("--self-check"))
        {
            AttachConsole(-1);
            try { return SelfCheck.Run(); }
            catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        }
        // One instance owns the keyboard, like a macOS app; a second launch reopens the window.
        using var mutex = new Mutex(true, @"Local\Flow2Studio.Instance", out bool first);
        using var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Flow2Studio.Reopen");
        if (!first) { reopen.Set(); return 0; }
        ApplicationConfiguration.Initialize();
        var studio = new Studio();
        var listener = new Thread(() => { while (reopen.WaitOne()) studio.Reopen(); }) { IsBackground = true };
        listener.Start();
        Application.Run(studio);
        return 0;
    }
}
