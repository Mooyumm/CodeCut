import Foundation
import CryptoKit
import AVFoundation
import QuartzCore
import AppKit

private final class ExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}

enum ProjectStore {
    enum Error: LocalizedError {
        case missingSource, invalidName, projectExists
        var errorDescription: String? {
            switch self {
            case .missingSource: "找不到原始视频，请重新定位素材。"
            case .invalidName: "项目名称不能为空，也不能包含路径符号。"
            case .projectExists: "同名项目已经存在。"
            }
        }
    }
    static func defaultURL(for name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "CodeCut/Projects", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(name).codecut")
    }
    static func save(_ document: ProjectDocument, to url: URL) throws {
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try JSONEncoder.pretty.encode(document).write(to: url, options: .atomic)
    }
    static func load(from url: URL) throws -> ProjectDocument {
        do { return try JSONDecoder.iso8601.decode(ProjectDocument.self, from: Data(contentsOf: url)) }
        catch {
            let backup = url.appendingPathExtension("backup")
            guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
            return try JSONDecoder.iso8601.decode(ProjectDocument.self, from: Data(contentsOf: backup))
        }
    }
    static func recentProjects() -> [URL] {
        let folder = defaultURL(for: "placeholder").deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "codecut" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }
    static func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":") else { throw Error.invalidName }
        let destination = url.deletingLastPathComponent().appending(path: "\(clean).codecut")
        guard destination == url || !FileManager.default.fileExists(atPath: destination.path) else { throw Error.projectExists }
        var document = try load(from: url)
        document.name = clean
        try save(document, to: destination)
        if destination != url {
            try FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
        }
        return destination
    }
    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.trashItem(at: backup, resultingItemURL: nil) }
    }
}

enum TranscriptCache {
    static func load(videoURL: URL, settings: MiMoSettings) -> TranscriptDocument? {
        load(videoURL: videoURL, identity: [settings.baseURL, settings.asrPath, settings.asrModel].joined(separator: "|"))
    }

    static func load(videoURL: URL, identity: String) -> TranscriptDocument? {
        guard let url = try? url(videoURL: videoURL, identity: identity),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    static func save(_ document: TranscriptDocument, videoURL: URL, settings: MiMoSettings) throws {
        try save(document, videoURL: videoURL, identity: [settings.baseURL, settings.asrPath, settings.asrModel].joined(separator: "|"))
    }

    static func save(_ document: TranscriptDocument, videoURL: URL, identity: String) throws {
        let destination = try url(videoURL: videoURL, identity: identity)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(document).write(to: destination, options: .atomic)
    }

    static func remove(videoURL: URL, settings: MiMoSettings) {
        remove(videoURL: videoURL, identity: [settings.baseURL, settings.asrPath, settings.asrModel].joined(separator: "|"))
    }

    static func remove(videoURL: URL, identity: String) {
        guard let destination = try? url(videoURL: videoURL, identity: identity) else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    static func url(videoURL: URL, settings: MiMoSettings, folder: URL? = nil) throws -> URL {
        try url(videoURL: videoURL, identity: [settings.baseURL, settings.asrPath, settings.asrModel].joined(separator: "|"), folder: folder)
    }

    static func url(videoURL: URL, identity: String, folder: URL? = nil) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let cacheIdentity = ["timing-v9", videoURL.standardizedFileURL.path, String((attributes[.size] as? NSNumber)?.int64Value ?? 0), String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0), identity].joined(separator: "|")
        let key = SHA256.hash(data: Data(cacheIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "CodeCut/Transcripts", directoryHint: .isDirectory)
        return root.appending(path: "\(key).json")
    }
}

enum TimelineExporter {
    enum Format: Equatable { case resolve, finalCutPro }

