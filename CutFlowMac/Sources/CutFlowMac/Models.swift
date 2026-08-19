import AVKit
import NaturalLanguage
import Observation
import SwiftUI

struct TranscriptWord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var speaker: String?
    var isDeleted = false
}

struct TranscriptDocument: Codable, Equatable, Sendable {
    var assetID: String
    var language: String?
    var duration: Double
    var words: [TranscriptWord]
}

struct SubtitleCue: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var wordIDs: [UUID]
}

struct EditSuggestion: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var type: Kind
    var title: String
    var reason: String
    var confidence: Double
    var wordIDs: [UUID]
    var retainedWordIDs: [UUID]? = nil
    var start: Double
    var end: Double
    var state: State = .pending

    enum Kind: String, Codable, CaseIterable, Sendable { case filler, correction, repetition, invalid }
    enum State: String, Codable, Sendable { case pending, kept, deleted }
}

struct BreathCandidate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var leftText: String
    var rightText: String
    var state: State = .pending
    var duration: Double { end - start }
    enum State: String, Codable, Sendable { case pending, kept, deleted }
}

struct TimeRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}

enum StoryboardKind: String, Codable, CaseIterable, Sendable {
    case liveAction = "实拍空镜"
    case motionGraphics = "MG 动画"
}

struct StoryboardItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: StoryboardKind
    var wordIDs: [UUID]
    var fallbackStart: Double
    var fallbackEnd: Double
    var description: String
    var composition: String
    var cameraMovement: String
    var elements: String
    var notes: String
}

struct EditDecisionList: Codable, Equatable, Sendable {
    var version = 1
    var sourcePath: String
    var sourceDuration: Double
    var frameRate: Double
    var deletedRanges: [TimeRange]
    var keptRanges: [TimeRange]
    var words: [TranscriptWord]
    var suggestions: [EditSuggestion]
    var breaths: [BreathCandidate]
    var subtitleBreaks: [UUID] = []
    var subtitleJoins: [UUID] = []
    var burnSubtitles = true
    var subtitleFontSize = 48.0
    var outputDuration: Double { keptRanges.reduce(0) { $0 + $1.duration } }
}

struct ProjectDocument: Codable, Sendable {
    var version = 1
    var name: String
    var sourcePath: String
    var sourceBookmark: Data?
    var transcript: TranscriptDocument?
    var suggestions: [EditSuggestion]
    var breaths: [BreathCandidate]
    var breathMode: EditorModel.BreathMode
    var dedupeMode: EditorModel.DedupeMode? = nil
    var frameRate: Double
    var manuscript: String? = nil
    var messages: [ChatMessage]? = nil
    var subtitleBreaks: [UUID]? = nil
    var subtitleJoins: [UUID]? = nil
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var sourceDuration: Double? = nil
    var burnSubtitles: Bool? = nil
    var subtitleFontSize: Double? = nil
    var playhead: Double? = nil
    var storyboards: [StoryboardItem]? = nil
    var updatedAt = Date()
}

struct ChatMessage: Identifiable, Codable, Sendable {
    var id = UUID()
    let role: Role
    let text: String
    enum Role: String, Codable, Sendable { case user, assistant, status }
}

