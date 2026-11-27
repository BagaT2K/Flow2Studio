# Flow Operator

A native macOS app for the Lofree Flow 2, written in SwiftUI on top of the Flow2Studio engine (`mac/`).

I wanted a configuration app that feels like it belongs on a Mac and that shows the actual keyboard instead of a diagram. So Flow Operator puts a 3D model of the Flow 2 at the top of the window and keeps it there: the settings scroll underneath, and the camera moves to whatever you are configuring.

It is free and open to everyone. If you own a Flow 2, try it, break it, and tell me what is missing.

> [!CAUTION]
> Same warning as Flow2Studio: flashing firmware is at your own risk. Flow Operator has been used on a **Flow 2 84** with Studio firmware 0.10. The 68 and 100 models are not handled yet.

## What it does

| Section | What you can do |
| --- | --- |
| **Overview** | Model, connection, firmware, battery. Pick the finish of your keyboard (Space Gray or Silver). |
| **Lighting** | Backlight brightness with live preview on the model, the seven effects and their speed, status light brightness and behaviour. |
| **Power** | Sleep delay, wake on touch, low-battery threshold. |
| **Keys** | Click a key on the model, choose its action from about 150 (keys, media, system, layers, macros, Touch Bar profiles). Six layers. Remapped keys light up orange and can be restored one by one. |
| **Touch Bar** | One to three zones, resized by dragging. Three gestures per zone (swipe up, tap, swipe down), with a second set while Fn is held. Presets for the common setups. |
| **Macros** | The 16 macros stored in the keyboard: record your keystrokes or build the steps by hand (text, key press, hold, release, pause), then assign the macro to a key. |
| **Firmware** | Install Studio firmware or go back to Lofree's, with a verified backup before any write. |

The menu bar item shows the battery level at a glance.

The interface follows your system language: French, English, German, Spanish, Simplified Chinese, Japanese, Korean and Russian.

## The 3D model

No official 3D model of the Flow 2 exists, so this one is built from scratch in Blender from Lofree's published dimensions (341.2 × 126 mm, 19.05 mm pitch) and product photos: aluminium case with its chamfers, the 84 keycaps with their dish, the side Touch Bar, the USB-C port, the status light.

- `model/build_flow2.py` generates the model, both finishes and the studio lighting.
- `model/legends.swift` draws the keycap legends.
- `model/build.sh` runs both and installs the result in `swift/Assets/`.

You only need Blender to change the model. The app builds without it.

This is an unofficial model made for this app. Lofree and Flow are trademarks of their owner; this project is not affiliated with Lofree.

## Build

Requires Xcode 26 or later (the macOS 26 SDK) on an Apple Silicon Mac. The app runs on macOS 14 and later.

```bash
bash scripts/build-swift-app.sh
```

The app lands in `dist/Flow Operator.app`.

## Try it without a keyboard

```bash
open "dist/Flow Operator.app" --args -FlowDemo YES
```

Demo mode simulates a Flow 2 84. Nothing is sent to a real keyboard, which makes it the right place to work on the interface.

## How it is organised

| File | Role |
| --- | --- |
| `FlowState.swift` | App state and every call to the engine. Settings are written only when you change a control, never on a refresh. |
| `FlowCatalog.swift` | The 84-key layout and the catalogue of key and Touch Bar actions. |
| `FlowMacros.swift` | Macro encoding, decoding and recording. |
| `Localization.swift`, `Localization/` | The `tr()` helper and one `.lproj` folder per language. The keys are the French strings. |
| `Flow2Scene.swift`, `Keyboard3DView.swift` | The SceneKit scene and its view. |
| `Views/` | The window: sidebar, stage, one view per section. |

## Contributing

Everything here is MIT, like Flow2Studio. Good places to start:

- **Translations.** French is the source language; the seven others were translated with machine help and have not been reviewed by native speakers. Fixes are welcome: each language is one file in `swift/Localization/`.
- **Flow 2 68 and 100.** They need their own layout table and model.
- **Live Touch Bar test**, to see your finger on the model.
- Anything you find awkward. Open an issue with what you expected and what happened.
