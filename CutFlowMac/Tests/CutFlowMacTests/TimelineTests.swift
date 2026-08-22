import Foundation
import AVFoundation
import AppKit
import Testing

import WhisperKit
@testable import CutFlowMac

private func word(_ text: String, _ start: Double, _ end: Double, deleted: Bool = false) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end, isDeleted: deleted)
}

@MainActor @Test func whisperWordTimingSplitsIntoContinuousCharacters() {
    let result = WhisperTranscriber.characterTimings(from: [
        WordTiming(word: " 你好", tokens: [], start: 1, end: 1.8, probability: 0.9)
    ])
    #expect(result.map(\.text) == ["你", "好"])
    #expect(abs(result[0].start - 1) < 0.001)
    #expect(abs(result[0].end - result[1].start) < 0.001)
    #expect(abs(result[1].end - 1.8) < 0.001)
}

@MainActor @Test func whisperModelFolderRequiresAllThreeModels() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "whisper-model-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(!WhisperTranscriber.isCompleteModelFolder(folder))
    for name in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
        try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
    }
    #expect(WhisperTranscriber.isCompleteModelFolder(folder))
}

@Test func deletedRangesMergeAndComplement() {
    let words = [word("删一", 1, 2, deleted: true), word("删二", 2.03, 3, deleted: true), word("保留", 4, 5)]
    let deleted = TimelineEngine.deletedRanges(words: words, breaths: [])
    #expect(deleted.count == 1)
    #expect(abs(deleted[0].start - 0.95) < 0.001)
    #expect(abs(deleted[0].end - 3.05) < 0.001)
    let kept = TimelineEngine.complement(of: deleted, duration: 6)
    #expect(kept.count == 2)
    #expect(abs(kept.reduce(0) { $0 + $1.duration } - 3.9) < 0.001)
}

@Test func breathThresholdAndAutomaticDeletion() {
    let words = [word("前", 0, 1), word("短", 1.3, 2), word("后", 2.7, 3)]
    let breaths = TimelineEngine.detectBreaths(words: words, threshold: 0.45)
    #expect(breaths.count == 1)
    #expect(abs(breaths[0].duration - 0.7) < 0.001)
}

@Test func outputTimeSubtractsPriorCuts() {
    let deleted = [TimeRange(start: 1, end: 2), TimeRange(start: 4, end: 5.5)]
    #expect(TimelineEngine.outputTime(for: 0.5, deleted: deleted) == 0.5)
    #expect(TimelineEngine.outputTime(for: 3, deleted: deleted) == 2)
    #expect(TimelineEngine.outputTime(for: 6, deleted: deleted) == 3.5)
    let kept = TimelineEngine.complement(of: deleted, duration: 7)
    #expect(TimelineEngine.sourceTime(for: 2, kept: kept) == 3)
    #expect(TimelineEngine.sourceTime(for: 3.5, kept: kept) == 6)
}

@MainActor @Test func cleanupShortFragmentsCutsOnlyInternalIslandsAndCanUndo() {
    let model = EditorModel()
    model.duration = 4
    model.trimEnd = 4
    model.breaths = [
        BreathCandidate(start: 0.5, end: 1.5, leftText: "", rightText: "", state: .deleted),
        BreathCandidate(start: 1.8, end: 3.5, leftText: "", rightText: "", state: .deleted)
    ]
    #expect(model.shortFragments == [TimeRange(start: 1.5, end: 1.8)])
    model.cleanupShortFragments()
    #expect(model.shortFragments.isEmpty)
    #expect(model.keptRanges == [TimeRange(start: 0, end: 0.5), TimeRange(start: 3.5, end: 4)])
    model.undo()
    #expect(model.shortFragments == [TimeRange(start: 1.5, end: 1.8)])
}

@MainActor @Test func deletingBreathRipplesTimelineAndCanUndo() {
    let model = EditorModel()
    model.duration = 4
    model.trimEnd = 4
    let breath = BreathCandidate(start: 1, end: 2, leftText: "前", rightText: "后")
    model.breaths = [breath]
    model.decideBreath(breath.id, delete: true)
    #expect(model.outputDuration == 3)
    #expect(TimelineEngine.outputTime(for: 2, deleted: model.deletedRanges) == 1)
    model.undo()
    #expect(model.outputDuration == 4)
    #expect(model.breaths[0].state == .pending)
}

