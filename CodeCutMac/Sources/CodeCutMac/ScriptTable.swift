import Foundation

/// 分镜稿表格：用户在文稿页里导入、修改的分镜稿。
///
/// 为什么不是一段纯文本：分镜稿本来就是表（文稿 / 分镜 / 镜头类型 / 是否拍摄 / 备注），
/// 表格能直接改内容、调列宽行高，导出还是 CSV，来回都不丢结构。
struct ScriptTable: Codable, Equatable, Sendable {
    var headers: [String] = []
    var rows: [[String]] = []
    /// 列宽／行高按索引存，跟着项目走；改了下次打开还是这个宽度。
    var columnWidths: [Double] = []
    var rowHeights: [Double] = []
    var sourcePath: String? = nil
    var importedAt: Date? = nil
    /// 上一次「按口播对时间」写进来时的口播指纹。有签名才说明时间列是我们生成的、可以自动刷新；
    /// 用户自己导入或手写的「时间」列没有签名，自动对齐不去动它。
    var timeColumnSignature: String? = nil

    static let defaultColumnWidth = 150.0
    /// 第一列通常是台词，给宽一点，不然一进来每行都被截断。
    static let firstColumnWidth = 360.0
    static let defaultRowHeight = 46.0
    static let minimumColumnWidth = 60.0
    static let minimumRowHeight = 24.0
    static let maximumColumnWidth = 1200.0
    static let maximumRowHeight = 600.0

    var isEmpty: Bool { headers.isEmpty && rows.isEmpty }
    var columnCount: Int { max(headers.count, rows.map(\.count).max() ?? 0) }
    var rowCount: Int { rows.count }

    func width(_ column: Int) -> Double {
        guard column >= 0, column < columnWidths.count, columnWidths[column] > 0 else {
            return column == 0 ? Self.firstColumnWidth : Self.defaultColumnWidth
        }
        return columnWidths[column]
    }

    func height(_ row: Int) -> Double {
        guard row >= 0, row < rowHeights.count, rowHeights[row] > 0 else { return Self.defaultRowHeight }
        return rowHeights[row]
    }

    func header(_ column: Int) -> String {
        column < headers.count ? headers[column] : ""
    }

    /// 哪一列是台词：按表头认（文稿 / 台词 / 口播 / 文案 / 解说 / 旁白），认不出来就按约定当第一列。
    var scriptColumn: Int {
        let keys = ["文稿", "台词", "口播", "文案", "解说", "旁白"]
        if let index = headers.firstIndex(where: { header in keys.contains { header.contains($0) } }) { return index }
        return 0
    }

    /// 按表头关键词找列（「镜头类型」「分镜」这类）：找不到就是 nil，调用方自己决定要不要兜底。
    func column(matching keywords: [String]) -> Int? {
        headers.firstIndex { header in keywords.contains { header.contains($0) } }
    }

    /// 取值永远不越界：表格是先有数据的，缺的地方当空字符串。
    func cell(_ row: Int, _ column: Int) -> String {
        guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else { return "" }
        return rows[row][column]
    }

    /// 把行补成等宽、把宽高数组补够，后面所有下标访问就都不用判断了。
    mutating func normalize() {
        // 空表就保持空：硬凑一格会让「这个项目没有分镜稿」变成「有一列空白」。
        guard !isEmpty else {
            headers = []; rows = []; columnWidths = []; rowHeights = []
            return
        }
        let count = max(1, columnCount)
        if headers.count < count { headers += Array(repeating: "", count: count - headers.count) }
        headers = Array(headers.prefix(count))
        rows = rows.map { $0.count >= count ? Array($0.prefix(count)) : $0 + Array(repeating: "", count: count - $0.count) }
        if columnWidths.count != count {
            columnWidths = (0..<count).map { index in
                index < columnWidths.count && columnWidths[index] > 0
                    ? columnWidths[index]
                    : (index == 0 ? Self.firstColumnWidth : Self.defaultColumnWidth)
            }
        }
        if rowHeights.count != rows.count {
            rowHeights = (0..<rows.count).map { index in
                index < rowHeights.count && rowHeights[index] > 0 ? rowHeights[index] : Self.defaultRowHeight
            }
        }
    }
}

// MARK: - CSV

