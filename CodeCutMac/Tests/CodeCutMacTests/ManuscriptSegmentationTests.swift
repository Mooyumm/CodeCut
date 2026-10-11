import Foundation
import Testing

@testable import CodeCutMac

private func word(_ text: String, _ start: Double, _ end: Double, deleted: Bool = false) -> TranscriptWord {
    TranscriptWord(text: text, start: start, end: end, isDeleted: deleted)
}

/// 逐字稿按字拆开，每个字一段连续时间戳（识别稿本身没有任何标点）。
private func characterWords(_ text: String, gapBefore: [Int: Double] = [:], seconds: Double = 0.25) -> [TranscriptWord] {
    var result: [TranscriptWord] = []
    var cursor = 0.0
    for (index, character) in Array(text).enumerated() {
        if let gap = gapBefore[index] { cursor += gap }
        result.append(word(String(character), cursor, cursor + seconds))
        cursor += seconds
    }
    return result
}

// MARK: - 第一级：文稿标点

@Test func manuscriptBreaksUsePunctuationFromReferenceScript() {
    let words = characterWords("这是第一句话这是第二句话")
    let result = TimelineEngine.manuscriptBreaks(manuscript: "这是第一句话。这是第二句话。", in: words)
    #expect(result.aligned)
    #expect(result.breaks == [words[6].id])
}

@Test func manuscriptBreaksTreatCommasAndQuestionMarksAsBoundaries() {
    let words = characterWords("今天讲三件事第一件是什么第二件是价格")
    let result = TimelineEngine.manuscriptBreaks(manuscript: "今天讲三件事，第一件是什么？第二件是价格。", in: words)
    #expect(result.aligned)
    #expect(result.breaks == [words[6].id, words[12].id])
}

@Test func manuscriptBreaksDoNotSplitOnEnumerationComma() {
    // 顿号只表示并列，和 mandatorySentenceBreaks 保持一致，不能在顿号处断句。
    let words = characterWords("吃饭工作睡觉都在这里")
    let result = TimelineEngine.manuscriptBreaks(manuscript: "吃饭、工作、睡觉都在这里。", in: words)
    #expect(result.breaks.isEmpty)
}

@Test func manuscriptBreaksTolerateRecognitionTypos() {
    // 识别稿把「话」听成了「花」，仍然要对齐到同一个断点。
    let words = characterWords("这是第一句花这是第二句话")
    let result = TimelineEngine.manuscriptBreaks(manuscript: "这是第一句话。这是第二句话。", in: words)
    #expect(result.aligned)
    #expect(result.breaks == [words[6].id])
}

@Test func manuscriptBreaksRefuseUnrelatedManuscript() {
    // 文稿和识别稿完全对不上时必须拒绝，绝不用错的标点去切。
    let words = characterWords("这是第一句话这是第二句话")
    let result = TimelineEngine.manuscriptBreaks(manuscript: "完全不同的另一段内容。", in: words)
    #expect(!result.aligned)
    #expect(result.breaks.isEmpty)
}

@Test func manuscriptBreaksIgnoreEmptyManuscript() {
    let words = characterWords("这是第一句话这是第二句话")
    #expect(TimelineEngine.manuscriptBreaks(manuscript: "   ", in: words).breaks.isEmpty)
}

// MARK: - 第二级：停顿优先

@Test func balancedSentenceBreaksPreferRealBreathOverEvenSplit() {
    // 27 个字的一条长片段，第 10 个字之后有一次 0.6 秒换气。
    // 按字数最均衡会切在 13 字处，正确做法是切在说话人换气的地方。
    let words = [
        word("前面九个字的内容，", 0, 1),
        word("停在", 1, 1.2),
        word("这里吧", 1.8, 2.5),
        word("后面还有很长的内容继续往下说。", 2.5, 6)
    ]
    let candidates = Set(words.map(\.id))
    let breaks = TimelineEngine.balancedSentenceBreaks([], candidates: candidates, in: words)
    #expect(breaks == [words[2].id])
}

