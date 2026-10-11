import AVFoundation
import Foundation
import Testing
@testable import CodeCutMac

@MainActor @Test func musicReferenceQwenPausesAndResumesSeparation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "QwenPauseTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    let track = MusicReferenceTrack(name: "队列测试", fileName: "a.mp3", originalName: "a.mp3", duration: 20)
    library.document.tracks = [track]
    library.separationOperation = { _, _, _ in
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        throw CancellationError()
    }
    library.enqueueSeparation(track.id)
    for _ in 0..<100 where !library.isSeparating { try await Task.sleep(for: .milliseconds(10)) }
    #expect(library.isSeparating)
    let pausing = Task { await library.pauseSeparationForQwen() }
    pausing.cancel() // Cancellation must still wait for the child, without spinning.
    await pausing.value
    #expect(library.qwenAudioBusy)
    #expect(!library.isSeparating)
    #expect(library.separationQueue.first?.status == "等待中")
    try await Task.sleep(for: .milliseconds(150))
    #expect(!library.isSeparating)
    library.separationOperation = { _, _, _ in throw AIError.invalidResponse("恢复已触发") }
    library.resumeSeparationAfterQwen()
    await library.waitForSeparationQueue()
    #expect(!library.qwenAudioBusy)
    #expect(library.separationQueue.first?.status == "失败")
    #expect(library.separationQueue.first?.detail.contains("恢复已触发") == true)
}

@Test func musicReferenceQwenActualAudio() async throws {
    guard let path = ProcessInfo.processInfo.environment["CODECUT_TEST_QWEN_AUDIO"] else { return }
    let clip = MusicReferenceClip(title: "Qwen实测", start: 0, end: 14)
    let result = try await Task.detached { try MusicAudioFeatures.extractWithQwen(source: URL(fileURLWithPath: path), clip: clip) }.value
    #expect(result.engine.contains("Qwen2-Audio"))
    #expect(result.summary.contains("Qwen2-Audio 音频描述"))
    print(result.summary)
    print("Qwen运行指标：", result.metrics.filter { $0.key.hasPrefix("qwen_") })
}

@MainActor @Test func musicReferenceSeparationQueueDeduplicatesAndRemovesWaiting() {
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicQueueTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    let first = MusicReferenceTrack(name: "第一首", fileName: "a.mp3", originalName: "a.mp3", duration: 20)
    let second = MusicReferenceTrack(name: "第二首", fileName: "b.mp3", originalName: "b.mp3", duration: 20)
    library.document.tracks = [first, second]
    library.enqueueSeparation(first.id, startImmediately: false)
    library.enqueueSeparation(first.id, startImmediately: false)
    library.enqueueSeparation(second.id, startImmediately: false)
    #expect(library.separationQueue.map(\.trackID) == [first.id, second.id])
    library.removeWaitingSeparation(library.separationQueue[0].id)
    #expect(library.separationQueue.map(\.trackID) == [second.id])
    library.separationQueue[0].status = "处理中"
    library.removeWaitingSeparation(library.separationQueue[0].id)
    #expect(library.separationQueue.count == 1)
    library.document.tracks.append(.init(name: "伴奏", fileName: "c.mp3", originalName: "a.mp3", duration: 20, sourceTrackID: first.id))
    library.enqueueSeparation(first.id, startImmediately: false)
    #expect(library.separationQueue.count == 1)
}

