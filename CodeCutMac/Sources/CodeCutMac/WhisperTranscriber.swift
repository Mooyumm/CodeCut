import Foundation
import WhisperKit

// CodeCut keeps the pipeline on MainActor; this bridges WhisperKit's pre-Swift-6 concurrency annotations.
extension WhisperKit: @retroactive @unchecked Sendable {}

@MainActor
final class WhisperTranscriber {
    static let shared = WhisperTranscriber()
    static let cacheIdentity = "whisperkit-v1.1.0-large-v3-626mb-simplified-character-timing-v2"

    private let model = "large-v3-v20240930_626MB"
    private let modelPathKey = "whisperkit.largeV3ModelFolder"
    private var whisperKit: WhisperKit?

    func transcribe(videoURL: URL, progress: @escaping @MainActor (String) -> Void) async throws -> TranscriptDocument {
        let pipe = try await pipeline(progress: progress)
        progress("WhisperKit 正在转换音频…")
        pipe.transcriptionStateCallback = { state in
            Task { @MainActor in
                switch state {
                case .convertingAudio: progress("WhisperKit 正在转换音频…")
                case .transcribing: progress("WhisperKit 正在识别并对齐时间…")
                case .finished: progress("WhisperKit 正在整理逐字时间戳…")
                }
            }
        }

        // The source may contain quiet speech below EnergyVAD's fixed threshold.
        // Continuous windowing is slower, but avoids dropping spoken sections entirely.
        let options = DecodingOptions(language: "zh", wordTimestamps: true, chunkingStrategy: ChunkingStrategy.none)
        let results = try await pipe.transcribe(audioPath: videoURL.path, decodeOptions: options)
        let timings = results.flatMap(\.allWords).sorted { $0.start < $1.start }
        let words = Self.characterTimings(from: timings)
        guard !words.isEmpty else { throw AIError.invalidResponse("WhisperKit 没有返回逐字时间戳") }
        return TranscriptDocument(
            assetID: videoURL.lastPathComponent,
            language: results.first?.language,
            duration: words.last?.end ?? 0,
            words: words
        )
    }

    private func pipeline(progress: @escaping @MainActor (String) -> Void) async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let folder: URL
        if let local = existingModelFolder() {
            folder = local
            progress("正在加载本地 WhisperKit 模型…")
        } else {
            progress("首次使用：正在下载 WhisperKit 中文模型（约 626 MB）…")
            folder = try await WhisperKit.download(variant: model) { value in
                Task { @MainActor in progress("正在下载 WhisperKit 模型… \(Int(value.fractionCompleted * 100))%") }
            }
            UserDefaults.standard.set(folder.path, forKey: modelPathKey)
        }
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: false, load: true, download: false))
        whisperKit = pipe
        return pipe
    }

    private func existingModelFolder() -> URL? {
        if let saved = UserDefaults.standard.string(forKey: modelPathKey) {
            let folder = URL(fileURLWithPath: saved)
            if Self.isCompleteModelFolder(folder) { return folder }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)", directoryHint: .isDirectory)
        guard Self.isCompleteModelFolder(folder) else { return nil }
        UserDefaults.standard.set(folder.path, forKey: modelPathKey)
        return folder
    }

    static func isCompleteModelFolder(_ folder: URL) -> Bool {
        ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    static func characterTimings(from timings: [WordTiming]) -> [TranscriptWord] {
        timings.flatMap { timing -> [TranscriptWord] in
            let characters = Array(simplified(timing.word)).filter { !$0.isWhitespace }
            guard !characters.isEmpty else { return [] }
            let start = Double(timing.start)
            let end = max(start + 0.01, Double(timing.end))
            let step = (end - start) / Double(characters.count)
            return characters.enumerated().map { index, character in
                TranscriptWord(text: String(character), start: start + Double(index) * step, end: start + Double(index + 1) * step)
            }
        }
    }

    private static func simplified(_ text: String) -> String {
        let value = NSMutableString(string: text)
        CFStringTransform(value, nil, "Traditional-Simplified" as CFString, false)
        return value as String
    }
}