@Test func balancedSentenceBreaksFallBackToEvenSplitWithoutAnyPause() {
    // 同样的句子，去掉换气之后只能退回左右均衡的位置。
    let words = [
        word("前面九个字的内容，", 0, 1),
        word("停在", 1, 1.2),
        word("这里吧", 1.2, 1.9),
        word("后面还有很长的内容继续往下说。", 1.9, 5.4)
    ]
    let candidates = Set(words.map(\.id))
    let breaks = TimelineEngine.balancedSentenceBreaks([], candidates: candidates, in: words)
    #expect(breaks == [words[3].id])
}

@Test func balancedSentenceBreaksStillSplitSlowSpeechWithoutPause() {
    let text = "与其是电视投影的价值其实更高用更低的成本"
    let words = Array(text).enumerated().map { index, character in
        word(String(character), Double(index) * 1.15, Double(index + 1) * 1.15)
    }
    let candidates = Set(TimelineEngine.subtitleCues(words: words).dropFirst().compactMap(\.wordIDs.first))
    let breaks = TimelineEngine.balancedSentenceBreaks([], candidates: candidates, in: words)
    #expect(!breaks.isEmpty)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: breaks, joinBefore: [])
    #expect(cues.allSatisfy { $0.end - $0.start <= 12 })
}

// MARK: - 组合：本地断句骨架

@Test func localSentenceBreaksAlignManuscriptThenKeepPauses() {
    let words = characterWords("这是第一句话这是第二句话这是第三句话", gapBefore: [15: 0.7])
    let result = TimelineEngine.localSentenceBreaks(words: words, manuscript: "这是第一句话。这是第二句话。这是第三句话。")
    #expect(result.manuscriptAligned)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: result.breaks, joinBefore: [])
    #expect(cues.map(\.text) == ["这是第一句话", "这是第二句话", "这是第三句话"])
}

@Test func localSentenceBreaksWithoutManuscriptStillUsePauses() {
    let words = characterWords("这是第一句话这是第二句话这是第三句话", gapBefore: [6: 0.7, 12: 0.7])
    let result = TimelineEngine.localSentenceBreaks(words: words)
    #expect(!result.manuscriptAligned)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: result.breaks, joinBefore: [])
    #expect(cues.count >= 2)
    #expect(cues.allSatisfy { $0.text.count >= 6 })
}

@Test func localSentenceBreaksIgnoreDeletedWords() {
    let words = characterWords("这是第一句话这是第二句话") + [word("。", 5, 5.1, deleted: true)]
    let result = TimelineEngine.localSentenceBreaks(words: words, manuscript: "这是第一句话。这是第二句话。")
    #expect(result.manuscriptAligned)
    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: result.breaks, joinBefore: [])
    #expect(cues.map(\.text) == ["这是第一句话", "这是第二句话"])
}

// MARK: - 真实逐字时间戳回归

/// 用本机真实口播逐字稿验证：识别稿本身没有任何标点，文稿的句读必须逐句落成断点。
/// 换了机器、缓存被清掉时自动跳过，不影响其它用例。
@Test func realTranscriptTakesPunctuationFromManuscript() {
    let path = "/Users/m4/Library/Caches/CodeCut/Transcripts/219d829fbc55f7a00d3221aadcd2b1864503889832e6ce161df05c4a96d669e9.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let document = try? JSONDecoder().decode(TranscriptDocument.self, from: data) else { return }
    let words = Array(document.words.filter { !$0.isDeleted }.prefix(300))
    guard words.count == 300 else { return }
    #expect(words.allSatisfy { $0.text.allSatisfy { !"，,。！？!?;；".contains($0) } })

    let offsets = [68, 141, 226]
    var manuscript = ""
    for (index, word) in words.enumerated() {
        if offsets.contains(index) { manuscript += "。" }
        manuscript += word.text
    }
    manuscript += "。"

    let result = TimelineEngine.localSentenceBreaks(words: words, manuscript: manuscript)
    #expect(result.manuscriptAligned)
    let expected = Set(offsets.map { words[$0].id })
    #expect(expected.isSubset(of: result.breaks))

    let cues = TimelineEngine.subtitleCues(words: words, breakBefore: result.breaks, joinBefore: [])
    #expect(cues.count > 5)
    #expect(cues.allSatisfy { $0.text.count <= 30 })
}