/// 分镜稿的 CSV 读写。引号里的逗号、换行、双引号都按 RFC 4180 处理——
/// 分镜稿的第一列是整句话，里面本来就有逗号，简单按逗号切会直接把行切碎。
enum ScriptTableCSV {
    static func parse(_ text: String) -> [[String]] {
        // 换行先归一化：Swift 把 "\r\n" 当成一个字符，直接逐字符判断会漏掉 Excel 的换行。
        let normalized = text
            .trimmingPrefix("\u{FEFF}")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let characters = Array(normalized)
        var index = 0
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }
            switch character {
            case "\"": inQuotes = true; index += 1
            case ",": endField(); index += 1
            case "\n": endRow(); index += 1
            default: field.append(character); index += 1
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        while let last = rows.last, last.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.removeLast() }
        return rows
    }

    static func encode(_ grid: [[String]]) -> String {
        grid.map { row in
            row.map { field -> String in
                let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
                guard needsQuotes else { return field }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// 第一行当表头，其余当数据。
    static func table(fromCSV text: String) -> ScriptTable {
        let grid = parse(text)
        guard let header = grid.first else { return ScriptTable() }
        var table = ScriptTable(headers: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(grid.dropFirst()))
        if table.headers.allSatisfy({ $0.isEmpty }) {
            // 没有表头的文件不要硬塞一行空表头，给一套能读的名字。
            table.headers = (0..<max(1, header.count)).map { "第 \($0 + 1) 列" }
        }
        table.normalize()
        table.importedAt = Date()
        return table
    }

    static func csv(from table: ScriptTable) -> String {
        encode([table.headers] + table.rows)
    }

    /// 纯文本兜底：以前贴在文稿页里的那种一行一句的分镜稿，按行搬进第一列，内容不丢。
    static func table(fromPlainText text: String) -> ScriptTable {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ScriptTable() }
        var table = ScriptTable(headers: ["分镜稿"], rows: lines.map { [$0] })
        table.normalize()
        return table
    }
}

// MARK: - 分镜行对口播时间

/// 把分镜稿的一行台词对回口播（逐词文字稿），得到这句话在成片里的时间区间。
///
/// 为什么不用 `contains`：识别稿和分镜稿本来就对不齐——同音字、重复字、
/// 英文大小写和空格（识别成 `Pocket 三 3`、分镜写 `pocket3`）、漏字多字都会让包含查找直接失败。
/// 这里用局部对齐（Smith-Waterman：一致 +3、不一致 -1、空位 -2）在识别稿里找“最像这一行”的连续区间，
/// 再用覆盖率判断这一行到底是不是口播里说过的话：覆盖率够就是有时间，不够就返回 nil（调用方留空）。
enum ScriptTimeMatcher {
    /// 识别稿里的一个词。时间已经是成片时间（删掉的段落已经扣掉），调用方负责换算。
    struct Word: Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Input: Sendable, Equatable {
        var words: [Word]
    }

    /// 对齐结果：start/end 是成片时间，coverage 是这一行有多少字在口播里找到了。
    struct Match: Sendable, Equatable {
        var start: Double
        var end: Double
        var coverage: Double
    }

    /// 覆盖率下限：低于这个值的行算“口播里没有这句”，留空。
    /// 真实素材上对上的行都在 0.67 以上，随便编一句不存在的词只有 0.1–0.2，中间有很宽的安全区。
    static let minimumCoverage = 0.5
    /// 「时间」列一进来别太窄，`00:00.0–00:00.0` 要放得下。
    static let defaultColumnWidth = 132.0

    /// 逐行对齐：返回的数组和 scripts 一一对应，nil 表示这一行口播里没有。
    static func matchAll(scripts: [String], input: Input) -> [Match?] {
        let document = Document(input: input)
        return scripts.map { match(script: $0, in: document) }
    }

    static func match(script: String, in document: Document) -> Match? {
        let needle = normalized(script)
        guard !needle.isEmpty, !document.chars.isEmpty else { return nil }
        // 一两个字的行（“好”“OK”）到处都是，只能在识别稿里找连续完全一致的。
        guard needle.count >= 3 else { return exactMatch(needle, in: document) }
        var best: Alignment?
        for window in candidateWindows(for: needle, in: document) {
            guard let alignment = align(needle, in: document, window: window) else { continue }
            if best == nil || alignment.score > best!.score { best = alignment }
        }
        guard let best, isConfident(best, needleCount: needle.count) else { return nil }
        return Match(
            start: document.starts[best.start],
            end: document.ends[best.end],
            coverage: Double(best.matched) / Double(needle.count)
        )
    }

    /// 表格里存的时间文本：`00:03.2–00:07.6`。
    static func timeText(_ match: Match) -> String { "\(clock(match.start))–\(clock(match.end))" }

    /// 把「时间」列里的文本读回秒。排 B-roll 要用它拿这一段台词的起止时间。
    static func timeRange(_ text: String) -> (start: Double, end: Double)? {
        let parts = text.split(whereSeparator: { "–—-~～".contains($0) })
        guard parts.count == 2, let start = seconds(String(parts[0])), let end = seconds(String(parts[1])), end > start else { return nil }
        return (start, end)
    }

    private static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let secs = Double(parts[1]) else { return nil }
        return minutes * 60 + secs
    }

    /// 分:秒.十分位。先换算成十分位再进位，59.96 秒不会显示成 `00:60.0`。
    static func clock(_ value: Double) -> String {
        let tenths = max(0, Int((value * 10).rounded()))
        return String(format: "%02d:%04.1f", tenths / 600, Double(tenths % 600) / 10)
    }

    // MARK: 归一化

    /// 对齐只比对“字”：全角转半角、英文转小写、数字和汉字数字统一，标点、空格、换行全部丢掉。
    /// 两边用的是同一套规则，所以不会因为规则本身把本来一致的句子判成不一致。
    static func normalized(_ text: String) -> [Character] {
        var characters: [Character] = []
        for character in text.folding(options: [.widthInsensitive, .diacriticInsensitive], locale: nil).lowercased() {
            guard character.isNumber || character.isLetter else { continue }
            characters.append(chineseNumeral(character) ?? character)
        }
        return characters
    }

    /// 汉字数字和阿拉伯数字混着写的两种版本（`Pocket三3` / `pocket3`、`三块` / `3 块`）也能对上。
    private static func chineseNumeral(_ character: Character) -> Character? {
        switch character {
        case "零": return "0"
        case "一": return "1"
        case "二", "两": return "2"
        case "三": return "3"
        case "四": return "4"
        case "五": return "5"
        case "六": return "6"
        case "七": return "7"
        case "八": return "8"
        case "九": return "9"
        default: return nil
        }
    }

    // MARK: 识别稿

    /// 识别稿逐字展开：每个字带着自己所属词的时间（成片时间），外加 3 字 / 2 字的索引，
    /// 用来先圈出“大概在哪儿”的候选区间，避免每行都在整篇上做动态规划。
    struct Document: Sendable {
        private(set) var chars: [Character] = []
        private(set) var starts: [Double] = []
        private(set) var ends: [Double] = []
        private var trigrams: [String: [Int]] = [:]
        private var bigrams: [String: [Int]] = [:]

        init(input: Input) {
            for word in input.words {
                for character in ScriptTimeMatcher.normalized(word.text) {
                    chars.append(character)
                    starts.append(word.start)
                    ends.append(word.end)
                }
            }
            trigrams = Self.index(gramSize: 3, chars: chars)
            bigrams = Self.index(gramSize: 2, chars: chars)
        }

        private static func index(gramSize: Int, chars: [Character]) -> [String: [Int]] {
            guard chars.count >= gramSize else { return [:] }
            var table: [String: [Int]] = [:]
            for position in 0...(chars.count - gramSize) {
                table[String(chars[position..<(position + gramSize)]), default: []].append(position)
            }
            return table
        }

        fileprivate func positions(of gram: String, gramSize: Int) -> [Int] {
            (gramSize == 3 ? trigrams[gram] : bigrams[gram]) ?? []
        }
    }

    private struct Alignment: Equatable {
        var score = 0
        var matched = 0
        var start = 0
        var end = 0
    }

    // MARK: 候选区间

    /// 先用 3 字组合圈候选区间；一个都没撞上说明这一行跟识别稿差得远，退一步用 2 字组合再试一次。
    private static func candidateWindows(for needle: [Character], in document: Document) -> [Range<Int>] {
        let candidates = windows(needle: needle, in: document, gramSize: 3, limit: 5)
        if !candidates.isEmpty { return candidates }
        return windows(needle: needle, in: document, gramSize: 2, limit: 5)
    }

    private static func windows(needle: [Character], in document: Document, gramSize: Int, limit: Int) -> [Range<Int>] {
        guard needle.count >= gramSize else { return [] }
        // 常见组合（“我们就…”）到处都有，用它圈区间只会圈出一堆噪声。
        let maximumHits = 400
        var hits: [Int] = []
        var seen = Set<String>()
        for start in 0...(needle.count - gramSize) {
            let gram = String(needle[start..<(start + gramSize)])
            guard seen.insert(gram).inserted else { continue }
            let positions = document.positions(of: gram, gramSize: gramSize)
            guard !positions.isEmpty, positions.count <= maximumHits else { continue }
            hits.append(contentsOf: positions)
        }
        guard !hits.isEmpty else { return [] }
        hits.sort()

        // 位置挨得近的算一簇；一簇跨度太大就断开，保证每个窗口的规模可控。
        let slack = max(24, needle.count)
        let span = max(160, needle.count * 8)
        var clusters: [(low: Int, high: Int, hits: Int)] = []
        for position in hits {
            if var last = clusters.last, position - last.high <= slack, position - last.low <= span {
                last.high = position
                last.hits += 1
                clusters[clusters.count - 1] = last
            } else {
                clusters.append((position, position, 1))
            }
        }
        clusters.sort { $0.hits > $1.hits }

        var result: [Range<Int>] = []
        for cluster in clusters.prefix(limit) {
            let low = max(0, cluster.low - needle.count)
            let high = min(document.chars.count, cluster.high + needle.count + gramSize)
            guard low < high else { continue }
            guard !result.contains(where: { $0.overlaps(low..<high) }) else { continue }
            result.append(low..<high)
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: 局部对齐

    /// 在 window 里找和 needle 最像的一段（Smith-Waterman），返回得分最高那一段的起止和命中字数。
    private static func align(_ needle: [Character], in document: Document, window: Range<Int>) -> Alignment? {
        let rows = needle.count
        let columns = window.count
        guard rows > 0, columns > 0 else { return nil }
        let matchScore = 3, mismatchScore = -1, gapScore = -2
        var previous = [Int](repeating: 0, count: columns + 1)
        var current = [Int](repeating: 0, count: columns + 1)
        var directions = [UInt8](repeating: 0, count: (rows + 1) * (columns + 1))
        var best = 0, bestRow = 0, bestColumn = 0

        for row in 1...rows {
            for column in 1...columns {
                let diagonal = previous[column - 1] + (needle[row - 1] == document.chars[window.lowerBound + column - 1] ? matchScore : mismatchScore)
                let up = previous[column] + gapScore
                let left = current[column - 1] + gapScore
                var value = 0
                var direction: UInt8 = 0
                if diagonal > value { value = diagonal; direction = 1 }
                if up > value { value = up; direction = 2 }
                if left > value { value = left; direction = 3 }
                current[column] = value
                directions[row * (columns + 1) + column] = direction
                if value > best { best = value; bestRow = row; bestColumn = column }
            }
            swap(&previous, &current)
            for column in 0...columns { current[column] = 0 }
        }
        guard best > 0 else { return nil }

        var row = bestRow, column = bestColumn, matched = 0
        var first = column, last = column - 1
        while row > 0, column > 0 {
            switch directions[row * (columns + 1) + column] {
            case 0: row = 0
            case 1:
                if needle[row - 1] == document.chars[window.lowerBound + column - 1] { matched += 1 }
                first = min(first, column); last = max(last, column)
                row -= 1; column -= 1
            case 2: row -= 1
            default: column -= 1
            }
        }
        guard last >= first else { return nil }
        return Alignment(score: best, matched: matched, start: window.lowerBound + first - 1, end: window.lowerBound + last - 1)
    }

    /// 覆盖率够不够：字太少的行要求完全对上，长一点的行允许漏字改字。
    private static func isConfident(_ alignment: Alignment, needleCount: Int) -> Bool {
        guard alignment.matched >= 3 else { return false }
        let coverage = Double(alignment.matched) / Double(max(1, needleCount))
        return needleCount <= 3 ? coverage >= 0.99 : coverage >= minimumCoverage
    }

    /// 极短的行只认连续完全一致，并且要求识别稿里同样只有一处，避免“好”“对”这种字到处误伤。
    private static func exactMatch(_ needle: [Character], in document: Document) -> Match? {
        guard needle.count >= 2, document.chars.count >= needle.count else { return nil }
        var found: Range<Int>?
        for start in 0...(document.chars.count - needle.count) {
            guard Array(document.chars[start..<(start + needle.count)]) == needle else { continue }
            if found != nil { return nil }
            found = start..<(start + needle.count)
        }
        guard let range = found else { return nil }
        return Match(start: document.starts[range.lowerBound], end: document.ends[range.upperBound - 1], coverage: 1)
    }
}