@Test func musicReferenceTimelineZoomAndPan() {
    var viewport = MusicTimelineViewport()
    viewport.scroll(delta: 50, anchor: 0.4, zooming: true, duration: 200)
    #expect(viewport.zoom > 1)
    #expect(abs(viewport.start + 0.4 * viewport.span(200) - 80) < 0.0001)
    let start = viewport.start
    viewport.scroll(delta: 20, anchor: 0, zooming: false, duration: 200)
    #expect(viewport.start > start)
    viewport.scroll(delta: 1e6, anchor: 0, zooming: false, duration: 200)
    #expect(abs(viewport.start + viewport.span(200) - 200) < 0.0001)
    viewport.scroll(delta: -1e6, anchor: 0, zooming: false, duration: 200)
    #expect(viewport.start == 0)
    for _ in 0..<20 { viewport.scroll(delta: 100, anchor: 0.5, zooming: true, duration: 200) }
    #expect(viewport.span(200) == 1)
    for _ in 0..<20 { viewport.scroll(delta: -100, anchor: 0.5, zooming: true, duration: 200) }
    #expect(viewport.zoom == 1)
    #expect(viewport.start == 0)
}

@MainActor @Test func musicReferenceEditedPromptPersists() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicPromptTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    var clip = MusicReferenceClip(title: "片段", start: 0, end: 14, note: "原始批注")
    clip.analysis = .init(categories: ["转场"], reason: "原因", evidence: "", suggestions: "", prompt: "旧提示词", avoid: "旧避免项", uncertainties: "", input: clip.input)
    let track = MusicReferenceTrack(name: "音乐", fileName: "source.mp3", originalName: "source.mp3", duration: 20, clips: [clip])
    library.document.tracks = [track]
    library.selectedTrackID = track.id
    library.selectedClipID = clip.id
    let longPrompt = String(repeating: "Instrumental only.\n", count: 200)
    library.editClip { $0.analysis?.prompt = longPrompt }
    library.editClip { $0.analysis?.avoid = "No vocals" }
    let restored = MusicReferenceLibrary(root: root).document.tracks[0].clips[0]
    #expect(restored.analysis?.prompt == longPrompt)
    #expect(restored.analysis?.avoid == "No vocals")
    #expect(restored.note == "原始批注")
    #expect(!restored.isStale)
}

@Test func musicReferenceAudioFeatureRangeInvalidation() {
    var clip = MusicReferenceClip(title: "测试", start: 0, end: 20)
    clip.audioFeatures = .init(engine: "Essentia test", start: 0, end: 20, summary: "实际读取", metrics: ["bpm": 120], warnings: [])
    #expect(clip.currentAudioFeatures != nil)
    #expect(clip.input.contains("实际读取"))
    clip.note = "新批注"
    #expect(clip.currentAudioFeatures != nil)
    clip.end = 21
    #expect(clip.currentAudioFeatures == nil)
    #expect(!clip.input.contains("实际读取"))
}

@Test func musicReferenceEssentiaActualMusic() async throws {
    guard let path = ProcessInfo.processInfo.environment["CODECUT_TEST_FEATURE_AUDIO"] else { return }
    let source = URL(fileURLWithPath: path)
    let clip = MusicReferenceClip(title: "真实音乐测试", start: 0, end: 20)
    let features = try await Task.detached { try MusicAudioFeatures.extract(source: source, clip: clip) }.value
    #expect(features.engine.contains("Essentia"))
    #expect(features.metrics["bpm"] != nil)
    #expect(features.metrics["spectral_centroid_hz"] != nil)
    #expect(abs((features.metrics["duration_seconds"] ?? 0) - 20) < 0.1)
    print("Essentia 实测：\(features.summary)")
}