@Test func parsesOfficialMiMoASRResponse() throws {
    let data = Data(#"{"choices":[{"message":{"content":"你好世界"}}]}"#.utf8)
    #expect(try MiMoASRClient.parseText(data) == "你好世界")
}

@Test func rejectsASRWithoutText() {
    #expect(throws: (any Error).self) { try MiMoASRClient.parseText(Data(#"{"choices":[]}"#.utf8)) }
}

@Test func exportsEscapedSRTAndFCPXML() {
    let words = [word("A&B", 0, 1), word("删除", 1, 2, deleted: true), word("结尾", 2, 3)]
    let deleted = TimelineEngine.deletedRanges(words: words, breaths: [])
    let edl = EditDecisionList(sourcePath: "/tmp/a&b.mov", sourceDuration: 3, frameRate: 25, deletedRanges: deleted, keptRanges: TimelineEngine.complement(of: deleted, duration: 3), words: words, suggestions: [], breaths: [])
    let srt = TimelineExporter.srt(edl)
    #expect(srt.contains("A&B")); #expect(!srt.contains("删除")); #expect(srt.contains("00:00:00,950"))
    let xml = TimelineExporter.fcpxml(edl, name: "A&B")
    #expect(xml.contains("A&amp;B")); #expect(xml.contains("fcpxml")); #expect(xml.contains("asset-clip"))
}

@Test func exportsResolveCMX3600TimelineWithSourceAndRecordTimecodes() {
    let edl = EditDecisionList(sourcePath: "/tmp/source.mov", sourceDuration: 8, frameRate: 25, deletedRanges: [.init(start: 2, end: 4)], keptRanges: [.init(start: 0, end: 2), .init(start: 4, end: 8)], words: [], suggestions: [], breaths: [])
    let text = TimelineExporter.cmx3600(edl, name: "测试")
    #expect(text.contains("TITLE: 测试"))
    #expect(text.contains("001  AX       V     C"))
    #expect(text.contains("002  AX       A     C"))
    #expect(text.components(separatedBy: "00:00:04:00 00:00:08:00 00:00:02:00 00:00:06:00").count == 3)
    #expect(text.contains("00:00:04:00 00:00:08:00 00:00:02:00 00:00:06:00"))
    #expect(text.contains("* FROM CLIP NAME: source.mov"))
}

@Test func storyboardParserMapsCueIndexesBackToStableWordIDs() throws {
    let first = SubtitleCue(text: "租房空间", start: 1, end: 5, wordIDs: [UUID(), UUID()])
    let second = SubtitleCue(text: "需要灵活布置", start: 5, end: 10, wordIDs: [UUID(), UUID()])
    let raw = #"{"items":[{"startIndex":0,"endIndex":1,"type":"MG 动画","description":"平面户型缩放","composition":"俯视","movement":"缓慢推进","elements":"户型线框","notes":"蓝白配色"}]}"#
    let items = try MiMoClient.parseStoryboards(raw, cues: [first, second])
    #expect(items.count == 1)
    #expect(items[0].kind == .motionGraphics)
    #expect(items[0].wordIDs == first.wordIDs + second.wordIDs)
    #expect(items[0].fallbackStart == 1)
    #expect(items[0].fallbackEnd == 10)
}

@MainActor @Test func storyboardMagnetShrinksThenDeletesWithAnchoredSpeechAndCanUndo() {
    let a = word("前", 0, 1), b = word("中", 1, 2), c = word("后", 2, 3)
    let item = StoryboardItem(kind: .liveAction, wordIDs: [a.id, b.id], fallbackStart: 0, fallbackEnd: 2, description: "房间空镜", composition: "广角", cameraMovement: "推进", elements: "房间", notes: "")
    let model = EditorModel(); model.duration = 3; model.trimEnd = 3; model.words = [a, b, c]; model.storyboards = [item]
    model.deleteWords([a.id])
    #expect(model.storyboards[0].wordIDs == [b.id])
    #expect(model.storyboardSourceRange(model.storyboards[0]) == TimeRange(start: 1, end: 2))
    model.deleteWords([b.id])
    #expect(model.storyboards.isEmpty)
    model.undo()
    #expect(model.storyboards.count == 1)
    #expect(model.storyboards[0].wordIDs == [b.id])
}

@MainActor @Test func storyboardRebindsAfterRecognitionAndKeepsUnmatchedTimeAnchor() {
    let oldWord = word("旧", 1, 2)
    let reboundID = UUID(), fallbackID = UUID()
    let rebound = StoryboardItem(id: reboundID, kind: .liveAction, wordIDs: [oldWord.id], fallbackStart: 1, fallbackEnd: 2, description: "重绑", composition: "", cameraMovement: "", elements: "", notes: "")
    let fallback = StoryboardItem(id: fallbackID, kind: .motionGraphics, wordIDs: [], fallbackStart: 5, fallbackEnd: 6, description: "时间锚点", composition: "", cameraMovement: "", elements: "", notes: "")
    let newWord = word("新", 1.1, 1.9)
    let model = EditorModel(); model.duration = 10; model.trimEnd = 10; model.words = [newWord]; model.storyboards = [rebound, fallback]

    model.rebindStoryboards(using: [(reboundID, .init(start: 1, end: 2)), (fallbackID, .init(start: 5, end: 6))])
    #expect(model.storyboards.first(where: { $0.id == reboundID })?.wordIDs == [newWord.id])
    #expect(model.storyboards.first(where: { $0.id == fallbackID })?.wordIDs.isEmpty == true)

    model.deleteWords([newWord.id])
    #expect(!model.storyboards.contains(where: { $0.id == reboundID }))
    #expect(model.storyboards.contains(where: { $0.id == fallbackID }))
}

@Test func storyboardCSVUsesEditedTimelineAndEscapesChineseProductionFields() {
    let id = UUID()
    let word = TranscriptWord(id: id, text: "亮度,更高", start: 4, end: 6)
    let item = StoryboardItem(kind: .motionGraphics, wordIDs: [id], fallbackStart: 4, fallbackEnd: 6, description: "数值“850”放大", composition: "居中", cameraMovement: "无", elements: "数字,箭头", notes: "")
    let edl = EditDecisionList(sourcePath: "/tmp/a.mov", sourceDuration: 6, frameRate: 25, deletedRanges: [.init(start: 0, end: 2)], keptRanges: [.init(start: 2, end: 6)], words: [word], suggestions: [], breaths: [])
    let csv = TimelineExporter.storyboardCSV([item], edl: edl)
    #expect(csv.contains("00:00:02.0 - 00:00:04.0"))
    #expect(csv.contains("\"亮度更高\""))
    #expect(csv.contains("\"数字,箭头\""))
}

@Test func detailedStoryboardPromptInputContainsTimingAndAnimationDirection() {
    let item = StoryboardItem(kind: .motionGraphics, wordIDs: [], fallbackStart: 1, fallbackEnd: 4.5, description: "数字放大", composition: "居中", cameraMovement: "缓慢推进", elements: "850、箭头、参数卡片", notes: "蓝色科技风")
    let input = MiMoClient.storyboardPromptInput(item: item, subtitle: "亮度达到850流明", duration: 3.5)
    #expect(input.contains("3.50 秒"))
    #expect(input.contains("亮度达到850流明"))
    #expect(input.contains("850、箭头、参数卡片"))
    #expect(input.contains("缓慢推进"))
}

@Test func projectRoundTripDoesNotContainAPIKey() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "cutflow-test-\(UUID()).cutflow")
    defer { try? FileManager.default.removeItem(at: url) }
    let document = ProjectDocument(name: "测试", sourcePath: "/tmp/a.mov", transcript: .init(assetID: "a", duration: 1, words: [word("好", 0, 1)]), suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25)
    try ProjectStore.save(document, to: url)
    #expect(try ProjectStore.load(from: url).name == "测试")
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("apiKey"))
}

@Test func correctionParserKeepsOnlyExistingWordIDs() throws {
    let valid = UUID()
    let unknown = UUID()
    let raw = #"{"corrections":[{"id":"\#(valid.uuidString)","text":"大眼橙"},{"id":"\#(unknown.uuidString)","text":"不能加入"}]}"#
    let corrections = try MiMoClient.parseCorrections(raw, validIDs: [valid])
    #expect(corrections == [valid: "大眼橙"])
}

@Test func indexedCorrectionParserMapsShortIDsAndDropsUnchangedText() throws {
    let words = [word("大", 0, 0.1), word("眼", 0.1, 0.2), word("尘", 0.2, 0.3)]
    let raw = #"{"corrections":[{"id":"0","text":" "},{"id":"1","text":"眼"},{"id":"2","text":"橙"},{"id":"99","text":"错"}]}"#
    let result = try MiMoClient.parseIndexedCorrections(raw, words: words)
    #expect(result == [words[2].id: "橙"])
}

@Test func lineCorrectionParserKeepsSubtitleRowsAndMapsBackToWordIDs() throws {
    let first = [word("大", 0, 0.1), word("眼", 0.1, 0.2), word("尘", 0.2, 0.3)]
    let second = [word("不", 0.3, 0.4), word("改", 0.4, 0.5)]
    let raw = #"{"lines":[{"id":0,"text":"大眼橙"}]}"#
    let result = try MiMoClient.parseLineCorrections(raw, lines: [first, second])
    #expect(result == [first[2].id: "橙"])
    #expect(result.keys.allSatisfy { first.map(\.id).contains($0) })
}

@Test func lineCorrectionParserRejectsDeletedTextInsteadOfCollapsingUUIDs() throws {
    let line = [word("保", 0, 0.1), word("留", 0.1, 0.2), word("我", 0.2, 0.3)]
    let raw = #"{"lines":[{"id":0,"text":"保留"}]}"#
    #expect(try MiMoClient.parseLineCorrections(raw, lines: [line]).isEmpty)
}

@Test func estimatesWordsInsideAudioChunk() {
    let words = MiMoASRClient.estimatedWords(text: "你好，世界。", start: 60, duration: 10)
    #expect(words.map(\.text).joined() == "你好，世界。")
    #expect(words.map(\.text) == ["你", "好", "，", "世", "界", "。"])
    #expect(words.contains { $0.text.contains("，") })
    #expect(words.first?.start == 60)
    #expect(words.last?.end == 70)
}

@Test func overlappingASRChunksMergeRepeatedBoundaryText() {
    let first = MiMoASRClient.estimatedWords(text: "不知道大家有没有这样的感觉，当你开始租房", start: 0, duration: 8)
    let second = MiMoASRClient.estimatedWords(text: "当你开始租房之后，就会发现以前很多东西", start: 6, duration: 8)
    let merged = MiMoASRClient.mergeOverlappingChunks([first, second])
    #expect(merged.map(\.text).joined() == "不知道大家有没有这样的感觉，当你开始租房之后，就会发现以前很多东西")
    #expect(merged.filter { $0.text == "当" }.count == 1)
}