enum TimelineEngine {
    static func subtitleDisplayText(_ source: String) -> String {
        var text = source.filter { !"，,。.".contains($0) }
        for duplicate in ["::", "：：", "：:", ":："] {
            while text.contains(duplicate) { text = text.replacingOccurrences(of: duplicate, with: ":") }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mandatorySentenceBreaks(in words: [TranscriptWord]) -> Set<UUID> {
        let end = CharacterSet(charactersIn: "，,。！？!?;；")
        return Set(words.indices.dropLast().compactMap { index in
            words[index].text.unicodeScalars.contains(where: end.contains) ? words[words.index(after: index)].id : nil
        })
    }

    static func refinedSentenceBreaks(_ proposed: Set<UUID>, in words: [TranscriptWord]) -> Set<UUID> {
        guard words.count > 1 else { return [] }
        var breaks = proposed
        func plain(_ range: Range<Int>) -> String {
            words[range].map(\.text).joined().filter { !$0.isWhitespace && !"，,。.!?！？;；".contains($0) }
        }
        func ranges() -> [Range<Int>] {
            var result: [Range<Int>] = [], start = 0
            for index in words.indices.dropFirst() where breaks.contains(words[index].id) {
                result.append(start..<index)
                start = index
            }
            result.append(start..<words.endIndex)
            return result
        }
        let discourseFragments = ["这也是", "就是", "所以", "但是", "而且", "然后", "因为", "不过", "其实", "比如", "尤其是", "但说实话"]
        let dependentStarters = ["当", "如果", "因为", "所以", "但是", "不过", "而且", "其实", "比如", "对于", "在", "相比于", "但说实话", "除了", "尤其是", "只是", "有的人", "就会"]
        let incompleteEnd = Set("的地得把被在和与或为让给用从对向是有一二三四五六七八九十百千万亿0123456789")
        let continuationStart = Set("个台块寸种些点层倍元万千百亿的地得了着过和与或0123456789")
        while true {
            let segments = ranges()
            var boundaryToRemove: UUID?
            for index in segments.indices {
                let text = plain(segments[index])
                if text.isEmpty, index > 0 {
                    boundaryToRemove = words[segments[index].lowerBound].id
                    break
                }
                if index + 1 < segments.count {
                    let next = plain(segments[index + 1])
                    let discourseFragment = discourseFragments.contains(text) || (text.count <= 6 && discourseFragments.contains(where: text.hasPrefix))
                    let leadingFragment = text.count < 6 || discourseFragment
                    let unfinished = text.count <= 12 && text.last.map(incompleteEnd.contains) == true
                    let continued = next.first.map(continuationStart.contains) == true
                    let source = words[segments[index]].map(\.text).joined()
                    let dependentClause = text.count <= 12 && (source.hasSuffix("，") || source.hasSuffix(",")) && dependentStarters.contains(where: text.hasPrefix)
                    if leadingFragment || unfinished || continued || dependentClause {
                        boundaryToRemove = words[segments[index + 1].lowerBound].id
                        break
                    }
                } else if index > 0, text.count <= 2 {
                    boundaryToRemove = words[segments[index].lowerBound].id
                    break
                }
            }
            guard let boundaryToRemove else { return breaks }
            breaks.remove(boundaryToRemove)
        }
    }

    static func balancedSentenceBreaks(_ refined: Set<UUID>, candidates: Set<UUID>, in words: [TranscriptWord], maxCharacters: Int = 22, maxDuration: Double = 8) -> Set<UUID> {
        var breaks = refined
        func count(_ range: Range<Int>) -> Int {
            words[range].map(\.text).joined().filter { !$0.isWhitespace && !"，,。.!?！？;；".contains($0) }.count
        }
        while true {
            var ranges: [Range<Int>] = [], start = 0
            for index in words.indices.dropFirst() where breaks.contains(words[index].id) {
                ranges.append(start..<index)
                start = index
            }
            ranges.append(start..<words.endIndex)
            var added: UUID?
            for range in ranges {
                guard let first = range.first, let last = range.last else { continue }
                let totalCharacters = count(range)
                let duration = words[last].end - words[first].start
                guard totalCharacters > maxCharacters || duration > maxDuration else { continue }
                let options = range.dropFirst().filter { index in
                    candidates.contains(words[index].id) && !breaks.contains(words[index].id) && count(range.lowerBound..<index) >= 5 && count(index..<range.upperBound) >= 5
                }
                let best = options.min { lhs, rhs in
                    abs(count(range.lowerBound..<lhs) - count(lhs..<range.upperBound)) < abs(count(range.lowerBound..<rhs) - count(rhs..<range.upperBound))
                }
                if let best { added = words[best].id; break }
            }
            guard let added else { return breaks }
            breaks.insert(added)
        }
    }

    static func subtitleCues(words: [TranscriptWord], breakBefore: Set<UUID> = [], joinBefore: Set<UUID> = [], maxCharacters: Int = 28, maxDuration: Double = 8) -> [SubtitleCue] {
        var cues: [SubtitleCue] = [], pending: [TranscriptWord] = []
        let terminal = CharacterSet(charactersIn: "。！？!?；;\n")
        let phraseBreak = CharacterSet(charactersIn: "，,：:")
        let semanticStarters = ["当你", "当我", "当我们", "当大家", "如果", "因为", "所以", "但是", "不过", "而且", "然后", "后来", "其实", "比如", "对于", "与其", "虽然", "即使", "只要", "从来", "而是", "让一个", "让我", "让我们", "让它", "更多", "我是", "记得", "那我们", "以前", "吃饭", "价格", "还需要", "一打开", "在参数层面"]
        let connectorOnly = Set(["所以", "但是", "不过", "而且", "然后", "而是", "因为"])
        func joined(_ words: [TranscriptWord]) -> String {
            words.reduce(into: "") { text, word in
                let value = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                text += value
            }
        }
        func contains(_ word: TranscriptWord, _ set: CharacterSet) -> Bool {
            word.text.unicodeScalars.contains { set.contains($0) }
        }
        func flush(_ count: Int? = nil) {
            let amount = min(count ?? pending.count, pending.count)
            guard amount > 0 else { return }
            let words = Array(pending.prefix(amount))
            guard let first = words.first, let last = words.last else { return }
            let displayText = joined(words)
            if displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !cues.isEmpty {
                    cues[cues.count - 1].end = last.end
                    cues[cues.count - 1].wordIDs += words.map(\.id)
                }
            } else {
                cues.append(.init(id: first.id, text: displayText, start: first.start, end: last.end, wordIDs: words.map(\.id)))
            }
            pending.removeFirst(amount)
        }
        func semanticBoundary() -> Int? {
            let text = joined(pending)
            let candidates = semanticStarters.compactMap { marker -> Int? in
                guard let range = text.range(of: marker, options: .backwards), range.lowerBound != text.startIndex else { return nil }
                let characterCount = text[..<range.lowerBound].count
                guard characterCount >= 6, characterCount <= maxCharacters else { return nil }
                guard let index = pending.indices.first(where: { joined(Array(pending[...$0])).count == characterCount }), pending[index].end - pending[0].start <= maxDuration else { return nil }
                return index + 1
            }
            return candidates.max()
        }
        func lexicalBoundary() -> Int? {
            let text = joined(pending)
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            var characterCounts: [Int] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let count = text[..<range.upperBound].count
                if count >= max(4, maxCharacters / 2), count <= maxCharacters { characterCounts.append(count) }
                return true
            }
            for target in characterCounts.sorted(by: >) {
                if let index = pending.indices.first(where: { joined(Array(pending[...$0])).count == target }), pending[index].end - pending[0].start <= maxDuration { return index + 1 }
            }
            return nil
        }
        for word in words where !word.isDeleted {
            if breakBefore.contains(word.id) { flush() }
            if let last = pending.last, word.start - last.end >= 0.9 { flush() }
            pending.append(word)
            // Semantic clauses outrank visual length. Wait for at least two characters
            // on the new side so a one-character starter is not left by itself.
            if let amount = semanticBoundary(), joined(Array(pending.dropFirst(amount))).count >= 2 { flush(amount) }
            while pending.count > 1, joined(pending).count > maxCharacters + 2 || (pending.last!.end - pending.first!.start) > maxDuration {
                if let natural = pending.dropLast().lastIndex(where: { contains($0, phraseBreak) }) {
                    flush(pending.distance(from: pending.startIndex, to: natural) + 1)
                } else if let amount = semanticBoundary() ?? lexicalBoundary() {
                    flush(amount)
                } else {
                    var amount = 1
                    for index in pending.indices.dropLast() {
                        let candidate = Array(pending[...index])
                        if joined(candidate).count <= maxCharacters, candidate.last!.end - candidate.first!.start <= maxDuration { amount = index + 1 }
                    }
                    flush(amount)
                }
            }
            if contains(word, terminal) { flush() }
            else if contains(word, phraseBreak) { flush() }
        }
        while pending.count > 1, joined(pending).count > maxCharacters || (pending.last!.end - pending.first!.start) > maxDuration {
            if let natural = pending.dropLast().lastIndex(where: { contains($0, phraseBreak) }) {
                flush(pending.distance(from: pending.startIndex, to: natural) + 1)
            } else if let amount = semanticBoundary() ?? lexicalBoundary() {
                flush(amount)
            } else {
                var amount = 1
                for index in pending.indices.dropLast() where joined(Array(pending[...index])).count <= maxCharacters { amount = index + 1 }
                flush(amount)
            }
        }
        flush()
        // A connective has no complete meaning by itself; attach it to what follows.
        if cues.count > 1 {
            var naturalCues: [SubtitleCue] = []
            var index = 0
            while index < cues.count {
                var cue = cues[index]
                let plain = cue.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
                if connectorOnly.contains(plain), index + 1 < cues.count {
                    let next = cues[index + 1]
                    cue.text += next.text
                    cue.end = next.end
                    cue.wordIDs += next.wordIDs
                    index += 1
                }
                naturalCues.append(cue)
                index += 1
            }
            cues = naturalCues
        }
        func withoutTrailingSentencePunctuation(_ cues: [SubtitleCue]) -> [SubtitleCue] {
            var result: [SubtitleCue] = [], leadingPunctuation: SubtitleCue?
            for original in cues {
                var cue = original
                cue.text = subtitleDisplayText(cue.text)
                if cue.text.isEmpty {
                    if var previous = result.popLast() {
                        previous.end = cue.end
                        previous.wordIDs += cue.wordIDs
                        result.append(previous)
                    } else if var leading = leadingPunctuation {
                        leading.end = cue.end
                        leading.wordIDs += cue.wordIDs
                        leadingPunctuation = leading
                    } else { leadingPunctuation = cue }
                    continue
                }
                if let leading = leadingPunctuation {
                    cue.id = leading.id
                    cue.start = leading.start
                    cue.wordIDs = leading.wordIDs + cue.wordIDs
                    leadingPunctuation = nil
                }
                result.append(cue)
            }
            return result
        }
        guard !joinBefore.isEmpty else { return withoutTrailingSentencePunctuation(cues) }
        var joinedCues: [SubtitleCue] = []
        for cue in cues {
            if let first = cue.wordIDs.first, joinBefore.contains(first), var previous = joinedCues.popLast() {
                previous.text += cue.text
                previous.end = cue.end
                previous.wordIDs += cue.wordIDs
                joinedCues.append(previous)
            } else { joinedCues.append(cue) }
        }
        return withoutTrailingSentencePunctuation(joinedCues)
    }

    static func applySegmentedArticle(_ article: String, to words: [TranscriptWord]) -> (words: [TranscriptWord], breaks: Set<UUID>)? {
        func isMapped(_ character: Character) -> Bool { character != "\n" && character != "\r" && !character.isWhitespace }
        let punctuation = CharacterSet.punctuationCharacters
        let source = words.filter { !$0.isDeleted }.flatMap { word in word.text.filter(isMapped).map { ($0, word.id) } }
        let returned = article.filter(isMapped)
        guard String(source.map(\.0)) == returned else { return nil }

        var cursor = 0, previousID: UUID?, pendingBreak = false
        var breaks: Set<UUID> = []
        for character in article {
            if character == "\n" || character == "\r" { pendingBreak = true; continue }
            if character.isWhitespace { continue }
            guard source.indices.contains(cursor) else { return nil }
            let id = source[cursor].1
            let isPunctuation = character.unicodeScalars.allSatisfy { punctuation.contains($0) }
            if pendingBreak, id != previousID, !isPunctuation { breaks.insert(id); pendingBreak = false }
            previousID = id
            cursor += 1
        }
        guard cursor == source.count else { return nil }
        return (words, breaks)
    }

    static func restoringBlankWords(_ words: [TranscriptWord], from cachedWords: [TranscriptWord]) -> (words: [TranscriptWord], count: Int) {
        let originals = Dictionary(uniqueKeysWithValues: cachedWords.map { ($0.id, $0.text) })
        var repaired = words, count = 0
        for index in repaired.indices where repaired[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let original = originals[repaired[index].id], !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            repaired[index].text = original
            count += 1
        }
        return (repaired, count)
    }

