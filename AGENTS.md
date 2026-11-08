# Agent notes

Flow2Studio configures Lofree Flow 2 keyboards. One web UI (`resources/`) runs inside two native hosts:

| Path | Role |
| --- | --- |
| `resources/` | Shared web UI. Do not fork it per platform. |
| `firmware-bundle/` | Shipped firmware images and pinned model catalogs. |
| `mac/` | macOS host (Objective-C, WKWebView). The reference implementation. |
| `windows/` | Windows host (C#, WinForms + WebView2). One `.cs` file per `mac/` module. |
| `firmware/`, `localization/`, `tests/` | Firmware build inputs, string catalogs, tests. |

## Build

- macOS: `scripts/build-app.sh` (needs a Mac).
- Windows: `powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1` (.NET 10 SDK). Output: `dist\Flow2Studio-windows\` with `Flow2Studio.exe`, `ui\`, `firmware\`.
- Windows offline check: `Flow2Studio.exe --self-check` (no device access). The build script runs it.

## Rules

- `mac/` is the source of truth for protocol, packet layouts and firmware safety. Port changes byte for byte; never guess.
- Platform differences go in the host, not in `resources/`. The Windows host injects a script that maps `window.webkit.messageHandlers.flow` onto WebView2; native-to-JS messages go through `window.flowReceive`.
- Never weaken firmware safety: pinned catalog hashes, model and controller checks, verified backup before any write, page allow-list, rollback, single-use consent.
- Do not flash or write to a real keyboard unless the user asks for it.

## Windows gotchas

- **Line endings.** With `core.autocrlf=true`, Git rewrites `firmware-bundle/model-*-v14.json` and their pinned SHA-256 checks fail (flashing is blocked). `scripts/build-windows.ps1` restores LF in the dist copy only.
- **Bootloader driver.** Flashing needs WinUSB on the WB32 bootloader `342D:DFA0` (recovery: Fn, left Shift, Esc). Install once per PC with Zadig; see README. Never bind WinUSB to the keyboard in normal mode (`388D:xxxx`).
- **Zadig runs elevated**, so UI automation from a normal process cannot read or click it.
- **HID reports** are 33 bytes on Windows: report ID 0 plus the 32-byte packet. The host refuses other sizes.
- **JSON numbers.** Use the `J` helpers in `windows/FlowPreferences.cs`. `JsonValue.GetValue<double>()` throws on values created from C# `int`.
- **Model detection** uses the USB PID like the Mac host: 1 = 68, 2 = 84, 3 = 100.

## Hardware coverage

- Windows: Studio 0.10 prepared on a Flow 2 84 over USB. Bluetooth, 2.4 GHz receiver, 68 and 100 are untested.
- macOS: tested by the author on Flow 2 68 only.
