// `Flow2Studio.exe --self-check`: offline assertions for the ported byte-level logic and the bundled
// firmware catalogs. Never opens a device. Vectors follow tests/control-release.c and tests/keymap.c.
namespace Flow2Studio;

static class SelfCheck
{
    static void Assert(bool condition, string what) { if (!condition) throw new Exception("Self-check failed: " + what); }

    public static int Run()
    {
        byte[] nonce = { 1, 7, 3, 9 }, p = Flow.ControlRequest(1, 0, 0, 0, nonce);
        uint[] models = { 68, 84, 100 };
        for (int i = 0; i < 3; i++)
        {
            var r = (byte[])p.Clone(); r[4] = 0x81; r[5] = 0; r[10] = 255; r[11] = 3; r[24] = 100; r[25] = 20; r[26] = 1; r[28] = 0x35;
            "F2S1"u8.CopyTo(r.AsSpan(16)); r[20] = (byte)models[i]; r[21] = 0; r[22] = 9; r[23] = 20;
            Assert(Flow.ControlMatch(p, r) && Flow.ControlGeneration(r) == 19 && Flow.ControlModelMatches(r, models[i]), "control 0.9 match");
            Assert(!Flow.ControlModelMatches(r, models[(i + 1) % 3]), "control model isolation");
            r[28] = 0x36; Assert(!Flow.ControlMatch(p, r), "animation mode bound"); r[28] = 0x45; Assert(!Flow.ControlMatch(p, r), "animation speed bound"); r[28] = 0x35;
            r[25] = 101; Assert(!Flow.ControlMatch(p, r), "threshold bound"); r[25] = 20; r[26] = 2; Assert(!Flow.ControlMatch(p, r), "sync bound"); r[26] = 1;
            r[12] ^= 1; Assert(!Flow.ControlMatch(p, r), "nonce"); r[12] ^= 1;
            r[22] = 10; Assert(Flow.ControlMatch(p, r), "release 0.10 (FlowControl.h accepts it; tests/control-release.c predates it)"); r[22] = 9;
            r[23] = 0; Assert(!Flow.ControlMatch(p, r), "base byte"); r[23] = 20;
            r[21] = 3; r[22] = 19; Assert(Flow.ControlMatch(p, r) && Flow.ControlGeneration(r) == 19, "legacy 3.19");
        }
        var request = Flow.Request(nonce); var reply = new byte[33]; reply[1] = 0x15; "LFB"u8.CopyTo(reply.AsSpan(2)); reply[5] = 0x81; reply[6] = 1; reply[7] = 80; nonce.CopyTo(reply, 9);
        Assert(Flow.Validate(reply, nonce) == 1 && request[4] == 1, "battery status with report ID byte");
        var response = new Flow.HIDResponse(); response.Begin(request, false); response.Accept(true, true, 0, reply); Assert(response.Done == 1, "HID response accepts 33-byte report");
        var model68 = Flow.ModelFor(68);
        for (int layer = 0; layer < 6; layer++)
        {
            var data = Flow.ModelDefault(model68, false, layer);
            Assert(Flow.ModelInitializable(model68, false, layer, FlowTables.FlowFactoryKeys.AsSpan(layer * 150)) == (layer != 1 && layer != 3), "layer initializable");
            if (layer != 1 && layer != 3) Assert(data[2] == 0 && data[3] == 30, "layer default");
        }
        var fn = Flow.ModelFn(model68, false, 1); for (int col = 1; col <= 12; col++) Assert(fn[col * 2] == 0 && fn[col * 2 + 1] == 57 + col, "fn template");
        Assert(Flow.MacrosValidSized(new byte[3156], 3156) && !Flow.MacrosValidSized(new byte[3155], 3156), "macro buffer");
        Assert(Flow.BrightnessLevel(255) == 4 && Flow.BrightnessLevel(0) == 0, "brightness");
        Assert(FlowFlashCore.DfuAllowed(new byte[] { 0x83, 0, 0, 0, 0xe8, 3, 0, 0 }, 2, false, Array.Empty<byte[]>(), Array.Empty<uint>(), 0), "dfu reset allowed");
        var write = new byte[268]; write[0] = 0x6a; FlowFlashCore.Put32(write.AsSpan(4), FlowFlashCore.FlashBase); FlowFlashCore.Put32(write.AsSpan(8), 256);
        Assert(!FlowFlashCore.DfuAllowed(write, 2, true, Array.Empty<byte[]>(), new uint[] { 0 }, 1), "dfu write needs a known image");
        foreach (uint model in models)
        {
            var status = FlowFirmware.Status(J.O(("model", model.ToString())));
            Assert(J.Bool(status["available"]), $"catalog {model}: {J.Str(status["message"])}");
            foreach (var file in Directory.GetFiles(Program.ResourcePath("firmware"), $"*-{model}*.bin"))
                Assert(FlowFlashCore.Identify(File.ReadAllBytes(file)) == model, "image identity " + Path.GetFileName(file));
        }
        Console.WriteLine("Self-check passed: control/battery/HID framing, keymaps, macros, DFU gate, firmware catalogs 68/84/100.");
        return 0;
    }
}