    static func export(_ edl: EditDecisionList, projectName: String, folder: URL, format: Format) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try srt(edl).write(to: folder.appending(path: "\(projectName).srt"), atomically: true, encoding: .utf8)
        switch format {
        case .resolve:
            try cmx3600(edl, name: projectName).write(to: folder.appending(path: "\(projectName).edl"), atomically: true, encoding: .utf8)
        case .finalCutPro:
            try fcpxml(edl, name: projectName).write(to: folder.appending(path: "\(projectName).fcpxml"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor static func renderMP4(_ edl: EditDecisionList, projectName: String, folder: URL, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        let source = AVURLAsset(url: URL(fileURLWithPath: edl.sourcePath))
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else { throw ProjectStore.Error.missingSource }
        let sourceAudio = try await source.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MiMoError.invalidResponse("无法创建视频轨道") }
        let audio = sourceAudio.flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var cursor = CMTime.zero
        for kept in edl.keptRanges {
            let range = CMTimeRange(start: CMTime(seconds: kept.start, preferredTimescale: 600), duration: CMTime(seconds: kept.duration, preferredTimescale: 600))
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio, let audio { try audio.insertTimeRange(range, of: sourceAudio, at: cursor) }
            cursor = cursor + range.duration
        }
        guard cursor > .zero, let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw MiMoError.invalidResponse("没有可导出的视频片段") }
        let exporterBox = ExportSessionBox(exporter)
        if edl.burnSubtitles {
            let cues = exportSubtitleCues(edl)
            if !cues.isEmpty {
                let naturalSize = try await sourceVideo.load(.naturalSize)
                let transform = try await sourceVideo.load(.preferredTransform)
                let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
                let renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                let adjusted = transform.concatenating(CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY))
                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = renderSize
                videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(edl.frameRate.rounded()))))
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                layerInstruction.setTransform(adjusted, at: .zero)
                instruction.layerInstructions = [layerInstruction]
                videoComposition.instructions = [instruction]
                let parent = CALayer(), videoLayer = CALayer()
                parent.frame = CGRect(origin: .zero, size: renderSize); videoLayer.frame = parent.frame
                parent.addSublayer(videoLayer)
                let total = max(0.001, cursor.seconds)
                for cue in cues {
                    let text = CATextLayer()
                    text.string = cue.text; text.alignmentMode = .center; text.isWrapped = true
                    text.fontSize = CGFloat(edl.subtitleFontSize); text.contentsScale = 2
                    text.foregroundColor = NSColor.white.cgColor; text.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
                    text.cornerRadius = 8
                    text.frame = CGRect(x: renderSize.width * 0.06, y: renderSize.height * 0.07, width: renderSize.width * 0.88, height: CGFloat(edl.subtitleFontSize * 2.4))
                    text.opacity = 0
                    let start = max(0, min(1, cue.start / total)), end = max(start, min(1, cue.end / total))
                    let visibility = CAKeyframeAnimation(keyPath: "opacity")
                    visibility.values = [0, 0, 1, 1, 0]
                    visibility.keyTimes = [0, NSNumber(value: start), NSNumber(value: start), NSNumber(value: end), NSNumber(value: end)]
                    visibility.duration = total; visibility.beginTime = AVCoreAnimationBeginTimeAtZero; visibility.isRemovedOnCompletion = false
                    text.add(visibility, forKey: "visibility"); parent.addSublayer(text)
                }
                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
                exporter.videoComposition = videoComposition
            }
        }
        var output = folder.appending(path: "\(projectName).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appending(path: "\(projectName)-\(suffix).mp4")
            suffix += 1
        }
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(exporter.progress))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { progressTask.cancel(); progress(1) }
        try await withTaskCancellationHandler {
            try await exporter.export(to: output, as: .mp4)
        } onCancel: {
            exporterBox.value.cancelExport()
        }
        return output
    }

    static func srt(_ edl: EditDecisionList) -> String {
        var index = 1
        let visibleWords = edl.words.filter {
            !$0.isDeleted && TimelineEngine.outputTime(for: $0.end, deleted: edl.deletedRanges) > TimelineEngine.outputTime(for: $0.start, deleted: edl.deletedRanges)
        }
        return TimelineEngine.subtitleCues(words: visibleWords, breakBefore: Set(edl.subtitleBreaks), joinBefore: Set(edl.subtitleJoins)).compactMap { cue in
            let start = TimelineEngine.outputTime(for: cue.start, deleted: edl.deletedRanges)
            let end = TimelineEngine.outputTime(for: cue.end, deleted: edl.deletedRanges)
            guard end > start else { return nil }
            defer { index += 1 }
            return "\(index)\n\(srtTime(start)) --> \(srtTime(end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func exportSubtitleCues(_ edl: EditDecisionList) -> [(text: String, start: Double, end: Double)] {
        let visibleWords = edl.words.filter {
            !$0.isDeleted && TimelineEngine.outputTime(for: $0.end, deleted: edl.deletedRanges) > TimelineEngine.outputTime(for: $0.start, deleted: edl.deletedRanges)
        }
        return TimelineEngine.subtitleCues(words: visibleWords, breakBefore: Set(edl.subtitleBreaks), joinBefore: Set(edl.subtitleJoins)).compactMap { cue in
            let start = TimelineEngine.outputTime(for: cue.start, deleted: edl.deletedRanges)
            let end = TimelineEngine.outputTime(for: cue.end, deleted: edl.deletedRanges)
            return end > start ? (cue.text, start, end) : nil
        }
    }

    static func fcpxml(_ edl: EditDecisionList, name: String) -> String {
        let fps = edl.frameRate > 0 ? edl.frameRate : 25
        let denominator = Int(fps.rounded())
        func time(_ value: Double) -> String { "\(max(0, Int((value * Double(denominator)).rounded())))/\(denominator)s" }
        var offset = 0.0
        let clips = edl.keptRanges.enumerated().map { index, range -> String in
            defer { offset += range.duration }
            return "<asset-clip name=\"\(xml(name)) \(index + 1)\" ref=\"r2\" offset=\"\(time(offset))\" start=\"\(time(range.start))\" duration=\"\(time(range.duration))\"/>"
        }.joined(separator: "\n")
        let source = URL(fileURLWithPath: edl.sourcePath).absoluteString
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10"><resources><format id="r1" name="CodeCutFormat" frameDuration="1/\(denominator)s" width="1920" height="1080"/><asset id="r2" name="\(xml(name))" src="\(xml(source))" start="0s" duration="\(time(edl.sourceDuration))" hasVideo="1" hasAudio="1" format="r1"/></resources><library><event name="CodeCut"><project name="\(xml(name))"><sequence format="r1" duration="\(time(edl.outputDuration))" tcStart="0s" tcFormat="NDF"><spine>\(clips)</spine></sequence></project></event></library></fcpxml>
        """
    }

    static func cmx3600(_ edl: EditDecisionList, name: String) -> String {
        let fps = max(1, Int(edl.frameRate.rounded()))
        func timecode(_ seconds: Double) -> String {
            let frames = max(0, Int((seconds * Double(fps)).rounded()))
            return String(format: "%02d:%02d:%02d:%02d", frames / (fps * 3600), frames / (fps * 60) % 60, frames / fps % 60, frames % fps)
        }
        var recordCursor = 0.0
        let clipName = URL(fileURLWithPath: edl.sourcePath).lastPathComponent
        let events = edl.keptRanges.enumerated().map { index, range -> String in
            defer { recordCursor += range.duration }
            let recordEnd = recordCursor + range.duration
            let videoNumber = String(format: "%03d", index * 2 + 1)
            let audioNumber = String(format: "%03d", index * 2 + 2)
            let timecodes = "\(timecode(range.start)) \(timecode(range.end)) \(timecode(recordCursor)) \(timecode(recordEnd))"
            return """
            \(videoNumber)  AX       V     C        \(timecodes)
            * FROM CLIP NAME: \(clipName)
            \(audioNumber)  AX       A     C        \(timecodes)
            * FROM CLIP NAME: \(clipName)
            """
        }.joined(separator: "\n")
        return "TITLE: \(name)\nFCM: NON-DROP FRAME\n\n\(events)\n"
    }

    static func storyboardCSV(_ items: [StoryboardItem], edl: EditDecisionList) -> String {
        let words = Dictionary(uniqueKeysWithValues: edl.words.map { ($0.id, $0) })
        func field(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func clock(_ value: Double) -> String { String(format: "%02d:%02d:%04.1f", Int(value) / 3600, Int(value) / 60 % 60, value.truncatingRemainder(dividingBy: 60)) }
        let rows = items.map { item -> String in
            let anchored = item.wordIDs.compactMap { words[$0] }.filter { !$0.isDeleted }
            let sourceStart = anchored.first?.start ?? item.fallbackStart
            let sourceEnd = anchored.last?.end ?? item.fallbackEnd
            let start = TimelineEngine.outputTime(for: sourceStart, deleted: edl.deletedRanges)
            let end = TimelineEngine.outputTime(for: sourceEnd, deleted: edl.deletedRanges)
            let subtitle = TimelineEngine.subtitleDisplayText(anchored.map(\.text).joined())
            return ["\(clock(start)) - \(clock(end))", subtitle, item.kind.rawValue, item.description, item.composition, item.cameraMovement, item.elements, item.notes].map(field).joined(separator: ",")
        }
        return (["时间码", "对应字幕", "类型", "画面描述", "景别/构图", "镜头运动", "素材/动画元素", "备注"].map(field).joined(separator: ",") + "\n" + rows.joined(separator: "\n") + "\n")
    }

    static func exportStoryboardCSV(_ items: [StoryboardItem], edl: EditDecisionList, projectName: String, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(projectName)-分镜表.csv")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(storyboardCSV(items, edl: edl).utf8))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func srtTime(_ value: Double) -> String { let ms = Int((value * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
    private static func xml(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

extension JSONEncoder { static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder } }
extension JSONDecoder { static var iso8601: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder } }
