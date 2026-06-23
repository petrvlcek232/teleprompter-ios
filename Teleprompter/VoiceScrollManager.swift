import Speech
import AVFoundation

/// Sleduje tvou řeč (on-device) a podle toho, kde jsi ve scénáři, hlásí postup 0…1.
/// Audio dostává z capture session (stejné vzorky jako nahrávání) — žádný konflikt o mikrofon.
@MainActor
final class VoiceScrollManager: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var listening = false
    let available: Bool

    private let recognizer: SFSpeechRecognizer?
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var scriptWords: [String] = []
    private var cursor = 0

    override init() {
        let r = VoiceScrollManager.makeRecognizer()
        recognizer = r
        available = r?.supportsOnDeviceRecognition ?? false
        super.init()
    }

    static func authorize() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Preferuj jazyk zařízení; když nemá on-device model, zkus angličtinu (široce podporovaná).
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        if let r = SFSpeechRecognizer(locale: Locale.current), r.supportsOnDeviceRecognition { return r }
        if let r = SFSpeechRecognizer(locale: Locale(identifier: "en_US")), r.supportsOnDeviceRecognition { return r }
        return SFSpeechRecognizer(locale: Locale.current)
    }

    func start(script: String) {
        guard let recognizer, recognizer.isAvailable, !listening else { return }
        scriptWords = VoiceScrollManager.tokenize(script)
        cursor = 0
        progress = 0

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let transcript = result.bestTranscription.formattedString
                Task { @MainActor in self.match(transcript: transcript) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
        listening = true
    }

    func stop() {
        guard listening || task != nil else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        listening = false
    }

    /// Voláno z audio vlákna capture session.
    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    /// Posune kurzor na nejvzdálenější shodu posledního vyřčeného slova v okně před námi.
    private func match(transcript: String) {
        guard !scriptWords.isEmpty else { return }
        let spoken = VoiceScrollManager.tokenize(transcript)
        guard let last = spoken.last else { return }
        let end = min(scriptWords.count, cursor + 25)
        guard cursor < end else { return }
        if let found = (cursor..<end).last(where: { scriptWords[$0] == last }) {
            cursor = found + 1
            progress = Double(cursor) / Double(scriptWords.count)
        }
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