@MainActor @Test func returnSplitsSubtitleAtCharacterTimestampAndCanUndo() {
    let model = EditorModel()
    model.words = [
        word("今", 10, 10.1), word("天", 10.1, 10.4), word("天", 10.4, 11.2),
        word("气", 11.2, 11.3), word("很", 11.3, 12.7), word("好", 12.7, 13)
    ]
    let cue = model.subtitleCues[0]
    let originalIDs = model.words.map(\.id)
    let originalTimes = model.words.map { ($0.start, $0.end) }
    let expectedTime = model.words[3].start
    model.splitSubtitle(cue, text: cue.text, atCharacterOffset: 3)
    #expect(model.subtitleCues.map(\.text) == ["今天天", "气很好"])
    #expect(abs(model.subtitleCues[1].start - expectedTime) < 0.001)
    #expect(model.words.map(\.id) == originalIDs)
    #expect(model.words.indices.allSatisfy { model.words[$0].start == originalTimes[$0].0 && model.words[$0].end == originalTimes[$0].1 })
    model.undo()
    #expect(model.subtitleCues.count == 1)
}

@Test func subtitleCuesPreferPunctuationAndUseLengthFallback() {
    let punctuated = [word("大家好，", 0, 1), word("欢迎回来。", 1, 2), word("下一句！", 2, 3)]
    let cues = TimelineEngine.subtitleCues(words: punctuated)
    #expect(cues.map(\.text) == ["大家好", "欢迎回来", "下一句！"])
    let enumeration = [word("吃饭、", 0, 1), word("工作、", 1, 2), word("休息都在这里。", 2, 3)]
    #expect(TimelineEngine.subtitleCues(words: enumeration).map(\.text) == ["吃饭、工作、休息都在这里"])
    let natural = ["当", "你", "开始", "租房", "之后，", "就", "会", "发现", "以前", "很多", "东西。"].enumerated().map { word($0.element, Double($0.offset) * 0.4, Double($0.offset + 1) * 0.4) }
    #expect(TimelineEngine.subtitleCues(words: natural).map(\.text) == ["当你开始租房之后", "就会发现以前很多东西"])
    let paused = [word("前半句", 0, 1), word("后半句", 2.1, 2.9)]
    #expect(TimelineEngine.subtitleCues(words: paused).map(\.text) == ["前半句", "后半句"])
    let fallback = (0..<10).map { word("测试", Double($0), Double($0 + 1)) }
    #expect(TimelineEngine.subtitleCues(words: fallback, maxCharacters: 18, maxDuration: 5).allSatisfy { $0.text.count <= 18 && $0.end - $0.start <= 5 })
}

@Test func generatedSubtitleIDsStayStableForScrollTargets() {
    let words = [word("第一句，", 0, 1), word("第二句。", 1, 2)]
    let firstPass = TimelineEngine.subtitleCues(words: words)
    let secondPass = TimelineEngine.subtitleCues(words: words)
    #expect(firstPass.map(\.id) == secondPass.map(\.id))
    #expect(firstPass.map(\.id) == firstPass.compactMap { $0.wordIDs.first })
}

@Test func modelBoundariesOverrideLocalPauseLengthAndPunctuationSplits() {
    let words = [
        word("这也是", 0, 0.4),
        word("为什么我觉得投影仪一直是租房党提升幸福感非常明显的一个产品。", 1.5, 10),
        word("就是", 12, 12.4),
        word("花一个容易接受的价格", 14, 22)
    ]
    let breakID = words[2].id
    let joins = Set(words.map(\.id)).subtracting([breakID])
    #expect(TimelineEngine.subtitleCues(words: words, breakBefore: [breakID], joinBefore: joins).map(\.text) == [
        "这也是为什么我觉得投影仪一直是租房党提升幸福感非常明显的一个产品",
        "就是花一个容易接受的价格"
    ])
}

@MainActor @Test func modelCannotCollapsePunctuatedArticleIntoOneSubtitle() {
    let model = EditorModel()
    model.words = [
        word("第一句，", 0, 1),
        word("第二句。", 1, 2),
        word("吃饭、工作都在这里。", 2, 3)
    ]
    let activeWords = model.words
    let breaks = TimelineEngine.mandatorySentenceBreaks(in: activeWords)
    model.subtitleBreaks = breaks
    model.subtitleJoins = Set(activeWords.map(\.id)).subtracting(breaks)
    #expect(model.subtitleCues.map(\.text) == ["第一句", "第二句", "吃饭、工作都在这里"])
}

@Test func matureSubtitleBoundariesMergeReportedHalfSentenceFragments() {
    let words = [
        word("这也是，", 0, 0.2),
        word("为什么我觉得投影仪一直是租房党提升幸福感非常明显的一个产品。", 0.2, 9),
        word("就是，", 9, 9.3),
        word("所以我买了大眼橙的C3D。", 9.3, 12),
        word("它解决了这样一个问题，", 12, 14),
        word("就是花一，", 14, 14.8),
        word("个容易接受的，", 14.8, 15.6),
        word("价格。", 15.6, 16)
    ]
    let proposed = TimelineEngine.mandatorySentenceBreaks(in: words)
    let refined = TimelineEngine.refinedSentenceBreaks(proposed, in: words)
    let joins = Set(words.map(\.id)).subtracting(refined)
    #expect(TimelineEngine.subtitleCues(words: words, breakBefore: refined, joinBefore: joins).map(\.text) == [
        "这也是为什么我觉得投影仪一直是租房党提升幸福感非常明显的一个产品",
        "就是所以我买了大眼橙的C3D",
        "它解决了这样一个问题",
        "就是花一个容易接受的价格"
    ])
}

@Test func matureSubtitleBoundariesHandleRealTranscriptPunctuationAndNumberArtifacts() {
    let words = [
        word("在参数层面，", 0, 1), word(",", 1, 1.1), word("大眼橙C3D用了自研全封闭光机。", 1.1, 4),
        word("但说实话，", 4, 4.5), word(",", 4.5, 4.6), word("单看这个数字大家没概念。", 4.6, 7),
        word("舒服地看一块10，", 7, 8), word("0寸的大屏。", 8, 9)
    ]
    let proposed = TimelineEngine.mandatorySentenceBreaks(in: words)
    let refined = TimelineEngine.refinedSentenceBreaks(proposed, in: words)
    let joins = Set(words.map(\.id)).subtracting(refined)
    #expect(TimelineEngine.subtitleCues(words: words, breakBefore: refined, joinBefore: joins).map(\.text) == [
        "在参数层面大眼橙C3D用了自研全封闭光机",
        "但说实话单看这个数字大家没概念",
        "舒服地看一块100寸的大屏"
    ])
}

@Test func matureSubtitleBoundariesBalanceLongCuesWithoutCreatingTinyRows() {
    let words = [
        word("所以后来我发现，", 0, 3),
        word("对于租房党来说，", 3, 7),
        word("与其是电视投影的价值其实更高用更低的成本。", 7, 25)
    ]
    let candidates = TimelineEngine.mandatorySentenceBreaks(in: words)
    let refined = TimelineEngine.refinedSentenceBreaks(candidates, in: words)
    let balanced = TimelineEngine.balancedSentenceBreaks(refined, candidates: candidates, in: words)
    let joins = Set(words.map(\.id)).subtracting(balanced)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: balanced, joinBefore: joins)
    #expect(cues.map(\.text) == ["所以后来我发现对于租房党来说", "与其是电视投影的价值其实更高用更低的成本"])
    #expect(cues.allSatisfy { $0.text.filter { !$0.isPunctuation && !$0.isWhitespace }.count >= 6 })
}

