import SwiftUI
import AVFoundation
import UIKit

/// Náhled obou kamer: zadní přes celou plochu, přední (zrcadlená) v pravém horním rohu.
struct DualCameraPreview: UIViewRepresentable {
    let manager: DualCameraManager
    var shape: PiPShape
    var sizeFraction: CGFloat
    var centerX: CGFloat
    var centerY: CGFloat

    func makeUIView(context: Context) -> DualPreviewUIView {
        let view = DualPreviewUIView()
        view.backgroundColor = .black
        view.backLayer = manager.backPreviewLayer
        view.frontLayer = manager.frontPreviewLayer
        view.layer.addSublayer(manager.backPreviewLayer)
        view.layer.addSublayer(manager.frontPreviewLayer)
        manager.frontPreviewLayer.masksToBounds = true
        manager.frontPreviewLayer.borderWidth = 2
        manager.frontPreviewLayer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: DualPreviewUIView, context: Context) {
        apply(to: uiView)
        uiView.setNeedsLayout()
    }

    private func apply(to view: DualPreviewUIView) {
        view.shape = shape
        view.sizeFraction = sizeFraction
        view.centerX = centerX
        view.centerY = centerY
    }

    final class DualPreviewUIView: UIView {
        weak var backLayer: AVCaptureVideoPreviewLayer?
        weak var frontLayer: AVCaptureVideoPreviewLayer?
        var shape: PiPShape = .rectangle
        var sizeFraction: CGFloat = 0.28
        var centerX: CGFloat = 0.82
        var centerY: CGFloat = 0.16

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backLayer?.frame = bounds

            let w = bounds.width * sizeFraction
            let h = (shape == .rectangle) ? w * 16.0 / 9.0 : w
            var x = bounds.width * centerX - w / 2
            var y = bounds.height * centerY - h / 2
            x = min(max(x, 0), bounds.width - w)
            y = min(max(y, 0), bounds.height - h)
            frontLayer?.frame = CGRect(x: x, y: y, width: w, height: h)

            switch shape {
            case .rectangle: frontLayer?.cornerRadius = w * 0.06
            case .square:    frontLayer?.cornerRadius = w * 0.08
            case .circle:    frontLayer?.cornerRadius = min(w, h) / 2
            }
            CATransaction.commit()
        }
    }
}