    /// Scan backwards: keep the latest delivery and suggest earlier repeats for removal.
    static func repetitionSuggestions(cues: [SubtitleCue], manuscript: String = "") -> [EditSuggestion] {
        func normalized(_ text: String) -> String {
            text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
        }
        func bigrams(_ text: String) -> Set<String> {
            let values = Array(text)
            guard values.count > 1 else { return text.isEmpty ? [] : [text] }
            return Set((0..<(values.count - 1)).map { String(values[$0...$0 + 1]) })
        }
        func similarity(_ lhs: String, _ rhs: String) -> Double {
            if lhs == rhs { return 1 }
            let a = bigrams(lhs), b = bigrams(rhs), union = a.union(b)
            return union.isEmpty ? 0 : Double(a.intersection(b).count) / Double(union.count)
        }
        func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
            let a = Array(lhs), b = Array(rhs)
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            var previous = Array(0...b.count)
            for (i, left) in a.enumerated() {
                var current = [i + 1] + Array(repeating: 0, count: b.count)
                for (j, right) in b.enumerated() {
                    current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1))
                }
                previous = current
            }
            return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
        }
        func repetitionScore(_ lhs: String, _ rhs: String) -> Double {
            if lhs == rhs { return 1 }
            let lengthRatio = Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
            guard lengthRatio >= 0.6 else { return 0 }
            if min(lhs.count, rhs.count) >= 6, abs(lhs.count - rhs.count) <= 4, lhs.contains(rhs) || rhs.contains(lhs) { return 0.95 }
            let edit = editSimilarity(lhs, rhs), overlap = similarity(lhs, rhs)
            return edit >= 0.7 || overlap >= 0.65 ? max(edit, overlap) : 0
        }
        func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
            zip(lhs, rhs).prefix { $0 == $1 }.count
        }
        typealias Candidate = (text: String, start: Double, end: Double, wordIDs: [UUID])
        var candidates: [Candidate] = []
        for start in cues.indices {
            var text = "", ids: [UUID] = []
            for end in start..<min(start + 3, cues.count) {
                if end > start, cues[end].start - cues[end - 1].end > 4 { break }
                text += cues[end].text
                ids += cues[end].wordIDs
                let value = normalized(text)
                if value.count >= 3 { candidates.append((value, cues[start].start, cues[end].end, ids)) }
            }
        }
        let reference = normalized(manuscript)
        let ordered = candidates.sorted { $0.start == $1.start ? $0.text.count > $1.text.count : $0.start > $1.start }
        var results: [EditSuggestion] = [], usedEarlierIDs: Set<UUID> = []
        for candidate in ordered where Set(candidate.wordIDs).isDisjoint(with: usedEarlierIDs) {
            let maxDistance = candidate.text.count <= 8 ? 10.0 : 60.0
            let nearbyLater = candidates.filter { $0.start >= candidate.end && $0.start - candidate.end <= maxDistance && Set($0.wordIDs).isDisjoint(with: usedEarlierIDs) }
            let scored = nearbyLater.compactMap { match -> (Candidate, Double, Bool)? in
                let gap = match.start - candidate.end
                let sharedPrefix = commonPrefixCount(candidate.text, match.text)
                let leadingExtra = match.text.range(of: candidate.text).map { match.text.distance(from: match.text.startIndex, to: $0.lowerBound) }
                let nearRestart = gap <= 6 && candidate.text.count <= match.text.count && candidate.text.count >= 6 && ((leadingExtra.map { $0 <= 3 } ?? false) || sharedPrefix >= max(6, candidate.text.count * 2 / 3))
                let referenceBacked = min(candidate.text.count, match.text.count) >= 10 && !reference.isEmpty && (reference.contains(candidate.text) || reference.contains(match.text))
                var score = nearRestart ? 0.95 : repetitionScore(candidate.text, match.text)
                if score == 0, referenceBacked, editSimilarity(candidate.text, match.text) >= 0.65 { score = 0.65 }
                return score > 0 ? (match, score - gap * 0.005, referenceBacked) : nil
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
            let match = best.0, score = best.1, referenceBacked = best.2
            usedEarlierIDs.formUnion(candidate.wordIDs)
            let timestamp = String(format: "%02d:%04.1f", Int(match.start) / 60, match.start.truncatingRemainder(dividingBy: 60))
            let source = referenceBacked ? "，并已参考文字稿确认表达" : ""
            results.append(.init(type: .repetition, title: "重复句（保留最后一遍）", reason: "后面在 \(timestamp) 还有相同或相似表达\(source)，按口播规则保留最后一遍。", confidence: min(1, score), wordIDs: candidate.wordIDs, retainedWordIDs: match.wordIDs, start: candidate.start, end: candidate.end))
        }
        return results.sorted { $0.start < $1.start }
    }

    static func deletedRanges(words: [TranscriptWord], breaths: [BreathCandidate], padding: Double = 0.05) -> [TimeRange] {
        let wordRanges = words.filter(\.isDeleted).map { TimeRange(start: max(0, $0.start - padding), end: $0.end + padding) }
        let breathRanges = breaths.filter { $0.state == .deleted }.map { TimeRange(start: $0.start, end: $0.end) }
        return merge(wordRanges + breathRanges)
    }

    static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var result: [TimeRange] = []
        for range in sorted.dropFirst() {
            if range.start <= current.end { current.end = max(current.end, range.end) }
            else { result.append(current); current = range }
        }
        result.append(current)
        return result
    }

    static func complement(of deleted: [TimeRange], duration: Double) -> [TimeRange] {
        var cursor = 0.0
        var kept: [TimeRange] = []
        for range in deleted {
            if range.start > cursor { kept.append(.init(start: cursor, end: min(duration, range.start))) }
            cursor = max(cursor, range.end)
        }
        if cursor < duration { kept.append(.init(start: cursor, end: duration)) }
        return kept.filter { $0.duration > 0.01 }
    }

    static func shortInternalFragments(in kept: [TimeRange], duration: Double, maximumDuration: Double = 0.35) -> [TimeRange] {
        kept.filter { $0.start > 0.01 && $0.end < duration - 0.01 && $0.duration <= maximumDuration }
    }

    static func outputTime(for sourceTime: Double, deleted: [TimeRange]) -> Double {
        sourceTime - deleted.reduce(0) { total, range in total + max(0, min(sourceTime, range.end) - range.start) }
    }

    static func sourceTime(for outputTime: Double, kept: [TimeRange]) -> Double {
        var cursor = 0.0
        for range in kept {
            if outputTime <= cursor + range.duration { return range.start + max(0, outputTime - cursor) }
            cursor += range.duration
        }
        return kept.last?.end ?? 0
    }

    static func detectBreaths(words: [TranscriptWord], threshold: Double) -> [BreathCandidate] {
        zip(words, words.dropFirst()).compactMap { left, right in
            guard right.start - left.end >= threshold else { return nil }
            return BreathCandidate(start: left.end, end: right.start, leftText: left.text, rightText: right.text)
        }
    }
}

@MainActor @Observable
final class EditorModel {
    enum MediaTab: String, CaseIterable { case assets = "素材", transcript = "文字稿" }
    enum BreathMode: String, Codable, CaseIterable { case confirm = "逐条确认", automatic = "自动删除" }
    enum DedupeMode: String, Codable, CaseIterable { case automatic = "自动去重", confirm = "逐条确认" }
    enum TaskState: Equatable { case idle, working(String), failed(String), done(String) }

    var player = AVPlayer()
    var videoURL: URL?
    var projectURL: URL?
    var projectName = "未命名项目"
    var duration = 0.0
    var frameRate = 25.0
    var words: [TranscriptWord] = []
    var suggestions: [EditSuggestion] = []
    var breaths: [BreathCandidate] = []
    var subtitleBreaks: Set<UUID> = []
    var subtitleJoins: Set<UUID> = []
    var waveform: [Float] = []
    var thumbnails: [Data] = []
    var trimStart = 0.0
    var trimEnd = 0.0
    var selectedWordIDs: [UUID] = []
    var exportProgress = 0.0
    var burnSubtitles = true
    var subtitleFontSize = 48.0
    var messages: [ChatMessage] = [.init(role: .assistant, text: "导入视频后，我会用 MiMo 生成逐词文字稿并提出可撤销的剪辑建议。")]
    var manuscript = ""
    var prompt = ""
    var taskState: TaskState = .idle
    var showImporter = false
    var showProjectImporter = false
    var showRelinkImporter = false
    var showExporter = false
    var showSettings = false
    var selectedTab = MediaTab.transcript
    var breathMode = BreathMode.confirm { didSet { applyBreathMode(); autosave() } }
    var dedupeMode = DedupeMode.confirm { didSet { autosave() } }
    var breathThreshold = 0.45 { didSet { refreshBreaths() } }
    var currentTime = 0.0
    var isPlaying = false
    var isChatWorking = false
    var reviewProgress: Double?
    var pendingReviewCorrections: [UUID: String] = [:]
    var hasUnsavedChanges = false
    var focusedWordID: UUID?
    var focusRequestID = UUID()
    var transientHighlightedWordIDs: Set<UUID> = []
    var transientHighlightedBreath: TimeRange?
    var transientHighlightOpacity = 0.0
    var storyboards: [StoryboardItem] = []
    var selectedStoryboardID: UUID?
    var storyboardSelectedWordIDs: Set<UUID> = []
    var storyboardSelectionAnchorID: UUID?

    @ObservationIgnored private var timeObserver: Any?
    private struct Snapshot { var words: [TranscriptWord]; var suggestions: [EditSuggestion]; var breaths: [BreathCandidate]; var subtitleBreaks: Set<UUID>; var subtitleJoins: Set<UUID>; var trimStart: Double; var trimEnd: Double; var manuscript: String; var storyboards: [StoryboardItem] }
    @ObservationIgnored private var undoStack: [Snapshot] = []
    @ObservationIgnored private var redoStack: [Snapshot] = []
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private var isRestoringProject = false
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored private var transientHighlightTask: Task<Void, Never>?

    init() { installPlayerObserver() }

    var isWorking: Bool { if case .working = taskState { true } else { isChatWorking } }
    var isExporting: Bool { exportTask != nil }
    var effectiveTrimEnd: Double { trimEnd > 0 ? min(duration, trimEnd) : duration }
    var deletedRanges: [TimeRange] {
        var ranges = TimelineEngine.deletedRanges(words: words, breaths: breaths)
        if trimStart > 0 { ranges.append(.init(start: 0, end: trimStart)) }
        if effectiveTrimEnd < duration { ranges.append(.init(start: effectiveTrimEnd, end: duration)) }
        return TimelineEngine.merge(ranges)
    }
    var keptRanges: [TimeRange] { TimelineEngine.complement(of: deletedRanges, duration: duration) }
    var shortFragments: [TimeRange] { TimelineEngine.shortInternalFragments(in: keptRanges, duration: duration) }
    var outputDuration: Double { keptRanges.reduce(0) { $0 + $1.duration } }
    var subtitleCues: [SubtitleCue] { TimelineEngine.subtitleCues(words: words, breakBefore: subtitleBreaks, joinBefore: subtitleJoins) }
    var activeSubtitle: SubtitleCue? { subtitleCues.first { currentTime >= $0.start && currentTime < $0.end && $0.end > trimStart && $0.start < effectiveTrimEnd } }
    var visibleSubtitleCues: [SubtitleCue] { subtitleCues.filter { $0.end > trimStart && $0.start < effectiveTrimEnd && TimelineEngine.outputTime(for: $0.end, deleted: deletedRanges) > TimelineEngine.outputTime(for: $0.start, deleted: deletedRanges) } }
    var edl: EditDecisionList? {
        guard let videoURL else { return nil }
        return .init(sourcePath: videoURL.path, sourceDuration: duration, frameRate: frameRate, deletedRanges: deletedRanges, keptRanges: keptRanges, words: words, suggestions: suggestions, breaths: breaths, subtitleBreaks: Array(subtitleBreaks), subtitleJoins: Array(subtitleJoins), burnSubtitles: burnSubtitles, subtitleFontSize: subtitleFontSize)
    }

    func importVideo(_ url: URL) async {
        taskState = .working("正在导入素材…")
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            taskState = .failed("无法导入：文件中没有可读取的视频轨道。")
            return
        }
        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        guard loadedDuration.isFinite, loadedDuration > 0 else {
            taskState = .failed("无法导入：视频时长无效。")
            return
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
        videoURL = url
        selectedWordIDs = []
        projectURL = nil
        burnSubtitles = true; subtitleFontSize = 48
        projectName = url.deletingPathExtension().lastPathComponent
        duration = loadedDuration
        trimStart = 0
        trimEnd = loadedDuration
        frameRate = Double((try? await track.load(.nominalFrameRate)) ?? 25)
        if !frameRate.isFinite || frameRate <= 0 { frameRate = 25 }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        await loadMediaVisuals(url)
        words = []
        manuscript = ""
        pendingReviewCorrections = [:]
        suggestions = []
        breaths = []
        subtitleBreaks = []
        subtitleJoins = []
        storyboards = []; selectedStoryboardID = nil; storyboardSelectedWordIDs = []; storyboardSelectionAnchorID = nil
        messages = [.init(role: .assistant, text: "这是“\(projectName)”项目的 AI 剪辑对话。转写或直接输入文字稿后，可以告诉我如何剪辑。")]
        messages.append(.init(role: .status, text: "已将 \(url.lastPathComponent) 加入素材库。下一步可以生成字幕。"))
        selectedTab = .assets
        taskState = .done("素材已导入")
        markChanged()
    }

    func resegment() {
        guard let videoURL else { return }
        if words.isEmpty {
            guard let document = TranscriptCache.load(videoURL: videoURL, identity: WhisperTranscriber.cacheIdentity) else {
                taskState = .failed("没有可用的逐字缓存，请点击“重新识别”。")
                return
            }
            words = document.words
            duration = max(duration, document.duration)
        }
        subtitleBreaks = []
        subtitleJoins = []
        pendingReviewCorrections = [:]
        refreshBreaths()
        taskState = .done("已按最新自然语言规则重新断句：\(subtitleCues.count) 条字幕")
        messages.append(.init(role: .status, text: "已使用现有逐字时间戳重新断句，未重新运行 WhisperKit。"))
        markChanged()
    }

    func resegmentWithMiMo() async {
        resegment()
        guard !words.isEmpty else { return }
        let service = MiMoSettings.current.serviceName
        taskState = .working("\(service) 正在为完整字幕文章调整换行…")
        let activeWords = words.filter { !$0.isDeleted }
        let article = activeWords.map(\.text).joined()
        do {
            let segmented = try await MiMoClient(settings: .current).segmentArticle(article)
            guard let result = TimelineEngine.applySegmentedArticle(segmented, to: words) else {
                throw MiMoError.invalidResponse("\(service) 改变了原始文字，已拒绝该结果。")
            }
            checkpoint()
            words = result.words
            let proposed = result.breaks.union(TimelineEngine.mandatorySentenceBreaks(in: activeWords))
            let refined = TimelineEngine.refinedSentenceBreaks(proposed, in: activeWords)
            let semanticFallbacks = Set(TimelineEngine.subtitleCues(words: activeWords).dropFirst().compactMap(\.wordIDs.first))
            let breaks = TimelineEngine.balancedSentenceBreaks(refined, candidates: proposed.union(semanticFallbacks), in: activeWords)
            subtitleBreaks = breaks
            subtitleJoins = Set(activeWords.map(\.id)).subtracting(breaks)
            pendingReviewCorrections = [:]
            refreshBreaths()
            taskState = .done("\(service) 断句完成：\(subtitleCues.count) 条字幕，逐字 UUID 和时间戳未改变")
            messages.append(.init(role: .status, text: "\(service) 已只通过调整换行重新断句，原始文字和标点校验通过。"))
            markChanged()
        } catch {
            taskState = .failed("\(service) 断句失败：\(error.localizedDescription)。已保留本地断句结果。")
        }
    }

    func transcribe(forceRecognition: Bool = false) async {
        guard let videoURL else { return }
        let oldStoryboardRanges = storyboards.map { ($0.id, storyboardSourceRange($0)) }
        if !forceRecognition, let document = TranscriptCache.load(videoURL: videoURL, identity: WhisperTranscriber.cacheIdentity) {
            words = document.words
            rebindStoryboards(using: oldStoryboardRanges)
            duration = max(duration, document.duration)
            refreshBreaths()
            subtitleBreaks = []
            subtitleJoins = []
            taskState = .done("已恢复缓存的逐字字幕：\(words.count) 个字")
            messages.append(.init(role: .status, text: "已从本机缓存恢复 \(words.count) 个逐字时间戳。"))
            markChanged()
            return
        }
        taskState = .working(forceRecognition ? "WhisperKit 正在重新识别全部音频…" : "WhisperKit 正在准备本地转写…")
        do {
            let document = try await WhisperTranscriber.shared.transcribe(videoURL: videoURL) { [weak self] status in
                self?.taskState = .working(status)
            }
            try TranscriptCache.save(document, videoURL: videoURL, identity: WhisperTranscriber.cacheIdentity)
            words = document.words
            rebindStoryboards(using: oldStoryboardRanges)
            duration = max(duration, document.duration)
            refreshBreaths()
            subtitleBreaks = []
            subtitleJoins = []
            taskState = .done("转写完成：\(words.count) 个字")
            messages.append(.init(role: .status, text: "WhisperKit 已在本机生成 \(words.count) 个逐字时间戳。"))
            markChanged()
        } catch { taskState = .failed(error.localizedDescription) }
    }

    func analyze() async {
        guard !words.isEmpty else { return }
        let repetitions = TimelineEngine.repetitionSuggestions(cues: subtitleCues, manuscript: manuscript)
        suggestions = repetitions
        taskState = .working("MiMo 正在分析口误…")
        do {
            let remote = try await MiMoEditClient(settings: .current).analyze(words: words)
            let repeatedIDs = Set(repetitions.flatMap(\.wordIDs))
            suggestions = repetitions + remote.filter { $0.type != .repetition || repeatedIDs.isDisjoint(with: $0.wordIDs) }
            taskState = .done("发现 \(suggestions.count) 条建议")
            messages.append(.init(role: .status, text: "发现 \(suggestions.count) 条建议，请逐项确认。"))
            markChanged()
        } catch {
            if repetitions.isEmpty { taskState = .failed(error.localizedDescription) }
            else {
                taskState = .done("已标记 \(repetitions.count) 条重复句；MiMo 其他分析暂时失败")
                messages.append(.init(role: .status, text: "已从后向前标记 \(repetitions.count) 条重复句，保留最后一遍。"))
                markChanged()
            }
        }
    }