@Test func matureSubtitleBoundariesSplitLongClausesAtGrammarPauses() {
    let words = [
        word("当你开始租房之后，", 0, 2),
        word("就会发现，", 2, 3),
        word("以前很多觉得理所当然的东西。", 3, 7),
        word("比如说电视，", 7, 8),
        word("以前觉得一个完整的家就应该有个大沙发。", 8, 13)
    ]
    let candidates = TimelineEngine.mandatorySentenceBreaks(in: words)
    let refined = TimelineEngine.refinedSentenceBreaks(candidates, in: words)
    let breaks = TimelineEngine.balancedSentenceBreaks(refined, candidates: candidates, in: words)
    let joins = Set(words.map(\.id)).subtracting(breaks)
    #expect(TimelineEngine.subtitleCues(words: words, breakBefore: breaks, joinBefore: joins).map(\.text) == [
        "当你开始租房之后就会发现",
        "以前很多觉得理所当然的东西",
        "比如说电视",
        "以前觉得一个完整的家就应该有个大沙发"
    ])
}

@Test func subtitleOutputJoinsCharacterLevelASCIIWithoutChangingSourceWords() {
    let words = [
        word("舒服地看一块", 0, 1), word("1", 1, 1.1), word("0", 1.1, 1.2), word("0", 1.2, 1.3), word("寸的大屏。", 1.3, 2),
        word("极米", 2, 2.2), word("P", 2.2, 2.3), word("l", 2.3, 2.4), word("a", 2.4, 2.5), word("y", 2.5, 2.6), word("6", 2.6, 2.7),
        word("大眼橙", 3.7, 3.9), word("C", 3.9, 4), word("3", 4, 4.1), word("D", 4.1, 4.2)
    ]
    let original = words.map(\.text)
    #expect(TimelineEngine.subtitleCues(words: words).map(\.text) == ["舒服地看一块100寸的大屏", "极米Play6", "大眼橙C3D"])
    #expect(words.map(\.text) == original)
}

@Test func matureSubtitleBoundariesUseSemanticFallbackOnlyForUnpunctuatedLongCue() {
    let text = "所以投影仪最有价值的地方从来不是它替代一台电视而是它用一个更低的成本让一个普通的出租屋更温馨一点"
    let words = Array(text).enumerated().map { index, character in word(String(character), Double(index) * 0.25, Double(index + 1) * 0.25) }
    let semanticCandidates = Set(TimelineEngine.subtitleCues(words: words).dropFirst().compactMap(\.wordIDs.first))
    let breaks = TimelineEngine.balancedSentenceBreaks([], candidates: semanticCandidates, in: words)
    let joins = Set(words.map(\.id)).subtracting(breaks)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: breaks, joinBefore: joins)
    #expect(cues.count > 1)
    #expect(cues.allSatisfy { $0.text.count >= 6 && $0.text.count <= 28 })
    for pair in zip(cues, cues.dropFirst()) {
        #expect(!(pair.0.text.hasSuffix("出租") && pair.1.text.hasPrefix("屋")))
    }
}

@Test func matureSubtitleBoundariesSplitSlowSpeechUsingSafeSemanticCandidates() {
    let text = "与其是电视投影的价值其实更高用更低的成本"
    let words = Array(text).enumerated().map { index, character in word(String(character), Double(index) * 1.15, Double(index + 1) * 1.15) }
    let semanticCandidates = Set(TimelineEngine.subtitleCues(words: words).dropFirst().compactMap(\.wordIDs.first))
    let breaks = TimelineEngine.balancedSentenceBreaks([], candidates: semanticCandidates, in: words)
    let joins = Set(words.map(\.id)).subtracting(breaks)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: breaks, joinBefore: joins)
    #expect(cues.count > 1)
    #expect(cues.allSatisfy { $0.text.count >= 6 })
    #expect(cues.allSatisfy { $0.end - $0.start <= 12 })
}

@Test func subtitleOutputCleansTranscriptPunctuationArtifactsWithoutChangingWords() {
    let words = [
        word("你会看到这样有一，层白白的。", 0, 2),
        word("那是因为做到了3000::1的对比度。", 2, 4),
        word("暗，部能够很容易压下来。", 4, 6),
        word("标准、鲜艳、柔和。", 6, 8)
    ]
    let originalText = words.map(\.text)
    #expect(TimelineEngine.subtitleCues(words: words).map(\.text) == [
        "你会看到这样有一层白白的",
        "那是因为做到了3000:1的对比度",
        "暗部能够很容易压下来",
        "标准、鲜艳、柔和"
    ])
    #expect(words.map(\.text) == originalText)
}

@Test func subtitleCuesPreferSemanticAndChineseWordBoundaries() {
    func characters(_ text: String) -> [TranscriptWord] {
        Array(text).enumerated().map { index, value in word(String(value), Double(index) * 0.2, Double(index + 1) * 0.2) }
    }
    let semantic = TimelineEngine.subtitleCues(words: characters("不知道大家有没有这样的感觉啊当你开始租房之后我就会发现"))
    #expect(semantic.first?.text == "不知道大家有没有这样的感觉啊")
    #expect(semantic.dropFirst().first?.text.hasPrefix("当你开始租房") == true)

    let lexical = TimelineEngine.subtitleCues(words: characters("所以后来我发现对于租房党来说与其是电视会成为一个负担"))
    for pair in zip(lexical, lexical.dropFirst()) {
        #expect(!(pair.0.text.hasSuffix("电") && pair.1.text.hasPrefix("视")))
    }
}

@Test func subtitleCuesKeepNaturalChineseClausesTogether() {
    func characters(_ text: String) -> [TranscriptWord] {
        Array(text).enumerated().map { index, value in word(String(value), Double(index) * 0.12, Double(index + 1) * 0.12) }
    }
    let text = "所以投影仪最有价值的地方从来不是它替代一台电视而是它用一个更低的成本让一个普通的出租屋更温馨一点更多一点家的感觉。"
    let cues = TimelineEngine.subtitleCues(words: characters(text))
    #expect(cues.map(\.text) == ["所以投影仪最有价值的地方", "从来不是它替代一台电视", "而是它用一个更低的成本", "让一个普通的出租屋更温馨一点", "更多一点家的感觉"])

    let connector = [word("所以", 0, 0.4), word("这是最后的结论。", 1.2, 2)]
    #expect(TimelineEngine.subtitleCues(words: connector).map(\.text) == ["所以这是最后的结论"])
}

@MainActor @Test func resegmentUsesCurrentWordsAndClearsManualBoundaries() {
    let model = EditorModel()
    model.videoURL = URL(fileURLWithPath: "/tmp/example.mov")
    model.words = [word("所以", 0, 0.4), word("这是结论。", 0.4, 1)]
    model.subtitleBreaks = [model.words[1].id]
    model.resegment()
    #expect(model.subtitleBreaks.isEmpty)
    #expect(model.subtitleCues.map(\.text) == ["所以这是结论"])
}

