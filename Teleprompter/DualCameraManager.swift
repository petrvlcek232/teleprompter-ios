import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Photos
import SwiftUI

/// Současné natáčení zadní (hlavní) + přední (PiP v rohu) kamery do JEDNOHO videa.
/// Hlavní záběr = zadní kamera přes celou plochu, přední kamera složená do pravého
/// horního rohu. Skládá se každý snímek přes Core Image a zapisuje přes AVAssetWriter.
@MainActor
final class DualCameraManager: NSObject, ObservableObject {
    @Published var permissionGranted = false
    @Published var isRecording = false
    @Published var didSaveVideo = false
    @Published var lastError: String?
    @Published var isSupported = AVCaptureMultiCamSession.isMultiCamSupported

    let session = AVCaptureMultiCamSession()
    let backPreviewLayer = AVCaptureVideoPreviewLayer()
    let frontPreviewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "teleprompter.dualcam.session")

    nonisolated(unsafe) private let backVideoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let frontVideoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioOutput = AVCaptureAudioDataOutput()
    nonisolated(unsafe) private let ciContext = CIContext()
    private let ioQueue = DispatchQueue(label: "teleprompter.dualcam.io")

    private var isConfigured = false

    // Stav zápisu — vše čtené/psané jen na ioQueue.
    nonisolated(unsafe) private var latestFront: CVPixelBuffer?
    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoWriterInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioWriterInput: AVAssetWriterInput?
    nonisolated(unsafe) private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var sessionStarted = false
    nonisolated(unsafe) private var recording = false
    nonisolated(unsafe) private var outputURL: URL?
    nonisolated(unsafe) private var outputSize = CGSize(width: 1080, height: 1920)

    // Konfigurace selfie okénka (sdílená s náhledem). Měněno z MainActoru,
    // čteno renderovacím vláknem — prosté hodnoty, bez race s následky.
    nonisolated(unsafe) private var pipShape: PiPShape = .rectangle
    nonisolated(unsafe) private var pipSizeFraction: CGFloat = 0.28
    nonisolated(unsafe) private var pipCenterXNorm: CGFloat = 0.82
    nonisolated(unsafe) private var pipCenterYNorm: CGFloat = 0.16

    func setPiPConfig(shape: PiPShape, size: CGFloat, centerX: CGFloat, centerY: CGFloat) {
        pipShape = shape
        pipSizeFraction = size
        pipCenterXNorm = centerX
        pipCenterYNorm = centerY
    }

    // MARK: - Lifecycle

    func start() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            isSupported = false
            lastError = "This device doesn't support recording with two cameras at once."
            return
        }
        Task {
            let camOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            permissionGranted = camOK
            if camOK {
                configure(audio: micOK)
            } else {
                lastError = "Camera access is required. Enable it in Settings."
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure(audio: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.isConfigured {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }

            self.session.beginConfiguration()

            // Zadní (hlavní)
            guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let backInput = try? AVCaptureDeviceInput(device: back),
                  self.session.canAddInput(backInput) else {
                self.failConfig("Couldn't open the back camera.")
                return
            }
            self.session.addInputWithNoConnections(backInput)

            // Přední (PiP)
            guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let frontInput = try? AVCaptureDeviceInput(device: front),
                  self.session.canAddInput(frontInput) else {
                self.failConfig("Couldn't open the front camera.")
                return
            }
            self.session.addInputWithNoConnections(frontInput)

            let pixelFormat = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.backVideoOutput.videoSettings = pixelFormat
            self.frontVideoOutput.videoSettings = pixelFormat
            self.backVideoOutput.setSampleBufferDelegate(self, queue: self.ioQueue)
            self.frontVideoOutput.setSampleBufferDelegate(self, queue: self.ioQueue)

            guard self.session.canAddOutput(self.backVideoOutput),
                  self.session.canAddOutput(self.frontVideoOutput) else {
                self.failConfig("Couldn't set up the video output.")
                return
            }
            self.session.addOutputWithNoConnections(self.backVideoOutput)
            self.session.addOutputWithNoConnections(self.frontVideoOutput)

            // Náhledové vrstvy je nutné svázat se session BEZ auto-connection,
            // jinak zůstanou černé (rotaci/zrcadlení řeší jejich connection).
            self.backPreviewLayer.setSessionWithNoConnection(self.session)
            self.frontPreviewLayer.setSessionWithNoConnection(self.session)

            // Ruční propojení portů (multi-cam vyžaduje explicitní connections).
            // Data-output NErotujeme/NEzrcadlíme — to řeší skládání přes Core Image.
            if let backPort = backInput.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first {
                let dataConn = AVCaptureConnection(inputPorts: [backPort], output: self.backVideoOutput)
                if self.session.canAddConnection(dataConn) { self.session.addConnection(dataConn) }

                let previewConn = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: self.backPreviewLayer)
                if self.session.canAddConnection(previewConn) {
                    self.session.addConnection(previewConn)
                    self.orientPreview(previewConn, mirror: false)
                }
            }

            if let frontPort = frontInput.ports(for: .video, sourceDeviceType: front.deviceType, sourceDevicePosition: .front).first {
                let dataConn = AVCaptureConnection(inputPorts: [frontPort], output: self.frontVideoOutput)
                if self.session.canAddConnection(dataConn) { self.session.addConnection(dataConn) }

                let previewConn = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: self.frontPreviewLayer)
                if self.session.canAddConnection(previewConn) {
                    self.session.addConnection(previewConn)
                    self.orientPreview(previewConn, mirror: true)
                }
            }

            // Audio
            if audio,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInputWithNoConnections(micInput)
                if self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutputWithNoConnections(self.audioOutput)
                    self.audioOutput.setSampleBufferDelegate(self, queue: self.ioQueue)
                    if let micPort = micInput.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified).first {
                        let audioConn = AVCaptureConnection(inputPorts: [micPort], output: self.audioOutput)
                        if self.session.canAddConnection(audioConn) { self.session.addConnection(audioConn) }
                    }
                }
            }

            self.backPreviewLayer.videoGravity = .resizeAspectFill
            self.frontPreviewLayer.videoGravity = .resizeAspectFill

            self.session.commitConfiguration()
            self.isConfigured = true
            self.session.startRunning()
        }
    }

    private func orientPreview(_ connection: AVCaptureConnection, mirror: Bool) {
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if mirror, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    private func failConfig(_ message: String) {
        session.commitConfiguration()
        Task { @MainActor in self.lastError = message }
    }

    // MARK: - Nahrávání

    func toggleRecording() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.recording { self.finishRecording() } else { self.startRecording() }
        }
    }

    nonisolated private func startRecording() {
        guard !recording else { return }
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelAdaptor = nil
        sessionStarted = false
        recording = true
        Task { @MainActor in self.isRecording = true }
    }

    nonisolated private func finishRecording() {
        guard recording else { return }
        recording = false
        Task { @MainActor in self.isRecording = false }

        guard let writer = assetWriter, sessionStarted else {
            assetWriter = nil
            return
        }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let url = writer.outputURL
            let ok = writer.status == .completed
            self.ioQueue.async {
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.pixelAdaptor = nil
                self.sessionStarted = false
            }
            if ok {
                self.saveToPhotos(url)
            } else {
                Task { @MainActor in self.lastError = writer.error?.localizedDescription ?? "Saving failed." }
            }
        }
    }

    nonisolated private func buildWriter(width: Int, height: Int) -> Bool {
        let url = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        outputURL = url
        outputSize = CGSize(width: width, height: height)

        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else {
            Task { @MainActor in self.lastError = "Couldn't start the recording." }
            return false
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(vInput) else { return false }
        writer.add(vInput)
        if writer.canAdd(aInput) { writer.add(aInput) }

        assetWriter = writer
        videoWriterInput = vInput
        audioWriterInput = aInput
        pixelAdaptor = adaptor
        return true
    }

    nonisolated private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard recording, let mainPB = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Zadní kamera v portrétu = rotace .right; rovnou portrétní extent.
        let mainImage = CIImage(cvPixelBuffer: mainPB).oriented(.right)
        let canvas = CGRect(origin: .zero, size: mainImage.extent.size)

        if assetWriter == nil {
            guard buildWriter(width: Int(canvas.width), height: Int(canvas.height)) else { return }
        }
        guard let writer = assetWriter, let adaptor = pixelAdaptor, let vInput = videoWriterInput else { return }

        if !sessionStarted {
            guard writer.status == .unknown else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard vInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var outPB: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB) == kCVReturnSuccess,
              let dst = outPB else { return }

        var image = place(mainImage, into: canvas)

        if let front = latestFront {
            // Přední kamera v portrétu, zrcadlená = .leftMirrored.
            let frontImage = CIImage(cvPixelBuffer: front).oriented(.leftMirrored)

            let w = canvas.width * pipSizeFraction
            let h = (pipShape == .rectangle) ? w * 16.0 / 9.0 : w
            let cx = pipCenterXNorm * canvas.width
            let cy = canvas.height - pipCenterYNorm * canvas.height   // SwiftUI (shora) → CI (zdola)
            var x = cx - w / 2
            var y = cy - h / 2
            x = min(max(x, 0), canvas.width - w)
            y = min(max(y, 0), canvas.height - h)
            let pipRect = CGRect(x: x, y: y, width: w, height: h)

            let radius: CGFloat
            switch pipShape {
            case .rectangle: radius = w * 0.06
            case .square:    radius = w * 0.08
            case .circle:    radius = min(w, h) / 2
            }

            let placed = place(frontImage, into: pipRect)
            if let mask = roundedMask(rect: pipRect, radius: radius) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = placed
                blend.backgroundImage = image
                blend.maskImage = mask
                image = blend.outputImage ?? placed.composited(over: image)
            } else {
                image = placed.composited(over: image)
            }
        }

        ciContext.render(image, to: dst, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(dst, withPresentationTime: pts)
    }

    nonisolated private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recording, sessionStarted, let aInput = audioWriterInput, aInput.isReadyForMoreMediaData else { return }
        aInput.append(sampleBuffer)
    }

    /// Umístí obraz do daného obdélníku (aspect-fill + ořez na střed).
    nonisolated private func place(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let scale = max(rect.width / e.width, rect.height / e.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let se = scaled.extent
        let cropX = se.origin.x + (se.width - rect.width) / 2
        let cropY = se.origin.y + (se.height - rect.height) / 2
        let cropped = scaled.cropped(to: CGRect(x: cropX, y: cropY, width: rect.width, height: rect.height))
        return cropped.transformed(by: CGAffineTransform(translationX: rect.minX - cropX, y: rect.minY - cropY))
    }

    /// Bílá zaoblená maska (kruh = radius = polovina strany) pro tvar PiP okénka.
    nonisolated private func roundedMask(rect: CGRect, radius: CGFloat) -> CIImage? {
        let gen = CIFilter.roundedRectangleGenerator()
        gen.extent = rect
        gen.radius = Float(radius)
        gen.color = CIColor.white
        return gen.outputImage
    }

    nonisolated private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self.lastError = "No permission to save to Photos." }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, err in
                Task { @MainActor in
                    if success { self.didSaveVideo = true }
                    else { self.lastError = err?.localizedDescription ?? "Saving to Photos failed." }
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

extension DualCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if output === frontVideoOutput {
            latestFront = CMSampleBufferGetImageBuffer(sampleBuffer)
        } else if output === audioOutput {
            appendAudio(sampleBuffer)
        } else {
            appendVideo(sampleBuffer)
        }
    }
}