struct DualCameraScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dual = DualCameraManager()

    @AppStorage("script") private var script: String = ""
    @AppStorage("fontSize") private var fontSize: Double = 34
    @AppStorage("speed") private var speed: Double = 45
    @AppStorage("mirrorText") private var mirrorText: Bool = false
    @AppStorage("showGrid") private var showGrid: Bool = false
    @AppStorage("promptFraction") private var savedPromptFraction: Double = 0.55
    @AppStorage("pipShape") private var pipShape: PiPShape = .rectangle
    @AppStorage("pipSize") private var pipSize: Double = 0.28
    @AppStorage("pipCenterX") private var pipCenterX: Double = 0.82
    @AppStorage("pipCenterY") private var pipCenterY: Double = 0.16

    @State private var promptFraction: Double = 0.55
    @State private var resizeStartFraction: Double?
    @State private var scrolling = false
    @State private var showEditor = false
    @State private var scrollID = UUID()
    @State private var controlsHidden = false

    var body: some View {
        ZStack {
            if dual.permissionGranted {
                DualCameraPreview(
                    manager: dual,
                    shape: pipShape,
                    sizeFraction: CGFloat(pipSize),
                    centerX: CGFloat(pipCenterX),
                    centerY: CGFloat(pipCenterY)
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            if showGrid && dual.permissionGranted {
                ruleOfThirdsGrid
            }

            GeometryReader { geo in
                VStack(spacing: 0) {
                    TeleprompterView(
                        text: script,
                        fontSize: fontSize,
                        speed: speed,
                        isRunning: scrolling,
                        mirror: mirrorText
                    )
                    .id(scrollID)
                    .frame(height: geo.size.height * CGFloat(promptFraction))
                    .background(
                        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                    resizeHandle(totalHeight: geo.size.height)

                    Spacer(minLength: 0).allowsHitTesting(false)
                }
            }

            if dual.permissionGranted {
                pipDragLayer
            }

            VStack {
                topBar
                Spacer()
                if controlsHidden { minimizedControls } else { controls }
            }
            .padding()

            if !dual.permissionGranted {
                infoOverlay
            }
        }
        .statusBarHidden(true)
        .overlay(alignment: .top) {
            if dual.didSaveVideo { savedToast }
        }
        .animation(.spring(duration: 0.3), value: dual.didSaveVideo)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            promptFraction = savedPromptFraction
            pushPiP()
            dual.start()
        }
        .onChange(of: pipShape) { _, _ in pushPiP() }
        .onChange(of: pipSize) { _, _ in pushPiP() }
        .onChange(of: pipCenterX) { _, _ in pushPiP() }
        .onChange(of: pipCenterY) { _, _ in pushPiP() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            dual.stop()
        }
        .onChange(of: dual.isRecording) { _, recording in
            scrolling = recording
            if recording { scrollID = UUID() }
        }
        .onChange(of: dual.didSaveVideo) { _, saved in
            if saved {
                Task { try? await Task.sleep(for: .seconds(2)); dual.didSaveVideo = false }
            }
        }
        .sheet(isPresented: $showEditor) { editorSheet }
        .alert("Error", isPresented: Binding(
            get: { dual.lastError != nil },
            set: { if !$0 { dual.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
            if !dual.isSupported {
                Button("Close") { dismiss() }
            }
        } message: {
            Text(dual.lastError ?? "")
        }
    }

    // MARK: - Lišty

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            if dual.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("REC · PiP").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Picker("", selection: $pipShape) {
                    Image(systemName: "rectangle.portrait").tag(PiPShape.rectangle)
                    Image(systemName: "square").tag(PiPShape.square)
                    Image(systemName: "circle").tag(PiPShape.circle)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)

                Image(systemName: "person.crop.square").foregroundStyle(.secondary)
                Slider(value: $pipSize, in: 0.18...0.45)
            }

            HStack(spacing: 26) {
                glyph("pencil") { showEditor = true }
                glyph("square.grid.3x3", tint: showGrid ? .yellow : .white) { showGrid.toggle() }
                glyph("character.cursor.ibeam", tint: mirrorText ? .yellow : .white) { mirrorText.toggle() }
                glyph("arrow.counterclockwise") { scrollID = UUID() }
            }

            sliderRow(icon: "tortoise.fill", trailing: "hare.fill", value: $speed, range: 10...140)
            sliderRow(icon: "textformat.size.smaller", trailing: "textformat.size.larger", value: $fontSize, range: 18...64)

            HStack(spacing: 28) {
                glyph(scrolling ? "pause.fill" : "play.fill") { scrolling.toggle() }
                recordButton
                glyph("chevron.down") {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsHidden = true }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

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
        Button { dual.toggleRecording() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
                RoundedRectangle(cornerRadius: dual.isRecording ? 6 : 28)
                    .fill(.red)
                    .frame(width: dual.isRecording ? 30 : 56, height: dual.isRecording ? 30 : 56)
                    .animation(.spring(duration: 0.25), value: dual.isRecording)
            }
        }
        .disabled(!dual.permissionGranted)
    }

    // MARK: - Táhlo výšky

    private func resizeHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Capsule().fill(.white.opacity(0.6)).frame(width: 44, height: 5)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7)).offset(y: 12)
        }
        .frame(maxWidth: .infinity).frame(height: 32)
        .background(.black.opacity(0.3))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStartFraction == nil { resizeStartFraction = promptFraction }
                    let base = resizeStartFraction ?? promptFraction
                    promptFraction = min(0.9, max(0.25, base + Double(value.translation.height / totalHeight)))
                }
                .onEnded { _ in
                    resizeStartFraction = nil
                    savedPromptFraction = promptFraction
                }
        )
    }

    // MARK: - Helpery

    private func glyph(_ name: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).frame(width: 44, height: 44)
        }
        .foregroundStyle(tint)
    }

    private func sliderRow(icon: String, trailing: String,
                           value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Slider(value: value, in: range)
            Image(systemName: trailing).foregroundStyle(.secondary)
        }
    }

    // MARK: - Tažení selfie okénka

    private func pushPiP() {
        dual.setPiPConfig(shape: pipShape,
                          size: CGFloat(pipSize),
                          centerX: CGFloat(pipCenterX),
                          centerY: CGFloat(pipCenterY))
    }

    private var pipDragLayer: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let w = W * CGFloat(pipSize)
            let h = (pipShape == .rectangle) ? w * 16.0 / 9.0 : w
            Color.clear
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .position(x: CGFloat(pipCenterX) * W, y: CGFloat(pipCenterY) * H)
                .gesture(
                    DragGesture(coordinateSpace: .named("pipSpace"))
                        .onChanged { value in
                            let halfX = Double((w / 2) / W)
                            let halfY = Double((h / 2) / H)
                            pipCenterX = min(max(Double(value.location.x / W), halfX), 1 - halfX)
                            pipCenterY = min(max(Double(value.location.y / H), halfY), 1 - halfY)
                        }
                )
        }
        .coordinateSpace(name: "pipSpace")
        .ignoresSafeArea()
    }

    private var ruleOfThirdsGrid: some View {
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

    private var editorSheet: some View {
        NavigationStack {
            TextEditor(text: $script)
                .font(.system(size: 20)).padding(8)
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

    private var infoOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Allow camera & microphone").font(.headline)
            Text("Recording needs them. Open Settings and enable them.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
