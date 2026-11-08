// Port of mac/Studio.m and mac/FlowWindow.h: the window hosting the web UI, the JS<->native bridge,
// the tray battery menu (NSStatusItem), sleep/wake handling, deferred settings and the editing lease.
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace Flow2Studio;

sealed class Studio : Form
{
    const string Origin = "https://flow2studio.local/";
    /* The web UI talks to window.webkit.messageHandlers.flow; forward it to WebView2 unchanged.
       Input activity is reported because WebView2 keeps keyboard/mouse events out of the host window. */
    const string Shim = """
        (() => {
          if (window.webkit && window.webkit.messageHandlers) return;
          const post = message => window.chrome.webview.postMessage(message);
          Object.defineProperty(window, 'webkit', { value: Object.freeze({ messageHandlers: Object.freeze({ flow: Object.freeze({ postMessage: post }) }) }) });
          const activity = (key, windowAction) => { try { post({ flowActivity: { key, windowAction } }); } catch (e) {} };
          window.addEventListener('keydown', e => activity(true, e.altKey && (e.key === 'F4' || e.key === 'Tab')), true);
          window.addEventListener('mousedown', () => activity(false, false), true);
          window.addEventListener('wheel', () => activity(false, false), { capture: true, passive: true });
        })();
        """;
    static readonly string[] Performed = { "status", "capabilities", "readTouch", "syncTouchProfile", "setTouch", "importTouchProfile", "selectTouchProfile", "touchLive", "lighting", "readLayer", "setKey", "setLayer", "resetLayer", "layerTemplate", "initializeLayers", "profile", "advanced", "wake", "readMacros", "saveMacros", "resetKeys", "resetAll" };
    static readonly string[] FirmwareActions = { "prepareKeyboard", "restoreFirmware", "restoreBackup", "installOEM14", "rollbackOEM14" };