@Test func subtitleCuesMatchReportedNaturalClauseCases() {
    func characters(_ text: String) -> [TranscriptWord] {
        Array(text).enumerated().map { index, value in word(String(value), Double(index) * 0.2, Double(index + 1) * 0.2) }
    }
    #expect(TimelineEngine.subtitleCues(words: characters("当你开始租房之后就会发现以前很多觉得理所当然的东西")).map(\.text) == ["当你开始租房之后就会发现", "以前很多觉得理所当然的东西"])
    #expect(TimelineEngine.subtitleCues(words: characters("很多时候卧室就是客厅吃饭工作休息可能都在一个空间里")).map(\.text) == ["很多时候卧室就是客厅", "吃饭工作休息可能都在一个空间里"])
    #expect(TimelineEngine.subtitleCues(words: characters("而且如果想买一台大尺寸电视价格上去的不说还需要考虑电视柜安装搬家的问题")).map(\.text) == ["而且如果想买一台大尺寸电视", "价格上去的不说", "还需要考虑电视柜安装搬家的问题"])
    #expect(TimelineEngine.subtitleCues(words: characters("尤其是很多便宜的投影一打开就是灰蒙蒙的一片")).map(\.text) == ["尤其是很多便宜的投影", "一打开就是灰蒙蒙的一片"])
    #expect(TimelineEngine.subtitleCues(words: characters("这个投影仪用的电机还有亮度有关在参数层面")).map(\.text) == ["这个投影仪用的电机还有亮度有关", "在参数层面"])
}

@Test func subtitleCuesPreferLongCompleteMeaningOverShortVisualLines() {
    let text = "这是一句稍微长一点语义完整并且不应该从中间乱切的字幕内容"
    let words = Array(text).enumerated().map { index, value in word(String(value), Double(index) * 0.15, Double(index + 1) * 0.15) }
    #expect(TimelineEngine.subtitleCues(words: words).map(\.text) == [text])

    let shortPause = [word("理所当然的", 0, 1), word("东西", 1.7, 2.4)]
    #expect(TimelineEngine.subtitleCues(words: shortPause).map(\.text) == ["理所当然的东西"])
}

@Test func subtitleCuesUseNaturalSpeechPausesInsteadOfFixedWidthWrapping() {
    let phrases = ["没错啊镜头前面这个拿着相机走着红毯的人就是我", "事情还要从两天前开始说起", "那时我刚落地中山"]
    var words: [TranscriptWord] = [], cursor = 0.0
    for (phraseIndex, phrase) in phrases.enumerated() {
        for character in phrase {
            words.append(word(String(character), cursor, cursor + 0.1))
            cursor += 0.1
        }
        if phraseIndex < phrases.count - 1 { cursor += 0.48 }
    }
    #expect(TimelineEngine.subtitleCues(words: words).map(\.text) == phrases)
}

@Test func refinementRejectsMechanicalBreakInsideAWord() {
    let text = "没错啊镜头前面这个拿着相机走着红毯的人就是我事情还要从两天前开始说起"
    let words = Array(text).enumerated().map { index, character in word(String(character), Double(index) * 0.1, Double(index + 1) * 0.1) }
    let splitAt = text.firstRange(of: "天前")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: splitAt)
    let refined = TimelineEngine.refinedSentenceBreaks([words[offset].id], in: words)
    #expect(refined.isEmpty)
}

@Test func mimoSegmentationOnlyChangesLinesAndMapsThemBackToUUIDs() {
    let words = Array("所以，投影仪更有价值。").enumerated().map { index, value in word(String(value), Double(index), Double(index + 1)) }
    let result = TimelineEngine.applySegmentedArticle("所以，投影仪更有价值。\n", to: words)
    #expect(result != nil)
    #expect(result?.words.map(\.id) == words.map(\.id))
    #expect(result?.words.map(\.text).joined() == words.map(\.text).joined())

    let split = TimelineEngine.applySegmentedArticle("所以，\n投影仪更有价值。", to: words)
    #expect(split?.breaks == [words[3].id])
    let misplacedBeforeComma = TimelineEngine.applySegmentedArticle("所以\n，投影仪更有价值。", to: words)
    #expect(misplacedBeforeComma?.breaks == [words[3].id])
    #expect(TimelineEngine.applySegmentedArticle("所以，\n电视更有价值。", to: words) == nil)
}

@Test func parsesSegmentationBreakIndexesWithoutAcceptingChangedText() throws {
    #expect(try MiMoClient.parseSegmentationBreakIndexes(#"{"break_before":[5,2,5]}"#, wordCount: 8) == [2, 5])
    #expect(throws: (any Error).self) {
        try MiMoClient.parseSegmentationBreakIndexes(#"{"article":"被改写的原文"}"#, wordCount: 8)
    }
    #expect(throws: (any Error).self) {
        try MiMoClient.parseSegmentationBreakIndexes(#"{"break_before":[0,8]}"#, wordCount: 8)
    }
}

@Test func subtitleCuesNeverEmitBlankPunctuationRows() {
    let first = word("你好", 0, 1)
    let comma = word("，", 1, 1.1)
    let last = word("世界。", 1.1, 2)
    let cues = TimelineEngine.subtitleCues(words: [first, comma, last], breakBefore: [comma.id])
    #expect(cues.map(\.text) == ["你好", "世界"]) 
    #expect(cues[0].wordIDs == [first.id, comma.id])
    #expect(cues.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
}

@Test func restoresWhitespaceCorruptionFromOriginalTranscriptCache() {
    let original = word(",", 1, 1.1)
    var damaged = original
    damaged.text = " "
    let result = TimelineEngine.restoringBlankWords([damaged], from: [original])
    #expect(result.count == 1)
    #expect(result.words[0].text == ",")
}

@Test func repetitionScanKeepsLatestMatchingClause() {
    let early = SubtitleCue(text: "这个房间采光特别好，", start: 1, end: 3, wordIDs: [UUID()])
    let middle = SubtitleCue(text: "我们再来一遍，", start: 4, end: 5, wordIDs: [UUID()])
    let latest = SubtitleCue(text: "这个房间采光特别好，", start: 8, end: 10, wordIDs: [UUID()])
    let suggestions = TimelineEngine.repetitionSuggestions(cues: [early, middle, latest])
    #expect(suggestions.count == 1)
    #expect(suggestions[0].wordIDs == early.wordIDs)
    #expect(suggestions[0].retainedWordIDs == latest.wordIDs)
    #expect(suggestions[0].type == .repetition)
}

@Test func repetitionScanFindsSimilarDeliveryWithoutConfusingSameTopic() {
    let repeated = SubtitleCue(text: "不说还需要考虑电视柜安装搬家的问题", start: 1, end: 4, wordIDs: [UUID()])
    let unrelated = SubtitleCue(text: "电视的亮度通常比投影仪更高", start: 5, end: 8, wordIDs: [UUID()])
    let latest = SubtitleCue(text: "还需要考虑电视柜安装搬家的问题", start: 9, end: 12, wordIDs: [UUID()])
    let suggestions = TimelineEngine.repetitionSuggestions(cues: [repeated, unrelated, latest])
    #expect(suggestions.map(\.wordIDs) == [repeated.wordIDs])
}