    func seek(to time: Double) { currentTime = time; player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func preview(_ range: TimeRange) { seek(to: max(0, range.start - 1)); player.play() }
    func togglePlayback() { player.rate == 0 ? player.play() : player.pause() }

    func deleteWords(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        checkpoint()
        let targets = Set(ids)
        for index in words.indices where targets.contains(words[index].id) { words[index].isDeleted = true }
        reconcileStoryboardsAfterEdit()
        markChanged()
    }

    /// Removes transcript/subtitle data only. It never creates a cut in the media timeline.
    func deleteSubtitles(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        checkpoint()
        let targets = Set(ids)
        words.removeAll { targets.contains($0.id) }
        subtitleBreaks.subtract(targets)
        subtitleJoins.subtract(targets)
        suggestions.removeAll { !targets.isDisjoint(with: $0.wordIDs) }
        selectedWordIDs.removeAll { targets.contains($0) }
        refreshBreaths()
        reconcileStoryboardsAfterEdit()
        markChanged()
    }

    func selectSubtitle(_ cue: SubtitleCue, additive: Bool = false) {
        if additive {
            toggleSubtitleSelection(cue)
        } else { selectedWordIDs = cue.wordIDs }
        seek(to: cue.start)
    }
    func toggleSubtitleSelection(_ cue: SubtitleCue) {
        let cueIDs = Set(cue.wordIDs)
        if cueIDs.isSubset(of: Set(selectedWordIDs)) { selectedWordIDs.removeAll { cueIDs.contains($0) } }
        else { selectedWordIDs = Array(Set(selectedWordIDs).union(cueIDs)) }
    }
    func isSelected(_ cue: SubtitleCue) -> Bool { !Set(cue.wordIDs).isDisjoint(with: selectedWordIDs) }
    func selectAllSubtitles() { selectedWordIDs = subtitleCues.flatMap(\.wordIDs) }

    func focusSuggestion(_ item: EditSuggestion) {
        showTransientFocus(wordIDs: item.wordIDs, range: .init(start: item.start, end: item.end))
    }

    func focusBreath(_ item: BreathCandidate) {
        showTransientFocus(wordIDs: [], range: .init(start: item.start, end: item.end), isBreath: true)
    }

    func isTransientlyHighlighted(_ cue: SubtitleCue) -> Bool {
        !Set(cue.wordIDs).isDisjoint(with: transientHighlightedWordIDs)
    }

    private func showTransientFocus(wordIDs: [UUID], range: TimeRange, isBreath: Bool = false) {
        transientHighlightTask?.cancel()
        focusedWordID = wordIDs.first
        transientHighlightedWordIDs = Set(wordIDs)
        transientHighlightedBreath = isBreath ? range : nil
        transientHighlightOpacity = 1
        focusRequestID = UUID()
        seek(to: range.start)
        transientHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 1.1)) { self.transientHighlightOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self.transientHighlightedWordIDs = []
            self.transientHighlightedBreath = nil
        }
    }

    func editSubtitle(_ cue: SubtitleCue, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != cue.text else { return }
        let ids = Set(cue.wordIDs)
        let indices = words.indices.filter { ids.contains(words[$0].id) }
        guard let lower = indices.min(), let upper = indices.max() else { return }
        checkpoint()
        let keptBreak = subtitleBreaks.contains(words[lower].id)
        let keptJoin = subtitleJoins.contains(words[lower].id)
        let speaker = words[lower].speaker
        subtitleBreaks.subtract(ids)
        subtitleJoins.subtract(ids)
        suggestions.removeAll { !ids.isDisjoint(with: $0.wordIDs) }
        var replacement = MiMoASRClient.estimatedWords(text: cleaned, start: cue.start, duration: cue.end - cue.start)
        for index in replacement.indices { replacement[index].speaker = speaker }
        words.replaceSubrange(lower...upper, with: replacement)
        if keptBreak, let first = replacement.first { subtitleBreaks.insert(first.id) }
        if keptJoin, let first = replacement.first { subtitleJoins.insert(first.id) }
        selectedWordIDs = replacement.map(\.id)
        refreshBreaths()
        rebindStoryboardsByCurrentTime()
        markChanged()
    }

    func splitSubtitle(at time: Double) {
        let active = words.filter { !$0.isDeleted }
        guard let word = active.first(where: { $0.start >= time }), word.id != active.first?.id else { return }
        checkpoint()
        subtitleBreaks.insert(word.id)
        subtitleJoins.remove(word.id)
        markChanged()
    }

    func splitSubtitle(_ cue: SubtitleCue, text: String, atCharacterOffset offset: Int) {
        let characters = text.filter { !$0.isWhitespace }.map(String.init)
        guard offset > 0, offset < characters.count else { return }
        let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        let cueWords = cue.wordIDs.compactMap { wordsByID[$0] }
        var original = cueWords.map(\.text).joined().filter { !$0.isWhitespace }
        while let last = original.last, "，,。.".contains(last) { original.removeLast() }
        if original == characters.joined() {
            var consumed = 0
            for index in cueWords.indices.dropLast() {
                consumed += cueWords[index].text.filter { !$0.isWhitespace }.count
                guard consumed >= offset else { continue }
                if consumed == offset {
                    checkpoint()
                    subtitleBreaks.insert(cueWords[cueWords.index(after: index)].id)
                    subtitleJoins.remove(cueWords[cueWords.index(after: index)].id)
                    markChanged()
                    return
                }
                break
            }
        }
        let ids = Set(cue.wordIDs)
        let indices = words.indices.filter { ids.contains(words[$0].id) }
        guard let lower = indices.min(), let upper = indices.max() else { return }
        checkpoint()
        let speaker = words[lower].speaker
        let keptBreak = subtitleBreaks.contains(words[lower].id)
        let keptJoin = subtitleJoins.contains(words[lower].id)
        subtitleBreaks.subtract(ids)
        subtitleJoins.subtract(ids)
        suggestions.removeAll { !ids.isDisjoint(with: $0.wordIDs) }
        var replacement = MiMoASRClient.estimatedWords(text: characters.joined(), start: cue.start, duration: cue.end - cue.start)
        for index in replacement.indices { replacement[index].speaker = speaker }
        words.replaceSubrange(lower...upper, with: replacement)
        if keptBreak, let first = replacement.first { subtitleBreaks.insert(first.id) }
        if keptJoin, let first = replacement.first { subtitleJoins.insert(first.id) }
        if replacement.indices.contains(offset) { subtitleBreaks.insert(replacement[offset].id) }
        selectedWordIDs = replacement.map(\.id)
        refreshBreaths()
        rebindStoryboardsByCurrentTime()
        markChanged()
    }

    func mergeSubtitle(startingWith wordID: UUID?) {
        guard let wordID, let cueIndex = subtitleCues.firstIndex(where: { $0.wordIDs.first == wordID }), cueIndex > 0 else { return }
        checkpoint()
        subtitleBreaks.remove(wordID)
        subtitleJoins.insert(wordID)
        markChanged()
    }

    func resetTrim() { checkpoint(); trimStart = 0; trimEnd = duration; markChanged() }
    func beginTrimEdit() { checkpoint() }
    func updateTrimStart(_ time: Double) { trimStart = snapped(min(max(0, time), max(0, effectiveTrimEnd - 0.1))) }
    func updateTrimEnd(_ time: Double) { trimEnd = snapped(max(trimStart + 0.1, min(duration, time))) }
    func finishTrimEdit() { reconcileStoryboardsAfterEdit(); seek(to: max(trimStart, min(currentTime, effectiveTrimEnd))); markChanged() }

    private func snapped(_ time: Double) -> Double { frameRate > 0 ? (time * frameRate).rounded() / frameRate : time }

    func toggleWord(_ id: UUID) {
        checkpoint()
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        words[index].isDeleted.toggle()
        reconcileStoryboardsAfterEdit()
        markChanged()
    }

    func decide(_ id: UUID, delete: Bool) {
        checkpoint()
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        let type = suggestions[index].type
        let start = suggestions[index].start
        suggestions[index].state = delete ? .deleted : .kept
        if delete {
            let ids = Set(suggestions[index].wordIDs)
            for i in words.indices where ids.contains(words[i].id) { words[i].isDeleted = true }
            reconcileStoryboardsAfterEdit()
        }
        markChanged()
        if delete, type == .repetition { focusNextPendingRepetition(after: start) }
    }

    private func focusNextPendingRepetition(after start: Double) {
        let pending = suggestions.filter { $0.type == .repetition && $0.state == .pending }.sorted { $0.start < $1.start }
        guard let next = pending.first(where: { $0.start > start }) ?? pending.first else {
            taskState = .done("全部重复字幕已处理完成")
            return
        }
        focusSuggestion(next)
    }

    func decideAll(delete: Bool) { for item in suggestions where item.state == .pending { decide(item.id, delete: delete) } }
    func decideBreath(_ id: UUID, delete: Bool) { checkpoint(); if let i = breaths.firstIndex(where: { $0.id == id }) { breaths[i].state = delete ? .deleted : .kept; reconcileStoryboardsAfterEdit(); markChanged() } }

    func cleanupShortFragments() {
        let fragments = shortFragments
        guard !fragments.isEmpty else { taskState = .done("没有发现需要清理的碎片"); return }
        checkpoint()
        breaths += fragments.map { BreathCandidate(start: $0.start, end: $0.end, leftText: "碎片", rightText: "碎片", state: .deleted) }
        reconcileStoryboardsAfterEdit()
        taskState = .done("已清理 \(fragments.count) 个小于 0.35 秒的孤立片段，可用 ⌘Z 撤销")
        markChanged()
    }

    func storyboardSourceRange(_ item: StoryboardItem) -> TimeRange {
        let ids = Set(item.wordIDs)
        let anchored = words.filter { ids.contains($0.id) && !$0.isDeleted }
        guard let first = anchored.first, let last = anchored.last else { return .init(start: item.fallbackStart, end: item.fallbackEnd) }
        return .init(start: first.start, end: last.end)
    }

    func storyboardOutputRange(_ item: StoryboardItem) -> TimeRange {
        let source = storyboardSourceRange(item)
        return .init(start: TimelineEngine.outputTime(for: source.start, deleted: deletedRanges), end: TimelineEngine.outputTime(for: source.end, deleted: deletedRanges))
    }

    func storyboardSubtitle(_ item: StoryboardItem) -> String {
        let ids = Set(item.wordIDs)
        return TimelineEngine.subtitleDisplayText(words.filter { ids.contains($0.id) && !$0.isDeleted }.map(\.text).joined())
    }

    func selectStoryboard(_ item: StoryboardItem) { selectedStoryboardID = item.id; seek(to: storyboardSourceRange(item).start) }

    func selectStoryboardCue(_ cue: SubtitleCue, extending: Bool) {
        let cues = visibleSubtitleCues
        if extending, let anchor = storyboardSelectionAnchorID,
           let a = cues.firstIndex(where: { $0.wordIDs.contains(anchor) }), let b = cues.firstIndex(where: { $0.id == cue.id }) {
            storyboardSelectedWordIDs = Set(cues[min(a, b)...max(a, b)].flatMap(\.wordIDs))
        } else {
            storyboardSelectedWordIDs = Set(cue.wordIDs)
            storyboardSelectionAnchorID = cue.wordIDs.first
        }
        seek(to: cue.start)
    }

    func updateStoryboard(_ id: UUID, _ change: (inout StoryboardItem) -> Void) {
        guard let index = storyboards.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); change(&storyboards[index]); markChanged()
    }

    func replaceStoryboard(_ item: StoryboardItem) {
        guard let index = storyboards.firstIndex(where: { $0.id == item.id }), storyboards[index] != item else { return }
        checkpoint(); storyboards[index] = item; markChanged()
    }

    func deleteStoryboard(_ id: UUID) {
        guard storyboards.contains(where: { $0.id == id }) else { return }
        checkpoint(); storyboards.removeAll { $0.id == id }; if selectedStoryboardID == id { selectedStoryboardID = nil }; markChanged()
    }

    func generateStoryboards(selectedOnly: Bool = false) async {
        guard !isWorking else { return }
        let all = visibleSubtitleCues
        let cues = selectedOnly ? all.filter { !Set($0.wordIDs).isDisjoint(with: storyboardSelectedWordIDs) } : all
        guard !cues.isEmpty else { taskState = .failed(selectedOnly ? "请先在字幕轨道选择连续字幕范围。" : "没有可用于生成分镜的字幕。"); return }
        let service = MiMoSettings.current.serviceName
        isChatWorking = true; reviewProgress = 0.08; taskState = .working("\(service) 正在设计分镜 8%…")
        do {
            let generated = try await MiMoClient(settings: .current).generateStoryboards(cues: cues) { [weak self] value in
                Task { @MainActor in self?.reviewProgress = value; self?.taskState = .working("\(service) 正在设计分镜 \(Int(value * 100))%…") }
            }
            guard !generated.isEmpty else { throw MiMoError.invalidResponse("没有生成可用的分镜") }
            checkpoint()
            if selectedOnly, let first = cues.first, let last = cues.last {
                storyboards.removeAll { storyboardSourceRange($0).start < last.end && storyboardSourceRange($0).end > first.start }
            } else { storyboards.removeAll() }
            storyboards += generated
            storyboards.sort { storyboardSourceRange($0).start < storyboardSourceRange($1).start }
            selectedStoryboardID = generated.first?.id
            reviewProgress = nil; isChatWorking = false
            taskState = .done("已生成 \(generated.count) 条实拍/MG 分镜参考")
            markChanged()
        } catch {
            reviewProgress = nil; isChatWorking = false; taskState = .failed("分镜生成失败：\(error.localizedDescription)")
        }
    }

    func regenerateStoryboard(_ id: UUID) async {
        guard let item = storyboards.first(where: { $0.id == id }), !isWorking else { return }
        let range = storyboardSourceRange(item)
        let cues = visibleSubtitleCues.filter { $0.start < range.end && $0.end > range.start }
        guard !cues.isEmpty else { return }
        isChatWorking = true; taskState = .working("正在重新设计这一条分镜…")
        do {
            let generated = try await MiMoClient(settings: .current).generateStoryboards(cues: cues)
            guard !generated.isEmpty else { throw MiMoError.invalidResponse("没有生成可用的分镜") }
            checkpoint(); storyboards.removeAll { $0.id == id }; storyboards += generated; selectedStoryboardID = generated.first?.id
            isChatWorking = false; taskState = .done("这一条分镜已重新生成"); markChanged()
        } catch { isChatWorking = false; taskState = .failed("重新生成失败：\(error.localizedDescription)") }
    }

    private func reconcileStoryboardsAfterEdit() {
        storyboards = storyboards.compactMap { item in
            // Re-recognition may leave a storyboard anchored only by its source-time fallback.
            // Keep that item through unrelated edits until a later recognition or redesign can rebind it.
            if item.wordIDs.isEmpty {
                let outputStart = TimelineEngine.outputTime(for: item.fallbackStart, deleted: deletedRanges)
                let outputEnd = TimelineEngine.outputTime(for: item.fallbackEnd, deleted: deletedRanges)
                return outputEnd > outputStart ? item : nil
            }
            let ids = Set(item.wordIDs)
            let surviving = words.filter { ids.contains($0.id) && !$0.isDeleted }
            guard let first = surviving.first, let last = surviving.last else { return nil }
            var item = item; item.wordIDs = surviving.map(\.id); item.fallbackStart = first.start; item.fallbackEnd = last.end
            let outputStart = TimelineEngine.outputTime(for: first.start, deleted: deletedRanges)
            let outputEnd = TimelineEngine.outputTime(for: last.end, deleted: deletedRanges)
            return outputEnd > outputStart ? item : nil
        }
        if let selectedStoryboardID, !storyboards.contains(where: { $0.id == selectedStoryboardID }) { self.selectedStoryboardID = nil }
    }

    func rebindStoryboards(using ranges: [(UUID, TimeRange)]) {
        for index in storyboards.indices {
            let range = ranges.first(where: { $0.0 == storyboards[index].id })?.1 ?? storyboardSourceRange(storyboards[index])
            storyboards[index].fallbackStart = range.start; storyboards[index].fallbackEnd = range.end
            storyboards[index].wordIDs = words.filter { !$0.isDeleted && $0.start < range.end && $0.end > range.start }.map(\.id)
        }
    }

    private func rebindStoryboardsByCurrentTime() {
        rebindStoryboards(using: storyboards.map { ($0.id, .init(start: $0.fallbackStart, end: $0.fallbackEnd)) })
    }

    func executeDedupe() {
        let repetitions = TimelineEngine.repetitionSuggestions(cues: subtitleCues, manuscript: manuscript)
        suggestions.removeAll { $0.type == .repetition && $0.state == .pending }
        guard !repetitions.isEmpty else {
            taskState = .done("未发现可确认的重复句")
            messages.append(.init(role: .assistant, text: "已从后往前检查：未发现相似度足够高的重复句，没有修改时间线。"))
            return
        }
        checkpoint()
        switch dedupeMode {
        case .automatic:
            let ids = Set(repetitions.flatMap(\.wordIDs))
            for index in words.indices where ids.contains(words[index].id) { words[index].isDeleted = true }
            reconcileStoryboardsAfterEdit()
            suggestions += repetitions.map { item in var item = item; item.state = .deleted; return item }
            messages.append(.init(role: .assistant, text: "已从后往前去重 \(repetitions.count) 处：每组保留时间线上最后一遍，早期重复已标记为删除，可用 ⌘Z 撤销。"))
            taskState = .done("已自动去重 \(repetitions.count) 处")
        case .confirm:
            suggestions += repetitions
            messages.append(.init(role: .assistant, text: "已从后往前找到 \(repetitions.count) 处重复句。我保留每组最后一遍，并把较早的版本放在这里逐条确认。"))
            taskState = .done("已生成 \(repetitions.count) 条去重建议")
        }
        markChanged()
    }

    func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(snapshot); restore(previous); markChanged() }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(snapshot); restore(next); markChanged() }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func reviewManuscript() async {
        let reference = manuscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeWords = words.filter { !$0.isDeleted }
        guard !reference.isEmpty, !activeWords.isEmpty, !isWorking else { return }
        let service = MiMoSettings.current.serviceName
        isChatWorking = true
        reviewProgress = 0.1
        taskState = .working("\(service) 审阅中 10%：正在准备去重后的文字稿和字幕…")
        let status = ChatMessage(role: .status, text: "\(service) 正在分块审阅去重后的字幕…")
        messages.append(status)
        do {
            reviewProgress = 0.35
            taskState = .working("\(service) 审阅中 35%：正在并发对照 Word 稿查找明显错误…")
            let corrections = try await MiMoClient(settings: .current).correct(reference: reference, cues: subtitleCues, words: activeWords)
            reviewProgress = 0.9
            taskState = .working("\(service) 审阅中 90%：正在生成红色修改标记…")
            pendingReviewCorrections = corrections
            messages.removeAll { $0.id == status.id }
            messages.append(.init(role: .assistant, text: corrections.isEmpty ? "已对照 Word 稿审阅，没有发现可确定的识别错误。" : "已找到 \(corrections.count) 处明显错误，已用红色标出。请选择“采用”或“取消”；当前还没有改动字幕。"))
            reviewProgress = 1
            taskState = .done("审阅完成 100%：待确认 \(corrections.count) 处修改")
        } catch {
            messages.removeAll { $0.id == status.id }
            messages.append(.init(role: .status, text: "审阅失败：\(error.localizedDescription)"))
            taskState = .failed("审阅失败：\(error.localizedDescription)")
        }
        isChatWorking = false
        reviewProgress = nil
    }

    func acceptReview() {
        guard !pendingReviewCorrections.isEmpty else { return }
        checkpoint()
        for index in words.indices where !words[index].isDeleted {
            if let corrected = pendingReviewCorrections[words[index].id] { words[index].text = corrected }
        }
        let count = pendingReviewCorrections.count
        pendingReviewCorrections = [:]
        messages.append(.init(role: .status, text: "已采用 \(count) 处字幕修正。"))
        markChanged()
    }

    func cancelReview() {
        let count = pendingReviewCorrections.count
        pendingReviewCorrections = [:]
        messages.append(.init(role: .status, text: "已取消 \(count) 处字幕修正，原字幕未改变。"))
    }

    func sendPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        prompt = ""
        messages.append(.init(role: .user, text: text))
        isChatWorking = true
        let status = ChatMessage(role: .status, text: "\(MiMoSettings.current.serviceName) 正在处理指令…")
        messages.append(status)
        do {
            if !words.isEmpty && (text.count > 200 || text.contains("以字幕稿为准") || text.contains("修正字幕")) {
                let corrections = try await MiMoClient(settings: .current).correct(reference: text, words: words)
                checkpoint()
                for index in words.indices where !words[index].isDeleted {
                    if let corrected = corrections[words[index].id] { words[index].text = corrected }
                }
                markChanged()
                messages.append(.init(role: .assistant, text: corrections.isEmpty ? "已对照参考稿检查，没有发现需要确定修正的识别错误。" : "已按现有字幕时间轴完成校对，修正了 \(corrections.count) 处文字；没有新增、删除或重排字幕。"))
            } else {
                let reply = try await MiMoClient(settings: .current).chat(instruction: text, transcript: timestampedTranscript)
                messages.removeAll { $0.id == status.id }
                messages.append(.init(role: .assistant, text: reply))
            }
            messages.removeAll { $0.id == status.id }
            messages.append(.init(role: .status, text: "指令已完成"))
        } catch {
            messages.removeAll { $0.id == status.id }
            messages.append(.init(role: .status, text: "请求失败：\(error.localizedDescription)"))
        }
        isChatWorking = false
        markChanged()
    }

    var timestampedTranscript: String {
        words.isEmpty ? manuscript : words.map { "[\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end))] id=\($0.id.uuidString) \($0.text)" }.joined(separator: "\n")
    }

    func newProject() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        videoURL = nil; projectURL = nil; projectName = "未命名项目"; duration = 0; frameRate = 25; trimStart = 0; trimEnd = 0; selectedWordIDs = []; burnSubtitles = true; subtitleFontSize = 48
        words = []; manuscript = ""; pendingReviewCorrections = [:]; suggestions = []; breaths = []; subtitleBreaks = []; subtitleJoins = []; waveform = []; thumbnails = []; storyboards = []; selectedStoryboardID = nil; storyboardSelectedWordIDs = []; storyboardSelectionAnchorID = nil; messages = [.init(role: .assistant, text: "导入视频后，我会用 MiMo 生成逐词文字稿并提出可撤销的剪辑建议。")]; undoStack = []; redoStack = []; hasUnsavedChanges = false
    }

    func save(to url: URL? = nil) throws {
        let destination = url ?? projectURL ?? ProjectStore.defaultURL(for: projectName)
        let bookmark = try videoURL?.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let document = ProjectDocument(name: projectName, sourcePath: videoURL?.path ?? "", sourceBookmark: bookmark, transcript: words.isEmpty ? nil : .init(assetID: videoURL?.lastPathComponent ?? "", duration: duration, words: words), suggestions: suggestions, breaths: breaths, breathMode: breathMode, dedupeMode: dedupeMode, frameRate: frameRate, manuscript: manuscript, messages: messages, subtitleBreaks: Array(subtitleBreaks), subtitleJoins: Array(subtitleJoins), trimStart: trimStart, trimEnd: effectiveTrimEnd, sourceDuration: duration, burnSubtitles: burnSubtitles, subtitleFontSize: subtitleFontSize, playhead: currentTime, storyboards: storyboards)
        try ProjectStore.save(document, to: destination)
        projectURL = destination
        hasUnsavedChanges = false
        UserDefaults.standard.set(destination.path, forKey: "recentProject")
    }

    func openProject(_ url: URL) async throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let document = try ProjectStore.load(from: url)
        isRestoringProject = true
        defer { isRestoringProject = false }
        player.pause()
        player.replaceCurrentItem(with: nil)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        videoURL = nil
        selectedWordIDs = []
        pendingReviewCorrections = [:]
        projectURL = url; projectName = document.name; frameRate = document.frameRate; suggestions = document.suggestions; breaths = document.breaths; breathMode = document.breathMode; dedupeMode = document.dedupeMode ?? .confirm
        words = document.transcript?.words ?? []; duration = document.sourceDuration ?? document.transcript?.duration ?? 0
        trimStart = document.trimStart ?? 0; trimEnd = document.trimEnd ?? duration
        burnSubtitles = document.burnSubtitles ?? true; subtitleFontSize = document.subtitleFontSize ?? 48
        currentTime = min(duration, max(0, document.playhead ?? trimStart))
        subtitleBreaks = Set(document.subtitleBreaks ?? [])
        subtitleJoins = Set(document.subtitleJoins ?? [])
        manuscript = document.manuscript ?? ""
        messages = document.messages ?? [.init(role: .assistant, text: "已打开项目“\(document.name)”。")]
        storyboards = document.storyboards ?? []
        selectedStoryboardID = nil; storyboardSelectedWordIDs = []; storyboardSelectionAnchorID = nil
        undoStack = []; redoStack = []; hasUnsavedChanges = false
        var source = URL(fileURLWithPath: document.sourcePath)
        if let bookmark = document.sourceBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) { source = resolved }
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            showRelinkImporter = true
            taskState = .failed("找不到原始视频，请重新定位素材。")
            return
        }
        var repairedBlankWords = 0
        if let cached = TranscriptCache.load(videoURL: source, identity: WhisperTranscriber.cacheIdentity) {
            let repair = TimelineEngine.restoringBlankWords(words, from: cached.words)
            words = repair.words
            repairedBlankWords = repair.count
        }
        if source.startAccessingSecurityScopedResource() { securityScopedURL = source }
        videoURL = source; player.replaceCurrentItem(with: AVPlayerItem(url: source)); seek(to: currentTime); await loadMediaVisuals(source); hasUnsavedChanges = false
        if repairedBlankWords > 0 {
            messages.append(.init(role: .status, text: "已从 WhisperKit 原始缓存修复 \(repairedBlankWords) 个异常空白字符。"))
            try? save()
        }
    }

    func relinkSource(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
            taskState = .failed("重新定位失败：文件中没有可读取的视频轨道。")
            return
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
        videoURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        await loadMediaVisuals(url)
        taskState = .done("素材已重新定位")
        hasUnsavedChanges = true
        try? save()
    }

    func autosave() { guard !isRestoringProject, hasUnsavedChanges, videoURL != nil else { return }; try? save() }

    func updateManuscript(_ text: String) { manuscript = text; hasUnsavedChanges = true; autosave() }
    func cancelExport() { exportTask?.cancel() }
    func setBurnSubtitles(_ enabled: Bool) { burnSubtitles = enabled; markChanged() }
    func setSubtitleFontSize(_ size: Double) { subtitleFontSize = min(80, max(24, size)); markChanged() }

    func renameProject(_ url: URL, to name: String) throws {
        let destination = try ProjectStore.rename(url, to: name)
        if projectURL == url { projectURL = destination; projectName = destination.deletingPathExtension().lastPathComponent }
    }

    func deleteProject(_ url: URL) throws {
        try ProjectStore.moveToTrash(url)
        if projectURL == url { newProject() }
    }

    private func refreshBreaths() {
        var old: [String: BreathCandidate.State] = [:]
        for breath in breaths { old["\(breath.start)-\(breath.end)"] = breath.state }
        breaths = TimelineEngine.detectBreaths(words: words, threshold: breathThreshold)
        for i in breaths.indices { breaths[i].state = old["\(breaths[i].start)-\(breaths[i].end)"] ?? (breathMode == .automatic ? .deleted : .pending) }
    }
    private func applyBreathMode() { if breathMode == .automatic { for i in breaths.indices where breaths[i].state == .pending { breaths[i].state = .deleted } } }
    private var snapshot: Snapshot { .init(words: words, suggestions: suggestions, breaths: breaths, subtitleBreaks: subtitleBreaks, subtitleJoins: subtitleJoins, trimStart: trimStart, trimEnd: trimEnd, manuscript: manuscript, storyboards: storyboards) }
    private func restore(_ value: Snapshot) { words = value.words; suggestions = value.suggestions; breaths = value.breaths; subtitleBreaks = value.subtitleBreaks; subtitleJoins = value.subtitleJoins; trimStart = value.trimStart; trimEnd = value.trimEnd; manuscript = value.manuscript; storyboards = value.storyboards }
    private func checkpoint() { undoStack.append(snapshot); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack.removeAll() }
    private func markChanged() { hasUnsavedChanges = true; autosave() }
    private func installPlayerObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate != 0
                if let cut = self.deletedRanges.first(where: { self.currentTime >= $0.start && self.currentTime < $0.end }) { self.seek(to: cut.end) }
            }
        }
    }
    private func loadMediaVisuals(_ url: URL) async {
        waveform = (try? await AudioWaveform.samples(videoURL: url)) ?? []
        thumbnails = (try? await VideoThumbnails.jpegData(videoURL: url)) ?? []
    }
}