@MainActor @Test func musicReferenceDragHierarchyAndPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicTreeTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    let clip = MusicReferenceClip(title: "片段", start: 1, end: 4, note: "不变的批注", folder: "A/子目录")
    let track = MusicReferenceTrack(name: "音乐", fileName: "source.mp3", originalName: "source.mp3", duration: 20, clips: [clip], folder: "A")
    library.document.tracks = [track]
    library.document.folders = ["A", "A/子目录", "B", "B/A", "C"]
    #expect(library.save())
    #expect(!library.moveReference("codecut-reference|folder|A", to: "A/子目录"))
    #expect(!library.moveReference("codecut-reference|folder|A", to: "B"))
    #expect(library.moveReference("codecut-reference|folder|A", to: "C"))
    #expect(library.document.folders?.contains("C/A/子目录") == true)
    #expect(library.document.tracks[0].folder == "A")
    #expect(library.document.tracks[0].clips[0].folder == "C/A/子目录")
    #expect(library.moveReference("codecut-reference|folder|C/A", to: ""))
    #expect(library.document.tracks[0].folder == "A")
    #expect(library.moveReference("codecut-reference|clip|\(clip.id)", to: "B"))
    #expect(library.document.tracks[0].clips[0].folder == "B")
    #expect(library.moveReference("codecut-reference|clip|\(clip.id)", to: ""))
    #expect(library.moveReference("codecut-reference|track|\(track.id)", to: "B", music: true))
    library.addFolder("仅音乐", music: true)
    #expect(!library.folders(music: false).contains("仅音乐"))
    #expect(library.moveReference("codecut-reference|folder|B", to: "仅音乐", music: true))
    #expect(library.document.tracks[0].folder == "仅音乐/B")
    #expect(library.folders(music: false).contains("B"))
    #expect(!library.moveReference("codecut-reference|clip|\(clip.id)", to: "仅音乐", music: true))
    #expect(!library.moveReference("codecut-reference|track|\(track.id)", to: "不存在"))
    let restored = MusicReferenceLibrary(root: root)
    #expect(restored.document.tracks[0].folder == "仅音乐/B")
    #expect(restored.document.tracks[0].clips[0].folder == nil)
    #expect(restored.document.tracks[0].clips[0].note == "不变的批注")
    #expect(restored.document.tracks[0].fileName == "source.mp3")
}

@MainActor @Test func musicReferenceDeleteOnlyLibraryCopiesAndRollback() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicDeleteTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let library = MusicReferenceLibrary(root: root.appending(path: "Library"))
    try fm.createDirectory(at: library.root.appending(path: "Audio"), withIntermediateDirectories: true)
    let original = MusicReferenceTrack(name: "原曲", fileName: "original.mp3", originalName: "source.mp3", duration: 30)
    let clip = MusicReferenceClip(title: "伴奏片段", start: 1, end: 4, note: "批注")
    let stem = MusicReferenceTrack(name: "去人声", fileName: "stem.mp3", originalName: "source.mp3", duration: 30, clips: [clip], sourceTrackID: original.id)
    library.document.tracks = [original, stem]
    try Data("source".utf8).write(to: root.appending(path: "source.mp3"))
    try Data("original".utf8).write(to: library.audioURL(original))
    try Data("stem".utf8).write(to: library.audioURL(stem))
    #expect(library.save())
    let excerpt = library.root.appending(path: "Clips/\(clip.id)/audio.m4a")
    try Data("excerpt".utf8).write(to: excerpt)
    library.deleteMusic(stem.id) { _ in throw CocoaError(.fileWriteNoPermission) }
    #expect(library.document.tracks.count == 2)
    #expect(fm.fileExists(atPath: library.audioURL(stem).path))
    #expect(fm.fileExists(atPath: excerpt.path))
    library.error = nil
    let trash = root.appending(path: "TestTrash")
    library.deleteMusic(stem.id) { url in try fm.moveItem(at: url, to: trash); return trash }
    #expect(library.error == nil)
    #expect(library.document.tracks.count == 1)
    #expect(!library.document.tracks.contains { $0.sourceTrackID == original.id })
    #expect(!fm.fileExists(atPath: library.audioURL(stem).path))
    #expect(!fm.fileExists(atPath: excerpt.path))
    #expect(fm.fileExists(atPath: trash.appending(path: "Audio/stem.mp3").path))
    #expect(fm.fileExists(atPath: trash.appending(path: "Clips/\(clip.id)/annotation.json").path))
    #expect(fm.fileExists(atPath: library.audioURL(original).path))
    #expect(try String(contentsOf: root.appending(path: "source.mp3"), encoding: .utf8) == "source")
    #expect(MusicReferenceLibrary(root: library.root).document.tracks.count == 1)
    library.isSeparating = true
    library.deleteMusic(original.id) { _ in throw CocoaError(.fileWriteUnknown) }
    #expect(library.document.tracks.count == 1)
    #expect(library.error == nil)
}

@Test func musicReferenceSeparationProgressReadsActualLog() {
    #expect(MusicReferenceNCM.separationPercentage(in: "Loading model...") == nil)
    #expect(MusicReferenceNCM.separationPercentage(in: "\r  0%|          | 0/29") == 0)
    #expect(MusicReferenceNCM.separationPercentage(in: "\r  3%|▎ | 1/29\r 55%|█████▌ | 16/29") == 55)
    #expect(MusicReferenceNCM.separationPercentage(in: "\r100%|██████████| 29/29") == 100)
    #expect(MusicReferenceNCM.separationPercentage(in: "101%|invalid") == nil)
    #expect(MusicReferenceNCM.separationPercentage(in: "memory 60%") == nil)
}

@MainActor @Test func musicReferenceNCMImportUsingAudioForge() async throws {
    guard let path = ProcessInfo.processInfo.environment["CODECUT_TEST_NCM"] else { return }
    let source = URL(fileURLWithPath: path)
    let original = try Data(contentsOf: source)
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicNCMTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    await library.importFiles([source])
    #expect(library.error == nil)
    let track = try #require(library.track)
    #expect(track.fileName.hasSuffix(".mp3"))
    #expect(track.originalName == source.lastPathComponent)
    #expect(track.duration > 0)
    let player = try AVAudioPlayer(contentsOf: library.audioURL(track))
    #expect(player.prepareToPlay())
    #expect(try Data(contentsOf: source) == original)
    let invalid = root.appending(path: "invalid.ncm")
    try Data("invalid container".utf8).write(to: invalid)
    await library.importFiles([invalid])
    #expect(library.document.tracks.count == 1)
    #expect(library.error != nil)
}

@Test func musicReferenceRejectsInvalidRanges() {
    #expect(MusicReferenceRules.validRange(start: 0, end: 2, duration: 2))
    #expect(!MusicReferenceRules.validRange(start: -1, end: 2, duration: 3))
    #expect(!MusicReferenceRules.validRange(start: 2, end: 1, duration: 3))
    #expect(!MusicReferenceRules.validRange(start: 0, end: 4, duration: 3))
    #expect(!MusicReferenceRules.validRange(start: .nan, end: 2, duration: 3))
    #expect(!MusicReferenceRules.validRange(start: 0, end: .infinity, duration: 3))
}

@Test func musicReferenceAnalysisRequiresUsefulTypedOutput() throws {
    let valid = Data(#"{"categories":["思考／探究","原理／功能解释"],"reason":"批注说明用于提问","evidence":"用户描述短音","suggestions":"建议少量打击乐","prompt":"Instrumental curious underscore.","avoid":"No vocals.","uncertainties":"配器未确认"}"#.utf8)
    let result = try MusicReferenceRules.decodeAnalysis(valid, input: "original input")
    #expect(result.categories.count == 2)
    #expect(result.input == "original input")
    let missing = Data(#"{"categories":["思考／探究"],"prompt":"hello"}"#.utf8)
    #expect(throws: (any Error).self) { try MusicReferenceRules.decodeAnalysis(missing, input: "") }
    let unknownCategory = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "思考／探究", with: "invented").utf8)
    #expect(throws: (any Error).self) { try MusicReferenceRules.decodeAnalysis(unknownCategory, input: "") }
}

@Test func musicReferenceChangedNotesOrRangeInvalidatePrompt() {
    var clip = MusicReferenceClip(title: "疑问", start: 1, end: 8, note: "适合提问")
    clip.analysis = .init(categories: ["思考／探究"], reason: "r", evidence: "e", suggestions: "s", prompt: "p", avoid: "a", uncertainties: "u", input: clip.input)
    #expect(!clip.isStale)
    clip.note = "适合下结论"
    #expect(clip.isStale)
    clip.note = "适合提问"
    clip.end = 9
    #expect(clip.isStale)
}

@MainActor @Test func musicReferenceMultipleClipsPersistAndRecoverBackup() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MusicReferenceTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = MusicReferenceLibrary(root: root)
    let track = MusicReferenceTrack(name: "参考", fileName: "test.wav", originalName: "参考.wav", duration: 60)
    library.document.tracks = [track]
    library.selectedTrackID = track.id
    library.setRange(start: 2, end: 10); library.saveClip()
    library.editClip { $0.note = "问题出现时用" }
    library.setRange(start: 22, end: 30); library.saveClip()
    library.editClip { $0.note = "落下一个结论" }
    #expect(library.save())
    let reopened = MusicReferenceLibrary(root: root)
    #expect(reopened.document.tracks[0].clips.count == 2)
    #expect(reopened.document.tracks[0].clips[0].note == "问题出现时用")
    #expect(reopened.document.tracks[0].clips[1].start == 22)
    try Data("corrupt".utf8).write(to: root.appending(path: "library.json"))
    let recovered = MusicReferenceLibrary(root: root)
    #expect(!recovered.readOnly)
    #expect(recovered.document.tracks[0].clips.count == 2)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "library.recovery.json").path))
    try Data("corrupt".utf8).write(to: root.appending(path: "library.json"))
    try Data("corrupt".utf8).write(to: root.appending(path: "library.backup.json"))
    let blocked = MusicReferenceLibrary(root: root)
    #expect(blocked.readOnly)
    #expect(!blocked.save())
    #expect(try String(contentsOf: root.appending(path: "library.json"), encoding: .utf8) == "corrupt")
}

