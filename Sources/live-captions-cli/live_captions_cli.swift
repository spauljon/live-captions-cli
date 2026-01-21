import Foundation
import AVFoundation
import Speech

// MARK: - Console caption renderer (single-line)

final class ConsoleCaptionRenderer {
    private var lastRenderedCount: Int = 0

    func render(_ text: String) {
        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let padCount = max(0, lastRenderedCount - clean.count)
        let padded = clean + String(repeating: " ", count: padCount)

        FileHandle.standardOutput.write(Data(("\r" + padded).utf8))
        fflush(stdout)
        lastRenderedCount = clean.count
    }

    func newline() {
        FileHandle.standardOutput.write(Data("\n".utf8))
        fflush(stdout)
        lastRenderedCount = 0
    }
}

// MARK: - Live captions engine

final class LiveCaptionsCLI {
    private let renderer = ConsoleCaptionRenderer()

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?

    private var lastText: String = ""

    init(localeIdentifier: String = "en-US") {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "LiveCaptionsCLI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation

        if #available(macOS 12.0, *) {
            req.addsPunctuation = true
        }
        if #available(macOS 13.0, *),
           recognizer.supportsOnDeviceRecognition {
            // Try toggling this; false often matches Live Captions better, but test both.
            req.requiresOnDeviceRecognition = false
        }

        self.request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        print("Input format:", format)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            req.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Speech callback can arrive on any thread.
        // We only ship primitives across to main.
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription

            DispatchQueue.main.async { [weak self] in
                self?.applyUpdate(text: text, isFinal: isFinal, errorDesc: errorDesc)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)

            self.request?.endAudio()
            self.task?.cancel()

            self.request = nil
            self.task = nil
        }
    }

    // Main-queue only
    private func applyUpdate(text: String?, isFinal: Bool, errorDesc: String?) {
        if let text {
            if text != lastText {
                lastText = text
                renderer.render(text)
            }
            if isFinal {
                renderer.newline()
                lastText = ""
            }
        }

        if let err = errorDesc {
            renderer.newline()
            print("Speech error: \(err)")
            stop()
        }
    }
}

// Pragmatic: this object is confined to main queue for mutation.
extension LiveCaptionsCLI: @unchecked Sendable {}

// MARK: - Permissions

private func requestPermissions(_ done: @escaping @Sendable (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { micGranted in
        guard micGranted else {
            print("Microphone permission denied. Enable Terminal/iTerm in Privacy & Security → Microphone.")
            done(false)
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                print("Speech recognition permission denied. Enable Terminal/iTerm in Privacy & Security → Speech Recognition.")
                done(false)
                return
            }
            done(true)
        }
    }
}

// MARK: - Entry point

@main
struct Main {
    static func main() {
        setbuf(stdout, nil)

        let cli = LiveCaptionsCLI(localeIdentifier: "en-US")

        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            cli.stop()
            print("\nStopped.")
            exit(0)
        }
        sig.resume()

        // Kick off permissions + start.
        // Note: we do not depend on Thread.main runloop tricks; just keep the process alive via dispatchMain.
        DispatchQueue.main.async {
            requestPermissions { ok in
                guard ok else { exit(1) }

                DispatchQueue.main.async {
                    do {
                        try cli.start()
                        print("Live captions started. Speak into the mic. Press Ctrl+C to stop.\n")
                    } catch {
                        print("Failed to start: \(error.localizedDescription)")
                        exit(1)
                    }
                }
            }
        }

        dispatchMain()
    }
}

