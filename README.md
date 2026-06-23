# Teleprompter

A free, native iOS teleprompter + selfie video recorder. Read your script straight
off the screen while the front camera records you — the script text is an on-screen
reading layer only and is **never burned into the recorded video**.

Built with SwiftUI + AVFoundation. 100% on-device: nothing you record, type, or say
ever leaves your phone.

> No App Store build is provided. You build and install it yourself with Xcode and
> your own Apple ID (free). See **[Build & run](#build--run)** below.

---

## Features

- **Teleprompter overlay** over the live camera, with a smooth scroll.
  - **Grab-to-scrub**: touch the text to pause, drag to reposition, release to continue.
  - **Resizable reading area**: drag the bottom handle to make the reading panel taller/shorter (top edge stays locked). Remembered between launches.
- **Two scroll modes** (switch in the menu):
  - **Speed** — classic auto-scroll at an adjustable speed.
  - **Voice** — *voice-driven scrolling*: the app listens to your speech (on-device) and moves the text to match where you are in the script. Pause and it stops; speed up and it follows.
- **Recording**
  - Front/back **camera switch** (while not recording).
  - **Picture-in-Picture (PiP)** mode: record the **back camera full-screen with your face in a corner**, both composited into a single video. The selfie window shape (rectangle / square / circle), size, and position (drag) are adjustable.
  - **Resolution** (720p / 1080p / 4K) and **frame rate** (30 / 60 fps) settings.
- **Quality-of-life**
  - Hideable controls (collapse to just the record button).
  - Rule-of-thirds **grid** to frame your shot.
  - Adjustable font size and text mirroring.
  - Screen stays awake while reading; videos save straight to **Photos**.

---

## Requirements

- A **Mac** with **Xcode 16 or newer** (free from the Mac App Store).
- An **iPhone running iOS 18 or newer**.
- A **free Apple ID** for code signing (no paid Apple Developer account required).
- For **PiP dual-camera** mode: an iPhone that supports multi-cam capture (iPhone XS / XR and newer).

---

## Build & run

1. **Clone** the repository:
   ```bash
   git clone https://github.com/<your-username>/teleprompter-ios.git
   cd teleprompter-ios
   ```
2. **Open** `Teleprompter.xcodeproj` in Xcode (double-click it).
3. **Set up signing** (one-time):
   - Select the **Teleprompter** project in the navigator → **TARGETS → Teleprompter** → **Signing & Capabilities**.
   - **Team**: choose *Add an Account…* and sign in with your Apple ID (free), then select your **Personal Team**.
   - If you see "Bundle Identifier is not available", change the **Bundle Identifier** to something unique, e.g. `com.yourname.teleprompter`.
4. **Enable Developer Mode on the iPhone** (iOS 16+):
   - *Settings → Privacy & Security → Developer Mode → On* → the phone restarts.
   - (The Developer Mode option only appears after Xcode has tried to install an app at least once — if you don't see it, run step 6 first, let it fail, then come back here.)
5. **Connect** your iPhone with a cable and select it as the run destination at the top of Xcode.
6. **Run** (Cmd+R). The first launch may be blocked as "Untrusted Developer":
   - *Settings → General → VPN & Device Management* → tap your developer profile → **Trust**.
   - Reopen the app.

### How long does the app stay installed?

This depends on the Apple ID you sign with:

| Signing | App stays valid | Renew by |
|---|---|---|
| **Free Apple ID** | **7 days** | Reconnecting and pressing **Run** again (~10 s). Your recordings and settings are not lost. |
| **Apple Developer Program** ($99/yr) | **1 year** | — |
| **[AltStore](https://altstore.io) / SideStore** | auto-renews | Keeping the helper app running on your computer |

No internet, Mac, or cable is needed once the app is installed — it runs fully standalone until the signature expires.

---

## Permissions & privacy

The app asks for:

- **Camera** — to record video.
- **Microphone** — to record audio (and to feed the on-device speech recognizer in Voice mode).
- **Photos (add only)** — to save finished recordings.
- **Speech Recognition** — only for Voice mode. Recognition runs **on-device** (offline); nothing is sent anywhere.

There is no analytics, no account, and no network usage. Everything stays on your device.

---

## Notes & limitations

- **Voice mode language** follows your **device language**; if there's no offline model for it, the app falls back to **English**. If a language has no on-device model at all, Voice mode is unavailable and the toggle shows a note (Speed mode still works). A manual language picker is not implemented yet.
- **Voice tracking is approximate** — there's a small delay and matching can occasionally drift. Speed mode and manual scrubbing are always available as a fallback.
- **PiP mode** requires multi-cam support (A12 Bionic / iPhone XS or newer). The PiP self-view is composited into the recording (it is *not* a perfectly lip-synced separate track — it's two live camera feeds combined).
- **4K @ 60 fps** depends on the specific camera/device; if a combination isn't supported, the nearest available format is used automatically.
- **Quality/FPS settings apply to normal mode**; PiP runs at a balanced default because two simultaneous cameras are bandwidth-limited.

---

## Project structure

```
Teleprompter/
├── TeleprompterApp.swift     // app entry point
├── ContentView.swift         // main screen: camera + teleprompter + controls + settings
├── TeleprompterView.swift    // the scrolling text layer (speed + voice modes)
├── CameraManager.swift       // single-camera capture, recording, camera switch, quality/FPS
├── CameraPreview.swift       // live camera preview (UIViewRepresentable)
├── VoiceScrollManager.swift  // on-device speech recognition → scroll progress
├── DualCameraManager.swift   // multi-cam capture + PiP compositing (AVAssetWriter)
├── DualCameraScreen.swift    // PiP mode UI + dual preview
├── PiPShape.swift            // PiP window shape enum
└── Assets.xcassets           // app icon / accent color
```

**Tech:** SwiftUI · AVFoundation (capture, `AVCaptureMultiCamSession`, `AVAssetWriter`) · Speech framework (on-device) · Core Image (PiP compositing). Deployment target iOS 18.

---

## License

[MIT](LICENSE) — free to use, modify, and share.
