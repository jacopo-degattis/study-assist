import Foundation
import AVFoundation
import StudyDomain

/// Records an answer with AVAudioRecorder.
///
/// Audio is written to a temporary file in app storage, never to the library.
/// Nothing is submitted anywhere: the transcript lands in the editable answer
/// field and the student decides when to submit.
@MainActor
public final class AudioRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var timer: Timer?
    private var startedAt: Date?
    private let maximumDuration: TimeInterval

    public init(maximumDuration: TimeInterval = 10 * 60) {
        self.maximumDuration = maximumDuration
    }

    /// Requests microphone permission only at this point, never at launch.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start(in directory: URL) async throws {
        guard !isRecording else { return }
        guard await Self.requestPermission() else {
            throw AppError.microphonePermissionDenied
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("answer-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AppError.speechTranscriptionFailed("The microphone could not start recording.")
        }
        self.recorder = recorder
        self.outputURL = url
        self.startedAt = Date()
        self.elapsed = 0
        self.isRecording = true
        startTimer()
    }

    /// Stops and returns the temporary recording URL.
    @discardableResult
    public func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        stopTimer()
        isRecording = false
        self.recorder = nil
        let url = outputURL
        outputURL = nil
        guard let url, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 2_048 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    /// Cancels and deletes the recording.
    public func cancel() {
        recorder?.stop()
        stopTimer()
        isRecording = false
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsed = 0
        level = 0
    }

    public var duration: TimeInterval { elapsed }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= maximumDuration {
            _ = stop()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Converts recordings to the PCM format local recognisers expect, off the main thread.
public enum AudioFileConverter {
    public static func convertToPCM(fileAt url: URL, sampleRate: Double = 16_000) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let outputURL = url.deletingPathExtension().appendingPathExtension("wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        guard let format else {
            throw AppError.speechTranscriptionFailed("The audio format could not be created.")
        }
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw AppError.speechTranscriptionFailed("The audio could not be converted.")
        }
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputBufferLength: AVAudioFrameCount = 4_096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: inputBufferLength) else {
            throw AppError.speechTranscriptionFailed("The audio buffer could not be allocated.")
        }

        var finished = false
        while !finished {
            try input.read(into: inputBuffer)
            if inputBuffer.frameLength == 0 { break }
            let ratio = format.sampleRate / input.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1_024
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AppError.speechTranscriptionFailed("The audio buffer could not be allocated.")
            }
            var error: NSError?
            var consumed = false
            converter.convert(to: outputBuffer, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return inputBuffer
            }
            if let error {
                throw AppError.speechTranscriptionFailed(error.localizedDescription)
            }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            finished = input.framePosition >= input.length
        }
        return outputURL
    }
}