@Test func repetitionScanCombinesNearbyFragmentsAndUsesManuscriptContext() {
    let fragment1 = SubtitleCue(text: "传统投影", start: 10, end: 11, wordIDs: [UUID()])
    let fragment2 = SubtitleCue(text: "很多时候就是一个工具", start: 11.2, end: 13, wordIDs: [UUID()])
    let latest = SubtitleCue(text: "因为传统投影很多时候就是一个工具嘛", start: 28, end: 31, wordIDs: [UUID()])
    let suggestions = TimelineEngine.repetitionSuggestions(cues: [fragment1, fragment2, latest], manuscript: "传统投影很多时候就是一个工具")
    #expect(suggestions.count == 1)
    #expect(Set(suggestions[0].wordIDs) == Set(fragment1.wordIDs + fragment2.wordIDs))
    #expect(suggestions[0].retainedWordIDs == latest.wordIDs)
}

@Test func repetitionScanFindsShortAdjacentRestart() {
    let first = SubtitleCue(text: "尤其是", start: 20, end: 21, wordIDs: [UUID()])
    let latest = SubtitleCue(text: "尤其是", start: 23, end: 24, wordIDs: [UUID()])
    let suggestions = TimelineEngine.repetitionSuggestions(cues: [first, latest])
    #expect(suggestions.map(\.wordIDs) == [first.wordIDs])
}

@Test func repetitionScanPrefersNearbyCompletionAndIgnoresDistantGenericPhrase() {
    let distant = SubtitleCue(text: "可以明显地看到", start: 170.8, end: 172, wordIDs: [UUID()])
    let restart = SubtitleCue(text: "可以明显地看到在头", start: 207, end: 208.5, wordIDs: [UUID()])
    let completed = SubtitleCue(text: "可以明显地看到在几米投放的画面区域外部", start: 209.5, end: 212, wordIDs: [UUID()])
    let suggestions = TimelineEngine.repetitionSuggestions(cues: [distant, restart, completed])
    #expect(suggestions.count == 1)
    #expect(suggestions.first?.wordIDs == restart.wordIDs)
    #expect(suggestions.first?.retainedWordIDs == completed.wordIDs)
}

@MainActor @Test func timelineSelectionDeleteCanUndo() {
    let first = word("第一句。", 0, 1)
    let second = word("第二句。", 1, 2)
    let model = EditorModel()
    model.words = [first, second]
    model.deleteWords([first.id])
    #expect(model.words[0].isDeleted)
    #expect(!model.words[1].isDeleted)
    model.undo()
    #expect(!model.words[0].isDeleted)
}

@Test func deepSeekSettingsDisableThinkingForStructuredTextTasks() {
    let settings = MiMoSettings(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash", asrModel: "", asrPath: "", apiKey: "secret", provider: "deepseek")
    let body = settings.requestBody(["model": settings.model])
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    #expect(settings.serviceName == "DeepSeek")
}

@Test func deepSeekSegmentationAcceptsFencedBreakIndexJSON() throws {
    let raw = """
    ```json
    {"break_before":[18,7,18]}
    ```
    """
    #expect(try MiMoClient.parseSegmentationBreakIndexes(raw, wordCount: 30) == [7, 18])
}

@MainActor @Test func deletingSubtitleDoesNotCutMediaAndCanUndo() {
    let first = word("第一句", 0, 1)
    let second = word("第二句", 1, 2)
    let model = EditorModel()
    model.words = [first, second]
    model.deleteSubtitles([first.id])
    #expect(model.words.map(\.id) == [second.id])
    #expect(model.deletedRanges.isEmpty)
    model.undo()
    #expect(model.words.map(\.id) == [first.id, second.id])
    #expect(model.deletedRanges.isEmpty)
}

@MainActor @Test func deletingSubtitleSurvivesDuplicateBreathRanges() {
    let first = word("你", 0, 0.5)
    let second = word("好", 2, 2.5)
    let duplicate = BreathCandidate(start: 0.5, end: 2, leftText: "你", rightText: "好")
    let model = EditorModel()
    model.words = [first, second]
    model.breaths = [duplicate, duplicate]
    model.deleteSubtitles([first.id, second.id])
    #expect(model.words.isEmpty)
    #expect(model.breaths.isEmpty)
    model.undo()
    #expect(model.words.count == 2)
}

@MainActor @Test func subtitleSplitMergeAndUndo() {
    let first = word("第一", 0, 1)
    let second = word("第二", 1, 2)
    let third = word("第三", 2, 3)
    let model = EditorModel()
    model.words = [first, second, third]
    #expect(model.subtitleCues.count == 1)
    model.splitSubtitle(at: 0.5)
    #expect(model.subtitleCues.count == 2)
    #expect(model.subtitleCues[1].wordIDs.first == second.id)
    model.mergeSubtitle(startingWith: second.id)
    #expect(model.subtitleCues.count == 1)
    model.undo()
    #expect(model.subtitleCues.count == 2)
}

@MainActor @Test func automaticSubtitleBoundaryCanMergeAndUndo() {
    let first = word("第一句。", 0, 1)
    let second = word("第二句。", 1, 2)
    let model = EditorModel()
    model.words = [first, second]
    #expect(model.subtitleCues.count == 2)
    model.mergeSubtitle(startingWith: second.id)
    #expect(model.subtitleCues.map(\.text) == ["第一句第二句"])
    model.undo()
    #expect(model.subtitleCues.count == 2)
}

@MainActor @Test func trimHandlesClampAndSnapToFrames() {
    let model = EditorModel()
    model.duration = 10
    model.trimEnd = 10
    model.frameRate = 25
    model.beginTrimEdit()
    model.updateTrimStart(2.019)
    model.updateTrimEnd(8.021)
    #expect(model.trimStart == 2)
    #expect(model.trimEnd == 8.04)
    model.finishTrimEdit()
    model.undo()
    #expect(model.trimStart == 0)
    #expect(model.trimEnd == 10)
}

@MainActor @Test func selectingTranscriptCueUpdatesTimelineSelectionAndPlayerTime() {
    let model = EditorModel()
    let cue = SubtitleCue(text: "同步", start: 3, end: 4, wordIDs: [UUID(), UUID()])
    model.selectSubtitle(cue)
    #expect(model.selectedWordIDs == cue.wordIDs)
    #expect(model.currentTime == 3)
}

@MainActor @Test func editingSubtitleRebuildsWordsWithoutChangingTimeRange() {
    let model = EditorModel()
    model.manuscript = "用户自己的 Word 稿"
    model.words = [word("错", 2, 3), word("字幕。", 3, 4)]
    let cue = model.subtitleCues[0]
    model.editSubtitle(cue, text: "正确字幕。")
    #expect(model.subtitleCues.map(\.text) == ["正确字幕"])
    #expect(model.words.first?.start == 2)
    #expect(model.words.last?.end == 4)
    #expect(model.manuscript == "用户自己的 Word 稿")
    model.undo()
    #expect(model.words.map(\.text).joined() == "错字幕。")
}

@MainActor @Test func automaticDedupeKeepsLatestDeliveryAndCanUndo() {
    let early = word("这个房间采光特别好。", 1, 3)
    let latest = word("这个房间采光特别好。", 8, 10)
    let model = EditorModel()
    model.words = [early, word("我们再来一遍。", 4, 5), latest]
    model.dedupeMode = .automatic
    model.executeDedupe()
    #expect(model.words.first?.isDeleted == true)
    #expect(model.words.last?.isDeleted == false)
    model.undo()
    #expect(model.words.first?.isDeleted == false)
}

@MainActor @Test func confirmDedupeOnlyCreatesPendingChatSuggestions() {
    let early = word("这个房间采光特别好。", 1, 3)
    let latest = word("这个房间采光特别好。", 8, 10)
    let model = EditorModel()
    model.words = [early, latest]
    model.dedupeMode = .confirm
    model.executeDedupe()
    #expect(model.words.allSatisfy { !$0.isDeleted })
    #expect(model.suggestions.count == 1)
    #expect(model.suggestions.first?.state == .pending)
}

@MainActor @Test func repetitionRowDecisionOnlyAffectsThatVisibleCue() {
    let first = word("第一行", 1, 2), second = word("第二行", 2, 3), retained = word("最终保留行", 8, 9)
    let suggestion = EditSuggestion(type: .repetition, title: "重复", reason: "保留最后一遍", confidence: 0.9, wordIDs: [first.id, second.id], retainedWordIDs: [retained.id], start: 1, end: 3)
    let model = EditorModel()
    model.words = [first, second, retained]
    model.suggestions = [suggestion]

    model.decideRepetitionSegment(suggestion.id, wordIDs: [first.id], delete: true)
    #expect(model.words[0].isDeleted)
    #expect(!model.words[1].isDeleted)
    #expect(!model.words[2].isDeleted)
    #expect(model.suggestions[0].state == .pending)
    #expect(model.suggestions[0].wordIDs == [second.id])

    model.decideRepetitionSegment(suggestion.id, wordIDs: [second.id], delete: false)
    #expect(!model.words[1].isDeleted)
    #expect(!model.words[2].isDeleted)
    #expect(model.suggestions[0].state == .kept)
}

@MainActor @Test func reviewCorrectionsRequireExplicitAcceptance() {
    let original = word("大眼尘", 0, 1)
    let model = EditorModel()
    model.words = [original]
    model.pendingReviewCorrections = [original.id: "大眼橙"]
    #expect(model.words[0].text == "大眼尘")
    model.cancelReview()
    #expect(model.words[0].text == "大眼尘")
    model.pendingReviewCorrections = [original.id: "大眼橙"]
    model.acceptReview()
    #expect(model.words[0].text == "大眼橙")
    model.undo()
    #expect(model.words[0].text == "大眼尘")
}

@MainActor @Test func commandSelectionAddsAndTogglesSubtitleCues() {
    let model = EditorModel()
    let first = SubtitleCue(text: "一", start: 0, end: 1, wordIDs: [UUID()])
    let second = SubtitleCue(text: "二", start: 1, end: 2, wordIDs: [UUID(), UUID()])
    model.selectSubtitle(first)
    model.selectSubtitle(second, additive: true)
    #expect(Set(model.selectedWordIDs) == Set(first.wordIDs + second.wordIDs))
    model.selectSubtitle(first, additive: true)
    #expect(Set(model.selectedWordIDs) == Set(second.wordIDs))
}

@Test func projectTrimRoundTripAndSRTExcludeTrimmedWords() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "cutflow-trim-\(UUID()).cutflow")
    defer { try? FileManager.default.removeItem(at: url) }
    let words = [word("开头", 0, 1), word("保留", 2, 3), word("结尾", 4, 5)]
    let deleted = [TimeRange(start: 0, end: 2), TimeRange(start: 4, end: 5)]
    let document = ProjectDocument(name: "修剪", sourcePath: "/tmp/a.mov", transcript: .init(assetID: "a", duration: 5, words: words), suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25, trimStart: 2, trimEnd: 4, sourceDuration: 5)
    try ProjectStore.save(document, to: url)
    let restored = try ProjectStore.load(from: url)
    #expect(restored.trimStart == 2)
    #expect(restored.trimEnd == 4)
    let edl = EditDecisionList(sourcePath: "/tmp/a.mov", sourceDuration: 5, frameRate: 25, deletedRanges: deleted, keptRanges: [.init(start: 2, end: 4)], words: words, suggestions: [], breaths: [])
    let srt = TimelineExporter.srt(edl)
    #expect(srt.contains("保留"))
    #expect(!srt.contains("开头"))
    #expect(!srt.contains("结尾"))
}

@Test func projectRenameUpdatesFileAndDocumentName() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "cutflow-rename-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appending(path: "旧名称.cutflow")
    let document = ProjectDocument(name: "旧名称", sourcePath: "/tmp/a.mov", transcript: nil, suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25)
    try ProjectStore.save(document, to: original)
    let renamed = try ProjectStore.rename(original, to: "新名称")
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(renamed.lastPathComponent == "新名称.cutflow")
    #expect(try ProjectStore.load(from: renamed).name == "新名称")
    #expect(throws: (any Error).self) { try ProjectStore.rename(renamed, to: "../非法") }
}

@Test func projectLoadRecoversBackupAfterPrimaryCorruption() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "cutflow-backup-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "恢复.cutflow")
    let original = ProjectDocument(name: "可恢复版本", sourcePath: "/tmp/a.mov", transcript: nil, suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25)
    try ProjectStore.save(original, to: url)
    var updated = original; updated.name = "最新版本"
    try ProjectStore.save(updated, to: url)
    try Data("损坏内容".utf8).write(to: url)
    #expect(try ProjectStore.load(from: url).name == "可恢复版本")
}

@Test func oldProjectWithoutNewOptionalFieldsStillDecodes() throws {
    let document = ProjectDocument(name: "旧项目", sourcePath: "/tmp/a.mov", transcript: nil, suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(document)) as? [String: Any])
    for key in ["manuscript", "messages", "subtitleBreaks", "trimStart", "trimEnd", "sourceDuration", "burnSubtitles", "subtitleFontSize", "playhead"] { json.removeValue(forKey: key) }
    let decoded = try JSONDecoder.iso8601.decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.name == "旧项目")
    #expect(decoded.playhead == nil)
}

@MainActor @Test func previewSubtitleFollowsPlayerAndStyleBounds() {
    let model = EditorModel()
    model.duration = 5
    model.trimEnd = 5
    model.words = [word("预览字幕。", 1, 3)]
    model.currentTime = 2
    #expect(model.activeSubtitle?.text == "预览字幕")
    model.currentTime = 4
    #expect(model.activeSubtitle == nil)
    model.setSubtitleFontSize(200)
    #expect(model.subtitleFontSize == 80)
    model.setBurnSubtitles(false)
    #expect(!model.burnSubtitles)
}

@Test func convertsExternalVideoToMiMoSizedWAVChunks() async throws {
    guard let path = ProcessInfo.processInfo.environment["CUTFLOW_TEST_VIDEO"] else { return }
    let chunks = try await AudioChunker.makeWAVChunks(videoURL: URL(fileURLWithPath: path))
    defer { chunks.forEach { try? FileManager.default.removeItem(at: $0.url) } }
    #expect(!chunks.isEmpty)
    for chunk in chunks {
        #expect(try Data(contentsOf: chunk.url).prefix(4) == Data("RIFF".utf8))
        #expect((try? chunk.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 10_000_000)
        #expect(chunk.duration <= 10.01)
        #expect(!chunk.speechRanges.isEmpty)
        #expect(chunk.speechRanges.allSatisfy { $0.start >= 0 && $0.end <= chunk.duration + 0.001 && $0.end > $0.start })
        #expect(zip(chunk.speechRanges, chunk.speechRanges.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(chunk.speechStart >= 0)
        #expect(chunk.speechStart + chunk.speechDuration <= chunk.duration + 0.001)
    }
}

@Test func voiceBoundsRemoveLeadingAndTrailingSilence() {
    var pcm = Data()
    for frame in 0..<3000 {
        var sample = Int16(frame >= 1000 && frame < 2000 ? 12_000 : 0).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    let bounds = AudioChunker.speechBounds(pcm: pcm, sampleRate: 1000, channels: 1)
    #expect(bounds.start > 0.85 && bounds.start < 1.05)
    #expect(bounds.end > 1.95 && bounds.end < 2.15)
}

@Test func wordTimingFollowsInternalSpeechRanges() {
    var pcm = Data()
    for frame in 0..<6000 {
        let voiced = (500..<1500).contains(frame) || (3000..<5000).contains(frame)
        var sample = Int16(voiced ? 12_000 : 0).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    let ranges = AudioChunker.speechRanges(pcm: pcm, sampleRate: 1000, channels: 1)
    #expect(ranges.count == 2)
    #expect(ranges[0].end < 1.7)
    #expect(ranges[1].start > 2.8)
    let words = MiMoASRClient.estimatedWords(text: "第一，第二，第三，第四。", start: 10, duration: 6, speechRanges: ranges)
    #expect(words.count >= 2)
    #expect(words.first!.start > 10.4 && words.first!.start < 10.6)
    #expect(words.last!.end > 14.9 && words.last!.end < 15.1)
    #expect(words.allSatisfy { !($0.start < 12.8 && $0.end > 11.7) })
    #expect(words.contains { $0.start > 12.8 })
}

@Test func asrRetriesTransientFailuresButNotInvalidResponses() async throws {
    var attempts = 0
    let result: String = try await MiMoASRClient.retrying(initialDelayNanoseconds: 0) {
        attempts += 1
        if attempts < 3 { throw URLError(.networkConnectionLost) }
        return "成功"
    }
    #expect(result == "成功")
    #expect(attempts == 3)
    var invalidAttempts = 0
    do {
        let _: String = try await MiMoASRClient.retrying(initialDelayNanoseconds: 0) {
            invalidAttempts += 1
            throw MiMoError.invalidResponse("坏数据")
        }
        Issue.record("无效响应不应成功")
    } catch { #expect(invalidAttempts == 1) }
}

@Test func extractsExternalVideoWaveform() async throws {
    guard let path = ProcessInfo.processInfo.environment["CUTFLOW_TEST_VIDEO"] else { return }
    let samples = try await AudioWaveform.samples(videoURL: URL(fileURLWithPath: path), count: 240)
    #expect(samples.count == 240)
    #expect((samples.max() ?? 0) > 0.9)
}

@Test func extractsExternalVideoThumbnails() async throws {
    guard let path = ProcessInfo.processInfo.environment["CUTFLOW_TEST_VIDEO"] else { return }
    let images = try await VideoThumbnails.jpegData(videoURL: URL(fileURLWithPath: path), count: 4)
    #expect(images.count == 4)
    #expect(images.allSatisfy { NSImage(data: $0) != nil })
}

@MainActor @Test func rendersExternalVideoEditToMP4() async throws {
    guard let path = ProcessInfo.processInfo.environment["CUTFLOW_TEST_VIDEO"] else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: "cutflow-render-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let edl = EditDecisionList(sourcePath: path, sourceDuration: 479, frameRate: 30, deletedRanges: [.init(start: 2, end: 479)], keptRanges: [.init(start: 0, end: 2)], words: [word("测试字幕", 0.2, 1.8)], suggestions: [], breaths: [], burnSubtitles: true, subtitleFontSize: 48)
    let cues = TimelineExporter.exportSubtitleCues(edl)
    #expect(cues.count == 1)
    #expect(cues[0].text == "测试字幕")
    var progress = 0.0
    let output = try await TimelineExporter.renderMP4(edl, projectName: "render-test", folder: folder) { progress = $0 }
    #expect(FileManager.default.fileExists(atPath: output.path))
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(duration > 1.8 && duration < 2.2)
    #expect(progress == 1)
}

@Test func transcriptCacheChangesWhenSourceChanges() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "cutflow-cache-\(UUID())")
    let video = folder.appending(path: "sample.mov")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data([1]).write(to: video)
    let settings = MiMoSettings(baseURL: "https://example.com/v1", model: "chat", asrModel: "asr", asrPath: "/audio/transcriptions", apiKey: "secret")
    let first = try TranscriptCache.url(videoURL: video, settings: settings, folder: folder)
    try Data([1, 2]).write(to: video)
    let second = try TranscriptCache.url(videoURL: video, settings: settings, folder: folder)
    #expect(first != second)
    #expect(!first.lastPathComponent.contains("secret"))
}

@MainActor @Test func openingMissingSourceNeverKeepsPreviousVideo() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "cutflow-open-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = folder.appending(path: "missing.cutflow")
    let document = ProjectDocument(name: "待重定位", sourcePath: folder.appending(path: "missing.mov").path, transcript: .init(assetID: "missing.mov", duration: 2, words: [word("测试", 0, 1)]), suggestions: [], breaths: [], breathMode: .automatic, frameRate: 25, playhead: 1.25)
    try ProjectStore.save(document, to: project)
    let model = EditorModel()
    model.videoURL = folder.appending(path: "previous.mov")
    try await model.openProject(project)
    #expect(model.videoURL == nil)
    #expect(model.showRelinkImporter)
    #expect(model.words.map(\.text) == ["测试"])
    #expect(model.currentTime == 1.25)
}

@MainActor @Test func aiCardsCreateTemporaryFocusWithoutPermanentSelection() {
    let transcriptWord = word("重复句", 12, 13)
    let suggestion = EditSuggestion(type: .repetition, title: "重复句", reason: "保留最后一遍", confidence: 0.9, wordIDs: [transcriptWord.id], start: 12, end: 13)
    let model = EditorModel()
    model.words = [transcriptWord]
    let firstRequest = model.focusRequestID
    model.focusSuggestion(suggestion)
    #expect(model.currentTime == 12)
    #expect(model.focusedWordID == transcriptWord.id)
    #expect(model.transientHighlightedWordIDs == [transcriptWord.id])
    #expect(model.selectedWordIDs.isEmpty)
    #expect(model.focusRequestID != firstRequest)

    let breath = BreathCandidate(start: 20, end: 20.8, leftText: "前", rightText: "后")
    model.focusBreath(breath)
    #expect(model.currentTime == 20)
    #expect(model.transientHighlightedBreath == TimeRange(start: 20, end: 20.8))
    #expect(model.transientHighlightedWordIDs.isEmpty)
    #expect(model.selectedWordIDs.isEmpty)
}

@MainActor @Test func deletingRepetitionAutomaticallyFocusesNextPendingRegion() {
    let firstWord = word("第一次", 5, 6)
    let secondWord = word("第二次", 12, 13)
    let first = EditSuggestion(type: .repetition, title: "重复一", reason: "重复", confidence: 0.9, wordIDs: [firstWord.id], start: 5, end: 6)
    let second = EditSuggestion(type: .repetition, title: "重复二", reason: "重复", confidence: 0.9, wordIDs: [secondWord.id], start: 12, end: 13)
    let model = EditorModel()
    model.words = [firstWord, secondWord]
    model.suggestions = [second, first]

    model.decide(first.id, delete: true)
    #expect(model.words[0].isDeleted)
    #expect(model.suggestions.first(where: { $0.id == first.id })?.state == .deleted)
    #expect(model.currentTime == 12)
    #expect(model.focusedWordID == secondWord.id)
    #expect(model.transientHighlightedWordIDs == [secondWord.id])

    model.decide(second.id, delete: true)
    #expect(model.words[1].isDeleted)
    #expect(model.taskState == .done("全部重复字幕已处理完成"))
}