    readonly WebView2 web = new() { Dock = DockStyle.Fill };
    readonly NotifyIcon tray = new();
    readonly ToolStripMenuItem batteryMenu = new() { Enabled = false };
    readonly List<(ToolStripMenuItem item, string source)> menuItems = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 }, editingTimer = new() { Interval = 1000 };
    JsonObject selected, battery, cachedMenuPreviews, firmwareConfirmation;
    byte[] confirmationImage;
    bool sleeping, editingPending, terminating, quitting, editingWanted, editingBlocked, windowClosed, chargeForeground, chargeForcePercent, editingDark, deferredRunning, chargePending, firmwareBusy, wasMinimized, editingKeyBaseline;
    ulong editingGeneration, selectionGeneration;
    double editingActivity, editingLastAttempt, lastDeferredAttempt, lastChargeAttempt;
    uint editingKeyCount, editingTimeout;
    Flow.EditingPresence editingPresence;
    string usbInventory;
    FlowMacroRecorder macroRecorder;
    FlowBLEBattery bleBattery;

    static double Uptime => FlowHID.Uptime;
    static string L(string source) => FlowLocalization.Localized(source);
    /* NSString format with %@ / %d placeholders, applied in order. */
    static string Format(string format, params object[] values)
    {
        foreach (var value in values)
        {
            int at = format.IndexOf("%@", StringComparison.Ordinal), d = format.IndexOf("%d", StringComparison.Ordinal);
            int index = at < 0 ? d : d < 0 ? at : Math.Min(at, d);
            if (index < 0) break;
            format = format[..index] + value + format[(index + 2)..];
        }
        return format;
    }
    void Post(Action action) { if (!IsDisposed && IsHandleCreated) BeginInvoke(action); }
    static bool NonZero(JsonNode id) => J.Double(id) != 0;

    public Studio()
    {
        Text = "Flow 2 Studio";
        ClientSize = new Size(1180, 800);
        MinimumSize = SizeFromClientSize(new Size(1000, 720));
        StartPosition = FormStartPosition.CenterScreen;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        Controls.Add(web);
        editingActivity = Uptime;

        var menu = new ContextMenuStrip();
        menu.Items.Add(batteryMenu); menu.Items.Add(new ToolStripSeparator());
        foreach (var (source, handler) in new (string, Action)[] { ("Открыть Flow 2 Studio", ShowStudio), ("Обновить заряд", RefreshCharge), ("Завершить", Quit) })
        {
            var item = new ToolStripMenuItem(L(source)); item.Click += (_, _) => handler();
            menu.Items.Add(item); menuItems.Add((item, source));
        }
        tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => ShowStudio(); tray.Visible = true;
        RenderStatus();

        timer.Tick += (_, _) => { MonitorConnections(); ProcessDeferred(); };
        editingTimer.Tick += (_, _) => UpdateEditing();
        timer.Start(); editingTimer.Start();
        SystemEvents.PowerModeChanged += OnPower;
        Activated += (_, _) => EditingActivityOccurred();
        Deactivate += (_, _) => UpdateEditing();
        Resize += (_, _) =>
        {
            bool minimized = WindowState == FormWindowState.Minimized;
            if (minimized && !wasMinimized) Reply(0, J.O(("touchLiveWindow", false)), null);
            if (!minimized && wasMinimized) Reply(0, J.O(("touchLiveWindow", true)), null);
            wasMinimized = minimized; UpdateEditing();
        };
        Load += async (_, _) => await StartWeb();
    }

    async Task StartWeb()
    {
        string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Flow2Studio", "WebView2");
        var environment = await CoreWebView2Environment.CreateAsync(null, data);
        await web.EnsureCoreWebView2Async(environment);
        var core = web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultScriptDialogsEnabled = false;
        core.SetVirtualHostNameToFolderMapping("flow2studio.local", Program.ResourcePath("ui"), CoreWebView2HostResourceAccessKind.Deny);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(Shim);
        core.WebMessageReceived += OnMessage;
        // Only the bundled UI may load; external links go through openExternal/openUpdate.
        core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith(Origin, StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.ScriptDialogOpening += OnScriptDialog;
        Appearance();
        core.Navigate(Origin + "index.html");
        Reply(0, J.O(("touchLiveWindow", true)), null);
    }

    JsonObject Preferences()
    {
        string style = FlowPreferences.String("batteryStyle"); if (style is not ("keyboardPercent" or "logo")) style = "keyboardPercent";
        return J.O(("language", FlowLocalization.CurrentLanguage()), ("theme", FlowPreferences.String("theme") ?? "dark"), ("batteryStyle", style), ("autoCharge", FlowPreferences.Bool("autoCharge")),
            ("editingConnection", FlowPreferences.Bool("editingConnection")), ("keycaps", (JsonNode)FlowPreferences.Dictionary("keycaps") ?? new JsonObject()), ("menuPreviews", MenuPreviews()));
    }
    void Appearance()
    {
        bool light = J.Str(Preferences()["theme"]) == "light";
        var background = light ? Color.FromArgb(243, 243, 236) : Color.FromArgb(16, 18, 18);
        BackColor = background; web.DefaultBackgroundColor = background;
        int dark = light ? 0 : 1;
        if (IsHandleCreated) Native.DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Appearance(); }

    public void Reopen() => Post(ShowStudio);
    void ShowStudio()
    {
        windowClosed = false; Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate(); Reply(0, J.O(("touchLiveWindow", true)), null);
    }
    bool WindowShouldClose()
    {
        if (firmwareBusy) { Reply(0, J.O(("preparation", J.O(("phase", "busy"), ("done", 0), ("total", 1)))), null); return false; }
        if (firmwareConfirmation != null && Uptime < J.Double(firmwareConfirmation["deadline"])) return false;
        firmwareConfirmation = null; return true;
    }
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (quitting) { base.OnFormClosing(e); return; }
        e.Cancel = true;
        // Closing the window keeps the tray app alive and the same window can reopen.
        if (e.CloseReason == CloseReason.UserClosing)
        {
            if (!WindowShouldClose()) return;
            Hide(); windowClosed = true; chargeForeground = false; Reply(0, J.O(("touchLiveWindow", false)), null); StopEditing();
        }
        else Quit();
    }
    void Quit()
    {
        if (firmwareBusy) { ShowStudio(); Reply(0, J.O(("preparation", J.O(("phase", "busy"), ("done", 0), ("total", 1)))), null); return; }
        if (terminating) return;
        terminating = true; selectionGeneration++;
        timer.Stop(); editingTimer.Stop();
        macroRecorder?.Stop(false, null); bleBattery?.Cancel();
        firmwareConfirmation = null;
        StopEditing();
        // The worker barrier completes after all pending HID operations and lease release.
        FlowHID.Enqueue(() => Post(() => { quitting = true; tray.Visible = false; SystemEvents.PowerModeChanged -= OnPower; Application.Exit(); }));
    }
    void OnPower(object sender, PowerModeChangedEventArgs e) => Post(() =>
    {
        if (e.Mode == PowerModes.Suspend)
        {
            sleeping = true; Reply(0, J.O(("touchLiveWindow", false)), null); chargeForeground = false;
            macroRecorder?.Stop(true, "Recording stopped: the computer is going to sleep.");
            StopEditing(); selectionGeneration++; bleBattery?.Cancel(); FlowBLESerial.Reset(); battery = null; RenderStatus();
        }
        else if (e.Mode == PowerModes.Resume)
        {
            sleeping = false;
            if (Visible && !windowClosed && WindowState != FormWindowState.Minimized) Reply(0, J.O(("touchLiveWindow", true)), null);
            EditingActivityOccurred();
        }
    });

    bool Foreground() => Flow.WindowForeground(ActiveForm == this, ActiveForm == this, Visible, WindowState == FormWindowState.Minimized);
    void StopEditing()
    {
        editingPresence = default;
        editingWanted = false; editingBlocked = false; editingTimeout = 0; editingLastAttempt = 0; editingGeneration++;
        editingKeyBaseline = false;
        FlowHID.Enqueue(() => { FlowTransport.TouchLiveEnd(); FlowTransport.EditingEnd(); });
    }
    void EditingActivityOccurred()
    {
        editingActivity = Uptime;
        // A failed/unsupported session is retried only on explicit settings requests
        // or on a new window session, never on every mouse event.
        UpdateEditing(); ProcessDeferred();
    }
    void UpdateEditing()
    {
        if (terminating) return;
        double now = Uptime;
        bool foreground = !sleeping && !terminating && Foreground();
        bool activated = foreground && !chargeForeground, departed = !foreground && chargeForeground; chargeForeground = foreground;
        if (activated)
        {
            editingBlocked = false;
            if (selected != null && !firmwareBusy) ReadCharge(selected, 0, true);
        }
        bool rf = J.Str(selected?["connection"]) == "2.4 ГГц";
        bool wanted = Flow.EditingPresenceTick(ref editingPresence, now, J.Bool(Preferences()["editingConnection"]), foreground, !windowClosed, sleeping, firmwareBusy || terminating, rf);
        if (!wanted) { if (editingWanted) StopEditing(); return; }
        editingWanted = true;
        // Typing in another app is activity too. Only the aggregate last-input time is read:
        // no global hook, key codes, characters or typing history are collected.
        double idle = Native.KeyboardIdleSeconds(out uint lastInput);
        bool keyChanged = editingKeyBaseline && lastInput != editingKeyCount;
        editingKeyCount = lastInput; editingKeyBaseline = true;
        editingActivity = Flow.EditingKeyboardActivity(now, editingActivity, keyChanged, departed, keyChanged ? idle : 0);
        if (editingPending || editingBlocked) return;
        bool dark = Flow.EditingDark(now, editingActivity, editingTimeout);
        if (editingLastAttempt > 0 && now - editingLastAttempt < 4 && dark == editingDark) return;
        editingDark = dark; editingLastAttempt = now;
        editingPending = true; ulong generation = editingGeneration;
        var device = selected; double idleSeconds = Math.Max(0, now - editingActivity);
        FlowHID.Enqueue(() =>
        {
            var error = new ErrorSlot(); var result = FlowTransport.EditingTick(device, idleSeconds, error);
            Post(() =>
            {
                editingPending = false;
                if (generation != editingGeneration) { UpdateEditing(); return; }
                if (result?["timeout"] != null) { editingTimeout = J.UInt(result["timeout"]); editingDark = J.Bool(result["dark"]); }
                editingBlocked = result == null || J.Contains(new[] { "upgrade", "unsupported" }, result["state"]);
            });
        });
    }

    void Reply(JsonNode identifier, JsonNode value, string error)
    {
        var payload = new JsonObject { ["id"] = identifier?.DeepClone() ?? 0, ["result"] = value?.DeepClone(), ["error"] = error };
        _ = web.CoreWebView2?.ExecuteScriptAsync($"window.flowReceive({payload.ToJsonString()})");
    }
    void LogBattery()
    {
        if (!J.Bool(battery?["valid"])) return;
        try
        {
            Directory.CreateDirectory(FlowPreferences.Root);
            string path = Path.Combine(FlowPreferences.Root, "history.csv"); bool exists = File.Exists(path);
            string power = battery["power"] != null ? (J.Bool(battery["power"]) ? "1" : "0") : "";
            string id = J.Str(selected?["id"]) ?? selected?["id"]?.ToJsonString() ?? "";
            File.AppendAllText(path, (exists ? "" : "response_time,connection_id,percent,power\n") + $"{DateTime.UtcNow:yyyy-MM-dd'T'HH:mm:ss'Z'},{id},{J.Int(battery["percent"])},{power}\n");
        }
        catch { }
    }

    /* The status-bar glyph from Studio.m, drawn in mac coordinates (origin bottom-left, 20 pt high). */
    Bitmap MenuImage(string style, float scale, Color color)
    {
        bool logo = style == "logo", power = J.Bool(battery?["power"]);
        float width = logo ? 21 : 27;
        var image = new Bitmap((int)Math.Ceiling((width + (power ? 28 : 0)) * scale), (int)(20 * scale));
        using var g = Graphics.FromImage(image);
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.ScaleTransform(scale, scale);
        using var pen = new Pen(color, 1.25f) { LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(color);
        RectangleF Flip(float x, float y, float w, float h) => new(x, 20 - y - h, w, h);
        if (logo)
        {
            using var font = new Font("Segoe UI Semibold", 17f, FontStyle.Italic | FontStyle.Bold, GraphicsUnit.Pixel);
            var size = g.MeasureString("f.", font);
            g.DrawString("f.", font, brush, 0, (20 - size.Height) / 2);
        }
        else
        {
            g.DrawPath(pen, Rounded(Flip(1, 3.5f, 25, 13), 2.2f));
            for (int row = 0; row < 2; row++) for (int col = 0; col < 6; col++) g.FillRectangle(brush, Flip(4 + col * 3.3f, 11.5f - row * 3, 1.8f, 1.3f));
            g.FillPath(brush, Rounded(Flip(7, 6, 13, 1.4f), 0.6f));
        }
        if (power)
        {
            float x = width + 5;
            PointF P(float px, float py) => new(px, 20 - py);
            g.DrawPolygon(pen, new[] { P(x + 10, 18), P(x + 2, 8), P(x + 8, 8), P(x + 6, 2), P(x + 16, 12), P(x + 10, 12) });
        }
        return image;
    }
    static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath(); float d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure(); return path;
    }
    JsonObject MenuPreviews()
    {
        if (cachedMenuPreviews != null) return cachedMenuPreviews;
        var assets = new JsonObject();
        foreach (var style in new[] { "keyboardPercent", "logo" })
        {
            using var image = MenuImage(style, 2, Color.Black); using var png = new MemoryStream();
            image.Save(png, ImageFormat.Png);
            assets[style] = "data:image/png;base64," + Convert.ToBase64String(png.ToArray());
        }
        return cachedMenuPreviews = assets;
    }
    /* A tray icon cannot carry the " 38%" title, so the percentage is drawn into the icon itself. */
    Icon TrayIcon(string style, int percent, bool valid)
    {
        bool lightTaskbar = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0) is int v && v == 1;
        var color = lightTaskbar ? Color.Black : Color.White;
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            if (style != "logo" && valid)
            {
                using var font = new Font("Segoe UI", percent >= 100 ? 15f : 20f, FontStyle.Bold, GraphicsUnit.Pixel);
                using var brush = new SolidBrush(color);
                var size = g.MeasureString(percent.ToString(), font);
                g.DrawString(percent.ToString(), font, brush, (32 - size.Width) / 2, (32 - size.Height) / 2);
            }
            else
            {
                using var glyph = MenuImage(style, style == "logo" ? 1.5f : 1.15f, color);
                g.DrawImage(glyph, (32 - glyph.Width) / 2f, (32 - glyph.Height) / 2f, glyph.Width, glyph.Height);
            }
        }
        IntPtr handle = bitmap.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        return icon;
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
    void RenderStatus()
    {
        foreach (var (item, source) in menuItems) item.Text = L(source);
        bool valid = J.Bool(battery?["valid"]); int percent = J.Int(battery?["percent"]);
        string style = J.Str(Preferences()["batteryStyle"]);
        string name = selected != null ? Format(L("Клавиатура Lofree Flow 2 %@"), J.Str(selected["model"]) ?? "") : "Flow 2 Studio";
        string text = valid ? $"{name} · {percent}% · {L(J.Str(selected?["connection"]) ?? "")}" : name + L(" · заряд недоступен");
        if (J.Bool(battery?["power"])) text += J.Bool(battery["full"]) ? L(" · Питание подключено, заряд полный") : L(" · Заряжается");
        var previous = tray.Icon;
        tray.Icon = TrayIcon(style, percent, valid); previous?.Dispose();
        tray.Text = text.Length > 127 ? text[..127] : text;
        batteryMenu.Text = text;
    }

    void ReadCharge(JsonObject device, JsonNode identifier, bool forcePercent = false)
    {
        if (terminating) return;
        if (firmwareBusy) { if (NonZero(identifier)) Reply(identifier, null, L("Идёт подготовка клавиатуры.")); return; }
        chargeForcePercent = chargeForcePercent || forcePercent;
        if (chargePending) { if (NonZero(identifier)) Reply(identifier, battery ?? J.O(("pending", true)), null); return; }
        chargePending = true; lastChargeAttempt = Uptime;
        ulong generation = selectionGeneration;
        void Complete(JsonObject value, string error)
        {
            bool forced = chargeForcePercent; chargeForcePercent = false; chargePending = false;
            if (terminating) return;
            if (generation != selectionGeneration || sleeping || !J.Same(selected?["id"], device["id"]))
            {
                if (NonZero(identifier)) Reply(identifier, null, L("Выбранное устройство изменилось."));
                if (forced && selected != null && !sleeping && !firmwareBusy) ReadCharge(selected, 0, true);
                return;
            }
            var display = value;
            if (value != null && !forced && !NonZero(identifier) && !J.Bool(Preferences()["autoCharge"]) && battery != null)
            {
                display = (JsonObject)value.DeepClone(); display["percent"] = J.Own(battery["percent"]) ?? 0; display["valid"] = J.Own(battery["valid"]) ?? false;
            }
            battery = display; RenderStatus(); LogBattery();
            Reply(identifier, NonZero(identifier) ? display : J.O(("battery", display)), error);
        }
        bool bluetooth = J.Str(device["connection"]) == "Bluetooth";
        if (bluetooth && !J.Bool(device["vendor"])) { (bleBattery ??= new FlowBLEBattery()).ReadDevice(device, Complete); return; }
        FlowHID.Enqueue(() =>
        {
            var error = new ErrorSlot(); var value = FlowTransport.Perform(device, "status", new JsonObject(), error);
            Post(() =>
            {
                if (terminating) { chargePending = false; chargeForcePercent = false; return; }
                if (value == null && bluetooth) (bleBattery ??= new FlowBLEBattery()).ReadDevice(device, Complete);
                else Complete(value, error.Value?.Message);
            });
        });
    }
    void OnScriptDialog(object sender, CoreWebView2ScriptDialogOpeningEventArgs e)
    {
        // Like the mac WKUIDelegate: only confirm() gets a native panel; alert/prompt are ignored.
        if (e.Kind != CoreWebView2ScriptDialogKind.Confirm) return;
        var deferral = e.GetDeferral();
        string message = e.Message;
        BeginInvoke(() =>
        {
            if (Choose(L(message), null, L("Продолжить"), L("Отмена")) == 0) e.Accept();
            deferral.Complete();
        });
    }
    int Choose(string message, string details, params string[] buttons)
    {
        var page = new TaskDialogPage { Caption = "Flow 2 Studio", Heading = message, Text = details, AllowCancel = true };
        var choices = buttons.Select(b => new TaskDialogButton(b)).ToList();
        foreach (var b in choices) page.Buttons.Add(b);
        var result = TaskDialog.ShowDialog(this, page);
        return choices.IndexOf(result);
    }
    void RefreshCharge()
    {
        if (selected == null || sleeping || firmwareBusy || terminating) return;
        ReadCharge(selected, 0);
    }
    void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!e.Source.StartsWith(Origin, StringComparison.OrdinalIgnoreCase)) return;
        JsonObject body; try { body = JsonNode.Parse(e.WebMessageAsJson) as JsonObject; } catch (JsonException) { return; }
        if (body == null) return;
        // Handle after the WebView2 event returns: dialogs below run nested message loops.
        BeginInvoke(() => Receive(body));
    }
    void StopRecording(string reason) => macroRecorder?.Stop(true, L(reason));
    void Receive(JsonObject body)
    {
        if (body["flowActivity"] is JsonObject activity) { if (!J.Bool(activity["windowAction"])) EditingActivityOccurred(); return; }
        var identifier = body["id"]; string action = J.Str(body["action"]);
        if (!J.IsNumber(identifier) || action == null || terminating) return;
        var args = body["args"] as JsonObject ?? new JsonObject();
        if (action == "checkUpdates") { FlowUpdates.Check(J.Bool(args["force"]), (result, error) => Reply(identifier, result, error != null ? L(error) : null)); return; }
        if (action == "openUpdate") { bool opened = !firmwareBusy && FlowUpdates.OpenUpdate(); Reply(identifier, opened ? J.O(("opened", true)) : null, opened ? null : L("Не удалось открыть ссылку в браузере.")); return; }
        if (action == "openExternal")
        {
            var links = new Dictionary<string, string> { ["github"] = "https://github.com/BagaT2K/Flow2Studio", ["kofi"] = "https://ko-fi.com/bagat2k/tip" };
            string key = J.Str(args["link"]);
            bool opened = key != null && links.TryGetValue(key, out var destination) && Program.OpenUrl(destination);
            Reply(identifier, opened ? J.O(("opened", true)) : null, opened ? null : L("Не удалось открыть ссылку в браузере.")); return;
        }
        if (action == "openFirmwareBackups")
        {
            try { Directory.CreateDirectory(FlowFirmware.BackupRoot); System.Diagnostics.Process.Start("explorer.exe", $"\"{FlowFirmware.BackupRoot}\""); } catch { }
            Reply(identifier, J.O(("opened", true)), null); return;
        }
        if (action == "startMacroRecording")
        {
            if (firmwareBusy) { Reply(identifier, null, L("Дождитесь завершения подготовки.")); return; }
            macroRecorder ??= new FlowMacroRecorder(e => { if (J.Bool(e["macroKey"]?["down"])) EditingActivityOccurred(); Reply(0, e, null); });
            bool started = macroRecorder.Start(this);
            Reply(identifier, started ? J.O(("recording", true), ("source", "native")) : null, started ? null : L("Откройте окно Studio, чтобы записать макрос.")); return;
        }
        if (action == "stopMacroRecording") { macroRecorder?.Stop(false, null); Reply(identifier, J.O(("recording", false)), null); return; }
        if (action == "preferences") { Reply(identifier, Preferences(), null); return; }
        if (action == "savePreferences")
        {
            if (FlowLocalization.LanguageSupported(J.Str(args["language"]))) FlowPreferences.Set("language", J.Str(args["language"]));
            if (J.Contains(new[] { "dark", "light" }, args["theme"])) FlowPreferences.Set("theme", J.Str(args["theme"]));
            if (J.Contains(new[] { "keyboardPercent", "logo" }, args["batteryStyle"])) FlowPreferences.Set("batteryStyle", J.Str(args["batteryStyle"]));
            if (J.IsNumber(args["editingConnection"])) { FlowPreferences.Set("editingConnection", J.Bool(args["editingConnection"])); StopEditing(); UpdateEditing(); }
            if (J.IsNumber(args["autoCharge"])) FlowPreferences.Set("autoCharge", J.Bool(args["autoCharge"]));
            if (selected != null && J.Contains(new[] { "white", "black" }, args["keycaps"]))
            {
                var caps = FlowPreferences.Dictionary("keycaps") ?? new JsonObject(); caps[J.Str(selected["key"]) ?? ""] = J.Str(args["keycaps"]); FlowPreferences.Set("keycaps", caps);
            }
            Appearance(); RenderStatus(); Reply(identifier, Preferences(), null); return;
        }
        if (action == "cancelFirmwareConfirmation") { firmwareConfirmation = null; confirmationImage = null; Reply(identifier, J.O(("cancelled", true)), null); return; }
        if (firmwareBusy)
        {
            if (action == "scan") Reply(identifier, J.O(("devices", selected != null ? J.A(new object[] { selected }) : new JsonArray())), null);
            else Reply(identifier, null, L("Дождитесь завершения подготовки клавиатуры."));
            return;
        }
        if (action == "scan")
        {
            var devices = FlowTransport.Devices(); foreach (var d in FlowFirmware.Devices()) devices.Add(J.Own(d));
            if (selected != null && !devices.Any(d => J.Same(d?["id"], selected["id"])))
            {
                StopRecording("Запись остановлена: устройство отключено."); selectionGeneration++; bleBattery?.Cancel(); FlowBLESerial.Reset(); selected = null; StopEditing(); battery = null; RenderStatus();
            }
            Reply(identifier, J.O(("devices", devices)), null); return;
        }
        JsonObject device = null;
        var allDevices = FlowTransport.Devices(); foreach (var d in FlowFirmware.Devices()) allDevices.Add(J.Own(d));
        foreach (var d in allDevices.OfType<JsonObject>()) if (J.Same(d["id"], body["device"])) { device = (JsonObject)d.DeepClone(); break; }
        if (device == null) { Reply(identifier, null, L("Устройство отключено")); return; }
        string deviceKey = J.Str(device["key"]);
        if (action == "preparationStatus") { Reply(identifier, FlowFirmware.Status(device), null); return; }
        if (FirmwareActions.Contains(action)) { Firmware(identifier, action, args, device); return; }
        if (action == "cachedState")
        {
            var caps = FlowPreferences.Dictionary("verifiedCapabilities.v1")?[deviceKey ?? ""] as JsonObject;
            if (caps != null && !J.Bool(caps["profile"]?["zoneAnimationsSupported"]) && J.UInt(caps["effect"]) > 1) { caps["effect"] = 1; caps["waveSpeed"] = 1; caps["effectFamily"] = "zones-v1"; }
            Reply(identifier, J.O(("caps", caps), ("jobs", FlowDeferredStore.Jobs(deviceKey))), null); return;
        }
        if (action == "clearDeferred") { FlowDeferredStore.Clear(deviceKey); PublishDeferred(); Reply(identifier, J.O(("cleared", true)), null); return; }
        if (action == "initializeLayers" && (FlowPreferences.Array("initializedLayers.v1")?.Any(k => J.Same(k, device["key"])) ?? false)) { Reply(identifier, J.O(("initialized", true), ("changedLayers", new JsonArray())), null); return; }
        if (action == "select")
        {
            StopRecording("Запись остановлена: выбрано устройство."); StopEditing(); selectionGeneration++; bleBattery?.Cancel(); firmwareConfirmation = null; confirmationImage = null;
            selected = device; EditingActivityOccurred(); battery = null; RenderStatus(); Reply(identifier, selected, null); return;
        }
        if (!Performed.Contains(action)) { Reply(identifier, null, L("Действие недоступно")); return; }
        if (action == "status")
        {
            if (sleeping) { Reply(identifier, null, L("The computer is going to sleep.")); return; }
            ReadCharge(device, identifier); return;
        }
        if (action == "resetLayer" && Choose(Format(L("Вернуть заводские назначения слоя %d?"), J.Int(args["layer"]) + 1), L("Изменится только выбранный слой. Остальные слои сохранятся. Изменение можно отменить в истории текущей сессии."), L("Отмена"), L("Сбросить слой")) != 1)
        { Reply(identifier, J.O(("cancelled", true)), null); return; }
        if (action is "resetKeys" or "resetAll")
        {
            bool all = action == "resetAll";
            string message = all ? L("Сбросить настройки клавиатуры?") : L("Восстановить заводские назначения?");
            string details = all ? L("Будут сброшены назначения всех 6 слоёв, макросы, яркость, эффект и поддерживаемый профиль индикатора/таймера. Сопряжения Bluetooth, прошивка и патч панели сохранятся. Перед записью приложение сохранит резервные копии.")
                : L("Будут восстановлены заводские назначения всех 6 слоёв. Макросы и подсветка сохранятся. Перед записью приложение сохранит резервную копию.");
            if (Choose(message, details, L("Отмена"), L("Сбросить")) != 1) { Reply(identifier, J.O(("cancelled", true)), null); return; }
        }
        if (FlowDeferredStore.Accepts(action) && FlowDeferredStore.Jobs(deviceKey).Count > 0)
        {
            FlowDeferredStore.Enqueue(action, args, deviceKey);
            var queued = (JsonObject)args.DeepClone(); queued["queued"] = true; Reply(identifier, queued, null); PublishDeferred(); ProcessDeferred(); return;
        }
        if (action == "touchLive") { TouchLive(identifier, args, device); return; }
        if (action != "syncTouchProfile") { editingActivity = Uptime; editingBlocked = false; UpdateEditing(); }
        var requestArgs = args;
        FlowHID.Enqueue(() =>
        {
            var error = new ErrorSlot(); var result = FlowTransport.Perform(device, action, requestArgs, error);
            Post(() =>
            {
                if (result == null && error.Value is { Domain: "Flow2Studio", Code: 2 } && FlowDeferredStore.Accepts(action))
                {
                    FlowDeferredStore.Enqueue(action, requestArgs, deviceKey); var queued = (JsonObject)requestArgs.DeepClone(); queued["queued"] = true;
                    Reply(identifier, queued, null); PublishDeferred(); return;
                }
                if (result != null)
                {
                    if (action == "initializeLayers")
                    {
                        var done = FlowPreferences.Array("initializedLayers.v1") ?? new JsonArray();
                        if (!done.Any(k => J.Same(k, device["key"]))) done.Add(J.Own(device["key"]));
                        FlowPreferences.Set("initializedLayers.v1", done);
                    }
                    if (action == "resetLayer" && !J.Bool(result["cancelled"]))
                    {
                        foreach (var job in FlowDeferredStore.Jobs(deviceKey).OfType<JsonObject>())
                            if (J.Contains(new[] { "setKey", "setLayer" }, job["action"]) && J.Same(job["args"]?["layer"], requestArgs["layer"])) FlowDeferredStore.Complete(J.Str(job["id"]), deviceKey);
                        PublishDeferred();
                    }
                    CacheResult(result, action, device);
                    if (action is "resetAll" or "resetKeys" && !J.Bool(result["cancelled"]))
                    {
                        if (action == "resetAll") FlowDeferredStore.Clear(deviceKey);
                        else foreach (var job in FlowDeferredStore.Jobs(deviceKey).OfType<JsonObject>()) if (J.Contains(new[] { "setKey", "setLayer" }, job["action"])) FlowDeferredStore.Complete(J.Str(job["id"]), deviceKey);
                        PublishDeferred();
                    }
                }
                var profile = action is "profile" or "advanced" ? result : result?["profile"] as JsonObject;
                if (J.Same(selected?["id"], device["id"]) && profile?["timeout"] != null) { editingTimeout = J.UInt(profile["timeout"]); UpdateEditing(); }
                Reply(identifier, result, error.Value?.Message);
            });
        });
    }
    void TouchLive(JsonNode identifier, JsonObject args, JsonObject device)
    {
        bool enable = J.IsYes(args["enabled"]);
        if (enable && (sleeping || terminating || windowClosed || WindowState == FormWindowState.Minimized || firmwareBusy)) { Reply(identifier, null, L("Действие недоступно")); return; }
        ulong generation = selectionGeneration;
        FlowHID.Enqueue(() =>
        {
            var error = new ErrorSlot(); bool enabled = false;
            if (enable)
                enabled = FlowTransport.TouchLiveStart(device, position => Post(() =>
                {
                    if (generation == selectionGeneration && !sleeping && !windowClosed && WindowState != FormWindowState.Minimized)
                        Reply(0, J.O(("touchLivePoint", position), ("device", device["id"])), null);
                }), error);
            bool ok = enable ? enabled : FlowTransport.TouchTestStop(error);
            Post(() => Reply(identifier, ok ? J.O(("enabled", enabled)) : null, ok ? null : (error.Value?.Message ?? L("Действие недоступно"))));
        });
    }
    void Firmware(JsonNode identifier, string action, JsonObject args, JsonObject device)
    {
        StopRecording("Запись остановлена перед подготовкой клавиатуры.");
        uint restoreMode = action == "restoreFirmware" ? 1u : action == "restoreBackup" ? 2u : action == "installOEM14" ? 3u : action == "rollbackOEM14" ? 4u : 0u; bool restore = restoreMode != 0;
        var status = FlowFirmware.Status(device);
        if (!J.Bool(status["available"]) || (!restore && !J.Bool(status["canPrepare"])) || (restore && (!(restoreMode == 1 ? J.Bool(status["canRestoreFactory"]) : J.Bool(status["canRestore"])) || (!J.Bool(status["wired"]) && !J.Bool(status["recovery"])))))
        { Reply(identifier, null, J.Str(status["message"]) ?? L("Подключите клавиатуру кабелем для подготовки.")); return; }
        string consentToken = J.Str(args["confirmationToken"]);
        var proposal = firmwareConfirmation;
        if (consentToken != null && !FlowFlashCore.ConsentValid(Uptime, J.Double(proposal?["deadline"]), selectionGeneration, (ulong)J.Double(proposal?["generation"]), J.Str(proposal?["token"]) == consentToken,
            J.Str(proposal?["action"]) == action && J.Same(proposal?["device"], device["id"])))
        { firmwareConfirmation = null; confirmationImage = null; Reply(identifier, null, L("Подтверждение устарело или устройство изменилось. Откройте окно обновления заново. Запись не начата.")); return; }
        JsonObject chosenBackup = restoreMode == 2 && consentToken != null ? proposal["backup"] as JsonObject : null;
        byte[] chosenImage = restoreMode == 2 && consentToken != null ? confirmationImage : null;
        if (restoreMode == 2 && consentToken == null)
        {
            Directory.CreateDirectory(FlowFirmware.BackupRoot);
            using var panel = new OpenFileDialog { Title = L("Выберите резервную копию прошивки"), Filter = "Firmware image (*.bin)|*.bin|All files (*.*)|*.*", Multiselect = false, InitialDirectory = FlowFirmware.BackupRoot, CheckFileExists = true };
            if (panel.ShowDialog(this) != DialogResult.OK) { Reply(identifier, J.O(("cancelled", true)), null); return; }
            var backupError = new ErrorSlot(); chosenBackup = FlowFirmware.ReadBackup(panel.FileName, out chosenImage, backupError);
            if (chosenBackup == null) { Reply(identifier, null, backupError.Value?.Message); return; }
        }
        if (!FlowFlashCore.BackupSelectionValid(restoreMode, J.Bool(device["bootloader"]), (uint)J.Int(chosenBackup?["model"]), (uint)J.Int(device["model"]), chosenImage?.Length == FlowFlashCore.FlashSize))
        { firmwareConfirmation = null; confirmationImage = null; Reply(identifier, null, L("Резервная копия относится к другой модели клавиатуры. Запись не начата.")); return; }
        if (consentToken == null)
        {
            string title = restoreMode == 3 ? L("Установить заводскую Lofree 0.14?") : restoreMode == 4 ? L("Вернуть прошивку до обновления?") : restoreMode == 1 ? L("Установить заводскую прошивку?") : restoreMode == 2 ? L("Восстановить из копии?") : L("Подготовить клавиатуру?");
            string model = J.Str(chosenBackup?["model"]) ?? J.Str(status["model"]) ?? J.Str(device["model"]) ?? "";
            string installDetails = L("Flow 2 %@ → Studio 0.9 на официальной базе Lofree 0.14.\n\nПри ошибке записи Studio попытается вернуть прежний образ. Сохранённую копию можно выбрать вручную. Оставьте USB подключённым и закройте VIA.").Replace("Studio 0.9", "Studio 0.10");
            string details = restoreMode == 0 ? Format(installDetails, model)
                : restoreMode == 1 ? Format(L("Будет установлена заводская Lofree 0.14 для Flow 2 %@ без расширений Studio. Текущая прошивка будет сохранена и проверена. Не отключайте USB."), model)
                : restoreMode == 2 ? Format(L("Файл: %@\nПрошивка: %@\nМодель: Flow 2 %@\n\nТекущий образ будет сохранён перед восстановлением. Не отключайте USB."), J.Str(chosenBackup["file"]), L(J.Str(chosenBackup["label"])), model)
                : L("Будет восстановлена проверенная прошивка, сохранённая перед обновлением. Используйте тот же USB-порт. Для другого порта выберите before.bin вручную. Не отключайте USB.");
            string token = Guid.NewGuid().ToString().ToUpperInvariant();
            firmwareConfirmation = J.O(("token", token), ("action", action), ("device", device["id"]), ("generation", selectionGeneration), ("deadline", Uptime + 120), ("backup", (JsonNode)chosenBackup ?? new JsonObject()));
            confirmationImage = chosenImage;
            string warning = L("Обновление выполняется на ваш страх и риск. При ошибке Studio попытается восстановить прежнюю прошивку из проверенной копии. При отключении питания, потере USB или неисправности устройства откат может потребовать отдельного восстановления и не гарантируется.");
            Reply(identifier, J.O(("confirmation", J.O(("token", token), ("title", title), ("details", details), ("warning", warning), ("model", J.Str(device["model"]) ?? ""),
                ("confirmLabel", restoreMode == 3 ? L("Установить 0.14") : restore ? L("Восстановить") : L("Обновить прошивку"))))), null);
            return;
        }
        firmwareConfirmation = null; confirmationImage = null; // Single use, bound to action/device/selection generation.
        // A cached extension belongs to the pre-flash firmware. Invalidate it
        // after confirmation, including interrupted operations, before reconnect.
        string deviceKey = J.Str(device["key"]);
        if (deviceKey != null) { var verified = FlowPreferences.Dictionary("verifiedCapabilities.v1") ?? new JsonObject(); verified.Remove(deviceKey); FlowPreferences.Set("verifiedCapabilities.v1", verified); }
        firmwareBusy = true; StopEditing(); selectionGeneration++; bleBattery?.Cancel(); FlowBLESerial.Reset(); battery = null; RenderStatus();
        FlowHID.Enqueue(() =>
        {
            const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x00000001;
            var error = new ErrorSlot(); JsonObject result = null;
            if (Native.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) != 0)
            {
                result = FlowFirmware.Prepare(device, restoreMode, chosenImage, step => Post(() => Reply(0, J.O(("preparation", step)), null)), error);
                Native.SetThreadExecutionState(ES_CONTINUOUS);
            }
            else error.Value = new FlowError("Flow2Firmware", 1, "Could not keep the computer awake. Preparation not started.");
            Post(() =>
            {
                firmwareBusy = false; if (result != null && !J.Bool(result["cancelled"])) FlowDeferredStore.Clear(deviceKey);
                selected = null; Reply(identifier, result, error.Value?.Message);
            });
        });
    }
    void CacheResult(JsonObject result, string action, JsonObject device)
    {
        string key = J.Str(device["key"]); if (key == null) return;
        var all = FlowPreferences.Dictionary("verifiedCapabilities.v1") ?? new JsonObject();
        var caps = all[key]?.DeepClone() as JsonObject;
        if (action == "capabilities" && J.Bool(result["profileSupported"])) caps = (JsonObject)result.DeepClone();
        else if (caps != null)
        {
            if (action is "profile" or "advanced") caps["profile"] = result.DeepClone();
            else if (action == "lighting") foreach (var (k, v) in result) caps[k] = v?.DeepClone();
        }
        if (caps != null) { all[key] = caps; FlowPreferences.Set("verifiedCapabilities.v1", all); }
    }
    void PublishDeferred()
    {
        string key = J.Str(selected?["key"]); if (key == null) return;
        var jobs = FlowDeferredStore.Jobs(key); bool paused = jobs.Count > 0; foreach (var job in jobs) if (job?["error"] == null) paused = false;
        Reply(0, J.O(("deferred", J.O(("device", selected["id"]), ("count", jobs.Count), ("paused", paused)))), null);
    }
    void ProcessDeferred()
    {
        if (deferredRunning || firmwareBusy || sleeping || terminating || selected == null) return;
        var device = selected; string key = J.Str(device["key"]); var jobs = FlowDeferredStore.Jobs(key); if (jobs.Count == 0) return;
        var job = jobs.OfType<JsonObject>().FirstOrDefault(j => j["error"] == null); if (job == null) return;
        double now = Uptime; if (now - lastDeferredAttempt < 4) return; lastDeferredAttempt = now; deferredRunning = true;
        string jobAction = J.Str(job["action"]); var jobArgs = job["args"] as JsonObject ?? new JsonObject();
        FlowHID.Enqueue(() =>
        {
            var error = new ErrorSlot();
            // Poll only a nonce status read while waiting; start the bounded editing operation
            // only after the keyboard answers, including when Studio is minimized.
            var online = FlowTransport.Perform(device, "status", new JsonObject(), error); bool waiting = online == null;
            JsonObject result = null; if (!waiting) { error = new ErrorSlot(); result = FlowTransport.Perform(device, jobAction, jobArgs, error); }
            Post(() =>
            {
                deferredRunning = false;
                if (result != null)
                {
                    FlowDeferredStore.Complete(J.Str(job["id"]), key); CacheResult(result, jobAction, device);
                    if (J.Same(selected?["id"], device["id"]))
                    {
                        Reply(0, J.O(("deferredApplied", J.O(("device", device["id"]), ("action", jobAction), ("args", jobArgs), ("value", result), ("superseded", FlowDeferredStore.Jobs(key).Count > 0)))), null);
                        editingBlocked = false; UpdateEditing();
                    }
                }
                else if (!waiting && error.Value is not { Domain: "Flow2Studio", Code: 2 })
                {
                    FlowDeferredStore.Block(J.Str(job["id"]), error.Value?.Message, key);
                    if (J.Same(selected?["id"], device["id"]))
                        Reply(0, J.O(("deferredError", J.O(("device", device["id"]), ("action", jobAction), ("args", jobArgs), ("message", error.Value?.Message ?? L("Настройка не подтверждена. Автоматическое применение приостановлено."))))), null);
                }
                PublishDeferred();
            });
        });
    }
    void MonitorConnections()
    {
        if (sleeping || firmwareBusy || terminating) return;
        var usb = FlowTransport.Devices().OfType<JsonObject>().Where(d => J.Str(d["connection"]) == "USB").Select(d => J.Str(d["id"]) ?? "").OrderBy(s => s, StringComparer.Ordinal);
        string inventory = string.Join(",", usb); bool changed = inventory != usbInventory; usbInventory = inventory;
        if (changed) Reply(0, J.O(("connectionsChanged", true)), null);
        if (selected == null || chargePending) return;
        // Status reads do not start an editing lease. Plug changes trigger an immediate refresh.
        if (Flow.BatteryPollDue(Uptime, lastChargeAttempt, Foreground(), J.Bool(Preferences()["autoCharge"]), changed)) RefreshCharge();
    }
}
