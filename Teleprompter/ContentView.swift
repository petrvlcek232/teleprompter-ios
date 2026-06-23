import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var voice = VoiceScrollManager()
    private let multiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported

    @AppStorage("script") private var script: String =
        "Hi! This is your script.\n\nTap the pencil to write your own text.\n\nUse the sliders to set scroll speed and font size. When you're ready, tap the red button and start reading."
    @AppStorage("fontSize") private var fontSize: Double = 34
    @AppStorage("speed") private var speed: Double = 45
    @AppStorage("mirrorText") private var mirrorText: Bool = false
    @AppStorage("showGrid") private var showGrid: Bool = false
    @AppStorage("videoQuality") private var videoQuality: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    @AppStorage("scrollMode") private var scrollMode: String = "speed"   // "speed" | "voice"

    @State private var scrolling = false
    @State private var showEditor = false
    @State private var scrollID = UUID()
    @State private var controlsHidden = false
    @State private var showPiP = false
    @State private var showSettings = false
    @State private var showScreenRecorder = false

    @AppStorage("promptFraction") private var savedPromptFraction: Double = 0.55
    @State private var promptFraction: Double = 0.55
    @State private var resizeStartFraction: Double?

    var body: some View {
        ZStack {
            if camera.permissionGranted {
                CameraPreview(session: camera.session, mirrored: camera.cameraPosition == .front)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            if showGrid && camera.permissionGranted {
                gridOverlay
            }

            // Vrstva s textem v horní části obrazovky
            GeometryReader { geo in
                VStack(spacing: 0) {
                    TeleprompterView(
                        text: script,
                        fontSize: fontSize,
                        speed: speed,
                        isRunning: scrolling,
                        mirror: mirrorText,
                        voiceProgress: (scrollMode == "voice" && voice.available) ? voice.progress : nil
                    )
                    .id(scrollID)
                    .frame(height: geo.size.height * CGFloat(promptFraction))
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.55), .black.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    resizeHandle(totalHeight: geo.size.height)

                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
            }

            VStack {
                topBar
                Spacer()
                if controlsHidden {
                    minimizedControls
                } else {
                    controls
                }
            }
            .padding()

            if !camera.permissionGranted {
                permissionOverlay
            }
        }
        .statusBarHidden(true)
        .overlay(alignment: .top) {
            if camera.didSaveVideo { savedToast }
        }
        .animation(.spring(duration: 0.3), value: camera.didSaveVideo)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // displej nezhasne při čtení
            promptFraction = savedPromptFraction
            applyVideoConfig()
            camera.audioSampleHandler = { [voice] buffer in voice.append(buffer) }
            Task { _ = await VoiceScrollManager.authorize() }
            camera.start()
        }
        .onChange(of: videoQuality) { _, _ in applyVideoConfig() }
        .onChange(of: videoFPS) { _, _ in applyVideoConfig() }
        .onChange(of: scrolling) { _, _ in updateVoiceTracking() }
        .onChange(of: scrollMode) { _, _ in updateVoiceTracking() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            voice.stop()
        }
        .onChange(of: camera.isRecording) { _, recording in
            scrolling = recording                 // start nahrávání = rozjede čtení
            if recording { scrollID = UUID() }    // a začne od začátku
        }
        .onChange(of: camera.didSaveVideo) { _, saved in
            if saved {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    camera.didSaveVideo = false
                }
            }
        }
        .sheet(isPresented: $showEditor) { editorSheet }
        .fullScreenCover(isPresented: $showPiP, onDismiss: { camera.start() }) {
            DualCameraScreen()
        }
        .onChange(of: showPiP) { _, presented in
            if presented { camera.stop() }   // uvolni kameru pro dual-cam režim
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showScreenRecorder) { ScreenRecordView() }
        .alert("Error", isPresented: Binding(
            get: { camera.lastError != nil },
            set: { if !$0 { camera.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.lastError ?? "")
        }
    }

    // MARK: - Horní lišta

    private var topBar: some View {
        HStack {
            if camera.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("REC").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if !camera.isRecording {
                Button { showScreenRecorder = true } label: {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white)

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func updateVoiceTracking() {
        if scrollMode == "voice" && voice.available && scrolling {
            voice.start(script: script)
        } else {
            voice.stop()
        }
    }

    private func applyVideoConfig() {
        let (w, h): (Int32, Int32)
        switch videoQuality {
        case "720p": (w, h) = (1280, 720)
        case "4K":   (w, h) = (3840, 2160)
        default:     (w, h) = (1920, 1080)
        }
        camera.setVideoConfig(width: w, height: h, fps: Double(videoFPS))
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Resolution") {
                    Picker("Quality", selection: $videoQuality) {
                        Text("720p").tag("720p")
                        Text("1080p").tag("1080p")
                        Text("4K").tag("4K")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Frame rate") {
                    Picker("FPS", selection: $videoFPS) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Changes apply when not recording. If the device doesn't support a combination (e.g. 4K 60 fps), the closest available format is used. Applies to normal mode; PiP runs at a balanced default.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Video settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Táhlo pro změnu výšky čtecího pole

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.6))
                .frame(width: 44, height: 5)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .offset(y: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(.black.opacity(0.3))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStartFraction == nil { resizeStartFraction = promptFraction }
                    let base = resizeStartFraction ?? promptFraction
                    let delta = Double(value.translation.height / totalHeight)
                    promptFraction = min(0.9, max(0.25, base + delta))
                }
                .onEnded { _ in
                    resizeStartFraction = nil
                    savedPromptFraction = promptFraction   // ulož až po puštění
                }
        )
    }

    // MARK: - Ovládání

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 22) {
                iconButton("pencil") { showEditor = true }
                toggleIconButton("square.grid.3x3", on: showGrid) { showGrid.toggle() }
                toggleIconButton("character.cursor.ibeam", on: mirrorText) { mirrorText.toggle() }
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .foregroundStyle(camera.isRecording ? .white.opacity(0.3) : .white)
                .disabled(camera.isRecording)

                if multiCamSupported {
                    iconButton("pip.enter") { showPiP = true }
                }
            }

            Picker("", selection: $scrollMode) {
                Text("Speed").tag("speed")
                Text("Voice").tag("voice")
            }
            .pickerStyle(.segmented)

            if scrollMode == "speed" {
                sliderRow(icon: "tortoise.fill", trailing: "hare.fill",
                          value: $speed, range: 10...140)
            } else if !voice.available {
                Text("Voice tracking isn't available on this device/language (no offline model).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if voice.listening {
                Label("Listening — read and the text follows you", systemImage: "waveform")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            sliderRow(icon: "textformat.size.smaller", trailing: "textformat.size.larger",
                      value: $fontSize, range: 18...64)

            HStack(spacing: 28) {
                iconButton(scrolling ? "pause.fill" : "play.fill") { scrolling.toggle() }
                iconButton("arrow.counterclockwise") { scrollID = UUID() }
                recordButton
                iconButton("chevron.down") {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsHidden = true }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

    /// Skryté ovládání: zůstane jen nahrávací tlačítko + ikona pro vyvolání menu.
    private var minimizedControls: some View {
        HStack(spacing: 16) {
            recordButton
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { controlsHidden = false }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
        }
    }

    private var recordButton: some View {
        Button {
            camera.toggleRecording()
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 30 : 56,
                           height: camera.isRecording ? 30 : 56)
                    .animation(.spring(duration: 0.25), value: camera.isRecording)
            }
        }
        .disabled(!camera.permissionGranted)
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).frame(width: 44, height: 44)
        }
        .foregroundStyle(.white)
    }

    private func toggleIconButton(_ name: String, on: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).frame(width: 44, height: 44)
        }
        .foregroundStyle(on ? .yellow : .white)
    }

    // MARK: - Mřížka (pravidlo třetin) pro vycentrování záběru

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func sliderRow(icon: String, trailing: String,
                           value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Slider(value: value, in: range)
            Image(systemName: trailing).foregroundStyle(.secondary)
        }
    }

    // MARK: - Editor scénáře

    private var editorSheet: some View {
        NavigationStack {
            TextEditor(text: $script)
                .font(.system(size: 20))
                .padding(8)
                .navigationTitle("Script")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear", role: .destructive) { script = "" }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showEditor = false }
                    }
                }
        }
    }

    // MARK: - Overlaye

    private var permissionOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Allow camera & microphone").font(.headline)
            Text("Recording needs them. Open Settings and enable them.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    private var savedToast: some View {
        Text("Saved to Photos ✓")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview {
    ContentView()
}
