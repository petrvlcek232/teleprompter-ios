import ReplayKit
import AVFoundation

/// Broadcast Upload Extension — zaznamenává CELOU obrazovku telefonu + mikrofon
/// a zapisuje do sdíleného App Group kontejneru. Hlavní appka pak soubor uloží
/// do Fotek. Bez facecamu (kamera v broadcast rozšíření na iOS nefunguje).
///
/// ⚠️ `appGroupID` MUSÍ odpovídat App Group nastavené v Signing & Capabilities
/// u OBOU targetů (appka i toto rozšíření).
class SampleHandler: RPBroadcastSampleHandler {

    private let appGroupID = "group.com.example.teleprompter"
    private let pendingKey = "pendingScreenRecording"

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Writer se založí až z prvního snímku (potřebujeme rozměry obrazovky).
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            appendVideo(sampleBuffer)
        case .audioMic:
            appendAudio(sampleBuffer)
        default:
            break   // .audioApp ignorujeme — chceme jen namluvený komentář z mikrofonu
        }
    }

    override func broadcastFinished() {
        guard let writer, sessionStarted, writer.status == .writing else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            if writer.status == .completed, let url = self.outputURL {
                // Vzkaz hlavní appce, ať to uloží do Fotek.
                UserDefaults(suiteName: self.appGroupID)?.set(url.lastPathComponent, forKey: self.pendingKey)
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Zápis

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if writer == nil {
            setupWriter(width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let writer, let videoInput else { return }

        if !sessionStarted {
            guard writer.status == .unknown else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let writer, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    private func setupWriter(width: Int, height: Int) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let url = container.appendingPathComponent("screen-\(UUID().uuidString).mp4")
        outputURL = url

        guard let writer = try? AVAssetWriter(url: url, fileType: .mp4) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100.0
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }

        self.writer = writer
        self.videoInput = vInput
        self.audioInput = aInput
    }
}