@MainActor @Test func musicReferenceImportAndExportActualAudio() async throws {
    let fixturePath = ProcessInfo.processInfo.environment["CODECUT_MUSIC_QA_FIXTURE"]
    let root = fixturePath.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appending(path: "MusicReferenceAudioTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { if fixturePath == nil { try? FileManager.default.removeItem(at: root) } }
    let source = root.appending(path: "tone.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000))
    buffer.frameLength = 144000
    let channel = try #require(buffer.floatChannelData?[0])
    for i in 0..<144000 { channel[i] = Float(sin(Double(i) * 440 * 2 * .pi / 48000)) * 0.1 }
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }
    let library = MusicReferenceLibrary(root: root.appending(path: "Library"))
    await library.importFiles([source])
    let track = try #require(library.track)
    #expect(abs(track.duration - 3) < 0.03)
    // 移走原曲后，本机参考副本仍能用。
    try FileManager.default.moveItem(at: source, to: root.appending(path: "moved.wav"))
    #expect(FileManager.default.fileExists(atPath: library.audioURL(track).path))
    library.seek(0.5); library.markIn()
    library.seek(0.25); library.markOut()
    #expect(library.selectionEnd > library.selectionStart)
    library.seek(1.75); library.markOut()
    library.addFolder("数码/思考")
    await library.confirmClip()
    #expect(library.document.folders == ["数码", "数码/思考"])
    #expect(library.clip?.folder == "数码/思考")
    await library.confirmClip()
    #expect(library.track?.clips.count == 1)
    library.editClip { $0.note = "测试批注：提出疑问，短音重复，给口播留空间" }
    let clip = try #require(library.clip)
    #expect(FileManager.default.fileExists(atPath: library.root.appending(path: "Clips/\(clip.id)/audio.m4a").path))
    #expect(FileManager.default.fileExists(atPath: library.root.appending(path: "Clips/\(clip.id)/annotation.json").path))
    let destination = root.appending(path: "excerpt.m4a")
    try await MusicReferenceLibrary.exportAudio(source: library.audioURL(track), clip: clip, destination: destination)
    let exported = AVURLAsset(url: destination)
    let duration = try await exported.load(.duration).seconds
    #expect(abs(duration - 1.25) < 0.08)
    #expect(try await !exported.loadTracks(withMediaType: .audio).isEmpty)
    let waveform = try await AudioWaveform.samples(videoURL: library.audioURL(track), count: 100)
    #expect(waveform.count == 100)
    #expect(waveform.contains { $0 > 0 })
    if ProcessInfo.processInfo.environment["CODECUT_TEST_ESSENTIA"] == "1" {
        await library.readAudio()
        #expect(library.error == nil)
        #expect(library.clip?.currentAudioFeatures != nil)
        #expect(library.clip?.currentAudioFeatures?.metrics["bpm"] == nil)
        #expect(MusicReferenceLibrary(root: library.root).document.tracks[0].clips[0].audioFeatures != nil)
    }
    if ProcessInfo.processInfo.environment["CODECUT_TEST_SEPARATION"] == "1" {
        let originalAudio = try Data(contentsOf: library.audioURL(track))
        library.enqueueSeparation(track.id)
        await library.waitForSeparationQueue()
        #expect(library.error == nil)
        #expect(!library.isSeparating)
        #expect(library.separationPercent == 100)
        #expect(library.document.tracks.count == 2)
        let instrumental = try #require(library.document.tracks.first { $0.sourceTrackID == track.id })
        #expect(instrumental.sourceTrackID == track.id)
        #expect(abs(instrumental.duration - track.duration) < 1)
        #expect(try Data(contentsOf: library.audioURL(track)) == originalAudio)
        library.selectTrack(track.id)
        library.enqueueSeparation(track.id)
        await library.waitForSeparationQueue()
        #expect(library.document.tracks.count == 2)
        #expect(library.selectedTrackID == track.id)
    }
    let priorSetting = UserDefaults.standard.string(forKey: "musicReferenceRoot")
    defer {
        if let priorSetting { UserDefaults.standard.set(priorSetting, forKey: "musicReferenceRoot") }
        else { UserDefaults.standard.removeObject(forKey: "musicReferenceRoot") }
    }
    let oldRoot = library.root
    await library.relocate(to: root.appending(path: "Relocated"))
    #expect(library.root.path == root.appending(path: "Relocated").standardizedFileURL.resolvingSymlinksInPath().path)
    #expect(FileManager.default.fileExists(atPath: oldRoot.appending(path: "library.json").path))
    #expect(FileManager.default.fileExists(atPath: library.root.appending(path: "Clips/\(clip.id)/audio.m4a").path))
    let reloaded = MusicReferenceLibrary(root: library.root)
    #expect(reloaded.document.tracks.first?.clips.first?.note == clip.note)
    #expect(reloaded.document.tracks.first?.clips.first?.folder == "数码/思考")
    await library.relocate(to: oldRoot)
    #expect(library.error != nil)
}

@MainActor @Test func musicReferenceLiveLocalModel() async throws {
    guard ProcessInfo.processInfo.environment["CODECUT_TEST_MUSIC_MODEL"] == "1" else { return }
    let clip = MusicReferenceClip(title: "思考型", start: 5, end: 25,
                                  note: "像脑子在思考，适合数码评测提出疑问，一开始就出现，别太悬疑",
                                  sound: "短促木质敲击，重复两三个音，偶尔停一下",
                                  avoid: "不要人声，不要大鼓，不要恐怖感")
    let result = try await MusicReferenceLibrary.analyze(clip)
    #expect(result.categories.contains("思考／探究"))
    #expect(!result.prompt.isEmpty)
    #expect(!result.evidence.isEmpty)
    #expect(result.prompt.contains("20.0 seconds"))
    #expect(result.uncertainties.contains("未经验证"))
    #expect(result.input == clip.input)
    print("Music reference local model result: \(result)")
}
