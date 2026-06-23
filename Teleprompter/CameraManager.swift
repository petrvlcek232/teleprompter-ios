import AVFoundation
import Photos
import SwiftUI

/// Spravuje kameru, mikrofon a nahrávání videa. Text teleprompteru je jen
/// SwiftUI vrstva NAD náhledem — do natočeného videa se nezapisuje.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var permissionGranted = false
    @Published var isRecording = false
    @Published var didSaveVideo = false
    @Published var lastError: String?
    @Published var cameraPosition: AVCaptureDevice.Position = .front

    let session = AVCaptureSession()

    /// Předává zvukové vzorky dál (rozpoznávač řeči pro hlasové posouvání).
    nonisolated(unsafe) var audioSampleHandler: ((CMSampleBuffer) -> Void)?

    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "teleprompter.camera.audio")
    private let sessionQueue = DispatchQueue(label: "teleprompter.camera.session")
    private var isConfigured = false
    private var videoInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var desiredWidth: Int32 = 1920
    private var desiredHeight: Int32 = 1080
    private var desiredFPS: Double = 30

    /// Vyžádá si přístup ke kameře + mikrofonu a nastaví session.
    func start() {
        Task {
            let camOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            permissionGranted = camOK
            if camOK {
                configureIfNeeded(audioEnabled: micOK)
            } else {
                lastError = "Camera access is required. Enable it in Settings."
            }
        }
    }

    private func configureIfNeeded(audioEnabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.isConfigured {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority   // rozlišení/FPS řídí aktivní formát zařízení

            // Přední kamera (selfie)
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
                self.applyVideoFormat(device)
            }

            // Mikrofon
            if audioEnabled,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInput(micInput)
            }

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            // Paralelní odběr zvuku pro rozpoznávání řeči (hlasové posouvání).
            if self.session.canAddOutput(self.audioDataOutput) {
                self.session.addOutput(self.audioDataOutput)
                self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
            }

            // Aby natočené video odpovídalo zrcadlovému náhledu.
            if let connection = self.movieOutput.connection(with: .video),
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }

            self.session.commitConfiguration()
            self.isConfigured = true
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    /// Přepne přední ⇆ zadní kameru. Funguje i během nahrávání — záznam pokračuje
    /// do stejného souboru (může nastat krátký zákmit při přepnutí).
    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // AVCaptureMovieFileOutput přepnutí vstupu během nahrávání neumí bez ztráty
            // souboru — proto přepínáme jen mimo nahrávání.
            guard !self.movieOutput.isRecording else { return }
            let newPosition: AVCaptureDevice.Position = (self.currentPosition == .front) ? .back : .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            if let current = self.videoInput {
                self.session.removeInput(current)
            }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.currentPosition = newPosition
                self.applyVideoFormat(device)
            } else if let current = self.videoInput {
                self.session.addInput(current)   // revert, kdyby přidání selhalo
            }

            if let connection = self.movieOutput.connection(with: .video),
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (self.currentPosition == .front)
            }
            self.session.commitConfiguration()

            Task { @MainActor in self.cameraPosition = self.currentPosition }
        }
    }

    /// Nastaví rozlišení + FPS (projeví se mimo nahrávání). Pokud zařízení danou
    /// kombinaci nepodporuje, zvolí nejbližší možný formát.
    func setVideoConfig(width: Int32, height: Int32, fps: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.desiredWidth = width
            self.desiredHeight = height
            self.desiredFPS = fps
            guard self.isConfigured, !self.movieOutput.isRecording,
                  let device = self.videoInput?.device else { return }
            self.session.beginConfiguration()
            self.applyVideoFormat(device)
            self.session.commitConfiguration()
        }
    }

    private func applyVideoFormat(_ device: AVCaptureDevice) {
        let matching = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == desiredWidth && d.height == desiredHeight
        }
        guard !matching.isEmpty else { return }   // rozlišení nepodporováno → necháme aktuální

        let supportsFPS: (AVCaptureDevice.Format) -> Bool = { fmt in
            fmt.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= self.desiredFPS && self.desiredFPS <= $0.maxFrameRate
            }
        }
        let chosen = matching.first(where: supportsFPS) ?? matching.max { a, b in
            (a.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0) <
            (b.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0)
        }
        guard let format = chosen else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if supportsFPS(format) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(desiredFPS))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            // při chybě necháme aktuální formát
        }
    }
}

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        audioSampleHandler?(sampleBuffer)
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.isRecording = true }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in self.isRecording = false }

        if let error {
            Task { @MainActor in self.lastError = error.localizedDescription }
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        saveToPhotos(outputFileURL)
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
                    if success {
                        self.didSaveVideo = true
                    } else {
                        self.lastError = err?.localizedDescription ?? "Saving to Photos failed."
                    }
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
