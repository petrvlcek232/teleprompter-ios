# Screen recording setup (optional)

The app can record your **whole phone screen + microphone** (like Control Center,
but started from inside the app and auto-saved to Photos). There is **no face camera**
in this mode — iOS does not allow the camera in a screen-broadcast recording.

This feature needs a second target — a **Broadcast Upload Extension** — which is most
reliably added through Xcode's UI. The code is already in this repo; you just wire it up.

## Steps (one-time, ~5 minutes)

1. **Add the extension target**
   - In Xcode: **File → New → Target… → Broadcast Upload Extension**.
   - Product Name: `ScreenBroadcast` (any name is fine).
   - **Uncheck** "Include UI Extension".
   - Finish. When asked to activate the new scheme, click **Activate**.

2. **Use the provided code**
   - Xcode generated a `SampleHandler.swift` in the new target. **Replace its entire
     contents** with the contents of [`BroadcastExtension/SampleHandler.swift`](BroadcastExtension/SampleHandler.swift) from this repo.

3. **Set bundle identifiers**
   - Main app target bundle id, e.g. `com.yourname.teleprompter`.
   - Extension target bundle id **must be a child of the app's**, e.g. `com.yourname.teleprompter.broadcast`.
   - Open `Teleprompter/ScreenRecordView.swift` and set `extensionBundleID` to that exact extension bundle id.

4. **Add an App Group to BOTH targets**
   - Select the **Teleprompter** target → **Signing & Capabilities → + Capability → App Groups** → add a group, e.g. `group.com.yourname.teleprompter`.
   - Do the **same** for the **ScreenBroadcast** target, using the **same** group id.
   - Update the `appGroupID` constant in **both** `Teleprompter/ScreenRecordView.swift` and `BroadcastExtension/SampleHandler.swift` to match that group id.

5. **Signing**
   - Make sure both targets use your Team (free Apple ID works) under Signing & Capabilities.

6. **Run**
   - Build & run the app on your iPhone.
   - Open the app → top bar → the **screen-record button** → tap the round broadcast button → choose your extension → **Start Broadcast**.
   - iOS shows a **3-2-1 countdown**, then records everything. Switch to any app you want to capture.
   - To enable narration, make sure **Microphone** is on in the broadcast sheet (long-press the record control in Control Center also toggles the mic).
   - **Stop** from the red status bar / Control Center.
   - Return to the app — the recording is **saved to Photos** automatically.

## Notes

- The extension writes the video into the shared App Group container; the app saves it to Photos the next time you open the screen-recording screen.
- If the broadcast button shows nothing to pick, the extension target isn't installed yet — re-check steps 1 and 3.
- iOS's built-in Control Center screen recording does the same thing for free; this just integrates it into the app.
