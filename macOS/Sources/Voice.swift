import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceManager: ObservableObject {
    enum Phase { case idle, listening, thinking, speaking }

    static let shared = VoiceManager()

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var permissionDenied = false
    @Published var micAuthorized = false

    var onFinal: ((String) -> Void)?
    var onSpeakingEnd: (() -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sayProcess: Process?
    private var endpointTask: Task<Void, Never>?
    private var listenStart = Date()
    private var lastPartial = Date()
    private var voiceName: String?

    // ---------------------------------------------------------- permisos

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            let speechOK = auth == .authorized
            DispatchQueue.main.async {
                guard speechOK else {
                    self.permissionDenied = true
                    completion(false)
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        self.micAuthorized = granted
                        if !granted { self.permissionDenied = true }
                        completion(granted)
                    }
                }
            }
        }
    }

    private func makeRecognizer() -> SFSpeechRecognizer? {
        for id in ["es_ES", "es_MX", "es_419", "es"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                return r
            }
        }
        return SFSpeechRecognizer()
    }

    // ---------------------------------------------------------- escuchar

    func startListening() {
        guard !transcript.isEmpty || transcript.isEmpty else { return }
        stopListening(silently: true)
        guard let recognizer = makeRecognizer() else {
            permissionDenied = true
            return
        }
        self.recognizer = recognizer
        transcript = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        req.contextualStrings = ["Candy", "Candy IA"]
        request = req

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }

        listenStart = Date()
        lastPartial = Date()
        phase = .listening

        do {
            try engine.start()
        } catch {
            permissionDenied = true
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.lastPartial = Date()
                    if result.isFinal {
                        self.finishListening(send: true)
                    }
                }
                if error != nil {
                    self.finishListening(send: true)
                }
            }
        }

        endpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.phase == .listening else { return }
                let silent = Date().timeIntervalSince(self.lastPartial)
                let elapsed = Date().timeIntervalSince(self.listenStart)
                if elapsed > 1.0 && silent > 1.4 && !self.transcript.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty {
                    self.finishListening(send: true)
                    return
                }
                if elapsed > 30 {
                    self.finishListening(send: !self.transcript.isEmpty)
                    return
                }
            }
        }
    }

    func stopListening(silently: Bool = false) {
        endpointTask?.cancel()
        endpointTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        request?.endAudio()
        task?.finish()
        task?.cancel()
        task = nil
        request = nil
        if !silently && phase == .listening {
            phase = .idle
        }
    }

    private func finishListening(send: Bool) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening(silently: true)
        phase = .idle
        if send, !text.isEmpty {
            onFinal?(text)
        }
    }

    /// Detiene la escucha desde la UI enviando lo que se haya entendido.
    func finishManual() {
        finishListening(send: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // ---------------------------------------------------------- hablar

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        stopSpeaking()
        let clean = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        guard !clean.isEmpty else {
            completion?()
            return
        }
        if voiceName == nil { voiceName = detectSpanishVoice() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let voice = voiceName {
            args += ["-v", voice]
        }
        args += ["-r", "205", "--", clean]
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                self?.sayProcess = nil
                if self?.phase == .speaking {
                    self?.phase = .idle
                    completion?()
                    self?.onSpeakingEnd?()
                }
            }
        }
        phase = .speaking
        try? p.run()
        sayProcess = p
    }

    func stopSpeaking() {
        if let p = sayProcess, p.isRunning {
            p.terminate()
        }
        sayProcess = nil
        if phase == .speaking { phase = .idle }
    }

    /// Esc interrumpe: corta la lectura; si ya no está hablando, corta el micrófono.
    func interrupt() {
        if phase == .speaking {
            stopSpeaking()
            startListening()
        } else if phase == .listening {
            finishListening(send: false)
        }
    }

    private func detectSpanishVoice() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fallback: String?
        for line in text.split(separator: "\n") {
            let l = String(line)
            guard let nameRange = l.range(of: "es_") else { continue }
            let before = l[..<nameRange.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !before.isEmpty else { continue }
            if l.contains("es_ES") { return before }
            if fallback == nil { fallback = before }
        }
        return fallback
    }
}
