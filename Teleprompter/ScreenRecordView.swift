import SwiftUI
import ReplayKit
import Photos

/// Spustí systémové nahrávání CELÉ obrazovky + mikrofon (přes Broadcast Extension)
/// a po skončení uloží výsledek do Fotek. Bez facecamu (iOS to u systémového
/// záznamu neumožňuje).
///
/// ⚠️ `appGroupID` a `extensionBundleID` musí odpovídat tomu, co nastavíš v Xcode
/// (App Group + bundle id Broadcast rozšíření). Viz SETUP-SCREEN-RECORDING.md.
struct ScreenRecordView: View {
    private let appGroupID = "group.com.example.teleprompter"
    private let extensionBundleID = "com.example.teleprompter.broadcast"
    private let pendingKey = "pendingScreenRecording"

    @Environment(\.dismiss) private var dismiss
    @State private var status: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "record.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)

                Text("Record your whole screen")
                    .font(.title2.weight(.semibold))

                Text("Captures everything on your phone plus your microphone. Tap the button, choose this app, and Start Broadcast — iOS shows a 3-2-1 countdown, then switch to whatever you want to record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                BroadcastPicker(preferredExtension: extensionBundleID)
                    .frame(width: 80, height: 80)
                    .background(.ultraThinMaterial, in: Circle())

                Text("Enable Microphone in the broadcast sheet to record narration. Stop from the red status bar or Control Center — the video is then saved to Photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Screen recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { savePendingRecordingIfNeeded() }
        }
    }

    /// Po návratu do appky zkontroluje, zda rozšíření dokončilo záznam, a uloží ho do Fotek.
    private func savePendingRecordingIfNeeded() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let name = defaults.string(forKey: pendingKey),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return }

        let url = container.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            defaults.removeObject(forKey: pendingKey)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { authStatus in
            guard authStatus == .authorized || authStatus == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, _ in
                if success {
                    try? FileManager.default.removeItem(at: url)
                    defaults.removeObject(forKey: pendingKey)
                    DispatchQueue.main.async { self.status = "Last screen recording saved to Photos" }
                }
            }
        }
    }
}

/// Systémové tlačítko pro výběr broadcast cíle (start/stop nahrávání obrazovky).
struct BroadcastPicker: UIViewRepresentable {
    let preferredExtension: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        view.preferredExtension = preferredExtension
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
