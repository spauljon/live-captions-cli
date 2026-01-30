import Foundation
import AVFoundation
import Speech

// MARK: - Final-only producer: emits append-only FINAL segments (NDJSON on stdout)

final class FinalOnlyProducer {
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Tap feeds audio into *current* request (we swap this pointer on new sessions)
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?

    // Stability-based “final” segmentation (text-stability, not audio VAD)
    private var latestFullText: String = ""
    private var lastChangeTime: DispatchTime = .now()
    private var silenceTimer: DispatchSourceTimer?

    // Tune these
    private let silenceMillis: UInt64 = 1200           // 800–1500 is typical
    private let timerTickMillis: UInt64 = 200          // how often we check stability

    // Delta emission tracking (per session)
    private var emittedPrefixCount: Int = 0

    // Stream identity
    private let streamId = UUID().uuidString
    private var seq: Int = 0

    // Guard against overlapping session resets
    private var isResettingSession: Bool = false

    // Session token to ignore late callbacks from previous sessions
    private var sessionToken: Int = 0

    init(localeIdentifier: String = "en-US") {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    // MARK: - Public lifecycle

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "FinalOnlyProducer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"]
            )
        }

        emit(kind: "status", detail: "starting", extra: [
            "locale": recognizer.locale.identifier
        ])

        // Start audio engine once
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        emit(kind: "status", detail: "audio_format", extra: [
            "sampleRate": format.sampleRate,
            "channels": format.channelCount
        ])

        inputNode.removeTap(onBus: 0)

        // Install a tap once; it appends into currentRequest (which we swap per session)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.currentRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Start first recognition session + timer
        startNewSession()
        startSilenceTimer()

        emit(kind: "status", detail: "ready")
    }

    func stop() {
        DispatchQueue.main.async {
            self.silenceTimer?.cancel()
            self.silenceTimer = nil

            self.currentRequest = nil

            self.request?.endAudio()
            self.task?.cancel()
            self.request = nil
            self.task = nil

            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)

            self.emit(kind: "status", detail: "stopped")
        }
    }

    // MARK: - Session management (2-method approach)

    // Scheduler: always hop to main
    private func startNewSession() {
        DispatchQueue.main.async { [weak self] in
            self?.startNewSessionOnMain()
        }
    }

    // Main-queue-only
    private func startNewSessionOnMain() {
        guard !isResettingSession else { return }
        isResettingSession = true
        defer { isResettingSession = false }

        guard let recognizer, recognizer.isAvailable else {
            emit(kind: "error", detail: "Speech recognizer unavailable")
            stop()
            return
        }

        // Advance session token (ignore late callbacks from older tasks)
        sessionToken += 1
        let myToken = sessionToken

        // Tear down prior session
        currentRequest = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil

        // Reset per-session state
        latestFullText = ""
        lastChangeTime = .now()
        emittedPrefixCount = 0

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(macOS 12.0, *) { req.addsPunctuation = true }
        if #available(macOS 13.0, *), recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = false
        }

        request = req
        currentRequest = req

        // IMPORTANT: Extract primitives in this callback thread BEFORE hopping to main,
        // so we never send non-Sendable `result` across queues.
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            let errDesc: String? = error?.localizedDescription

            // Extract fullText on this thread (String is Sendable)
            let fullText: String? = result?
                .bestTranscription
                .formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Ignore callbacks from previous sessions
                guard myToken == self.sessionToken else { return }

                if let errDesc {
                    // Expected during segmentation (endAudio/cancel); don't spiral
                    if self.isResettingSession || self.isBenignErrorMessage(errDesc) {
                        return
                    }

                    self.emit(kind: "error", detail: errDesc)
                    self.startNewSession()
                    return
                }

                guard let fullText, !fullText.isEmpty else { return }

                if fullText != self.latestFullText {
                    self.latestFullText = fullText
                    self.lastChangeTime = .now()
                }
            }
        }
    }

    private func isBenignErrorMessage(_ msg: String) -> Bool {
        let m = msg.lowercased()
        if m.contains("canceled") { return true }
        if m.contains("cancelled") { return true } // spelling variants
        if m.contains("no speech detected") { return true }
        return false
    }

    // MARK: - Stability timer → commit “final” segment

    private func startSilenceTimer() {
        silenceTimer?.cancel()

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + .milliseconds(Int(timerTickMillis)),
            repeating: .milliseconds(Int(timerTickMillis))
        )
        t.setEventHandler { [weak self] in
            self?.checkForStableSegment()
        }
        t.resume()
        silenceTimer = t
    }

    private func checkForStableSegment() {
        guard !isResettingSession else { return }
        guard !latestFullText.isEmpty else { return }

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - lastChangeTime.uptimeNanoseconds
        let elapsedMillis = elapsedNanos / 1_000_000
        guard elapsedMillis >= silenceMillis else { return }

        // Commit the current transcript as a “final segment”
        emitFinalDelta(fromFullText: latestFullText)

        // IMPORTANT: clear immediately so the timer doesn't re-trigger before session reset runs
        latestFullText = ""
        lastChangeTime = .now()

        // Start fresh session so transcripts don't grow without bound
        startNewSession()
    }

    // MARK: - Emit: delta + NDJSON

    private func emitFinalDelta(fromFullText fullText: String) {
        // If recognizer shrank/reset unexpectedly, reset prefix tracking
        if emittedPrefixCount > fullText.count {
            emittedPrefixCount = 0
        }

        let delta: String
        if emittedPrefixCount == 0 {
            delta = fullText
        } else if emittedPrefixCount >= fullText.count {
            delta = ""
        } else {
            let idx = fullText.index(fullText.startIndex, offsetBy: emittedPrefixCount)
            delta = String(fullText[idx...])
        }

        emittedPrefixCount = fullText.count

        let cleaned = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        emit(kind: "final", text: cleaned)
    }

    private func emit(kind: String, text: String? = nil, detail: String? = nil, extra: [String: Any] = [:]) {
        seq += 1

        var msg: [String: Any] = [
            "v": 1,
            "kind": kind,
            "streamId": streamId,
            "seq": seq,
            "ts": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let text { msg["text"] = text }
        if let detail { msg["detail"] = detail }
        for (k, v) in extra { msg[k] = v }

        if let data = try? JSONSerialization.data(withJSONObject: msg, options: []) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            fflush(stdout)
        }
    }
}

extension FinalOnlyProducer: @unchecked Sendable {}

// MARK: - Permissions

private func requestPermissions(_ done: @escaping @Sendable (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { micGranted in
        guard micGranted else { done(false); return }
        SFSpeechRecognizer.requestAuthorization { status in
            done(status == .authorized)
        }
    }
}

// MARK: - Entry point

@main
struct Main {
    static func main() {
        setbuf(stdout, nil)

        let producer = FinalOnlyProducer(localeIdentifier: "en-US")

        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            producer.stop()
            exit(0)
        }
        sig.resume()

        DispatchQueue.main.async {
            requestPermissions { ok in
                guard ok else {
                    FileHandle.standardOutput.write(
                        Data("{\"v\":1,\"kind\":\"error\",\"detail\":\"permissions_denied\"}\n".utf8)
                    )
                    exit(1)
                }

                do {
                    try producer.start()
                } catch {
                    FileHandle.standardOutput.write(
                        Data("{\"v\":1,\"kind\":\"error\",\"detail\":\"\(error.localizedDescription)\"}\n".utf8)
                    )
                    exit(1)
                }
            }
        }

        dispatchMain()
    }
}
