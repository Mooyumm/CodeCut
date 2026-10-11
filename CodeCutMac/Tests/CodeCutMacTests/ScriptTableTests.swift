import Foundation
import Testing
@testable import CodeCutMac

// MARK: - CSV 解析
//
// 分镜稿的第一列是整句台词，里面带逗号，而且 Excel 导出时会用引号包起来。
// 这几个用例固定住“不要按逗号切碎一行”这件事。

@Test func scriptTableCSVKeepsQuotedCommasInOneField() {
    let csv = "文稿,分镜,镜头类型\n\"先看这个包,再看细节\",外观镜头,实拍\n"
    let grid = ScriptTableCSV.parse(csv)
    #expect(grid.count == 2)
    #expect(grid[1][0] == "先看这个包,再看细节")
    #expect(grid[1][2] == "实拍")
}

@Test func scriptTableCSVHandlesEscapedQuotesAndCRLF() {
    let csv = "a,b\r\n\"他说\"\"这是防水的\"\"\",2\r\n"
    let grid = ScriptTableCSV.parse(csv)
    #expect(grid.count == 2)
    #expect(grid[1][0] == "他说\"这是防水的\"")
    #expect(grid[1][1] == "2")
}

@Test func scriptTableCSVStripsBOMAndTrailingBlankLines() {
    let csv = "\u{FEFF}文稿,分镜\n内容,特写\n\n\n"
    let grid = ScriptTableCSV.parse(csv)
    #expect(grid.first?.first == "文稿")
    #expect(grid.count == 2)
}

@Test func scriptTableCSVRoundTripsThroughEncode() {
    let grid = [["文稿", "分镜"], ["带,逗号", "带\"引号"], ["带\n换行", "普通"]]
    #expect(ScriptTableCSV.parse(ScriptTableCSV.encode(grid)) == grid)
}

@Test func scriptTableFromCSVUsesFirstRowAsHeader() {
    let table = ScriptTableCSV.table(fromCSV: "文稿,分镜\n第一句,特写\n第二句,全景")
    #expect(table.headers == ["文稿", "分镜"])
    #expect(table.rowCount == 2)
    #expect(table.cell(1, 0) == "第二句")
    // 列宽行高进表格时就补齐，界面不用再判断越界。
    #expect(table.columnWidths.count == 2)
    #expect(table.rowHeights.count == 2)
    #expect(table.width(0) == ScriptTable.firstColumnWidth)
}

@Test func scriptTableNormalizePadsShortRows() {
    var table = ScriptTable(headers: ["a", "b", "c"], rows: [["1"], ["1", "2", "3", "4"]])
    table.normalize()
    // 表头比数据短时以数据为准：多出来的那列是用户写下的内容，补表头，不丢数据。
    #expect(table.columnCount == 4)
    #expect(table.headers == ["a", "b", "c", ""])
    #expect(table.rows[0] == ["1", "", "", ""])
    #expect(table.rows[1] == ["1", "2", "3", "4"])
    #expect(table.columnWidths.count == 4)
}

@Test func scriptTablePlainTextMigrationKeepsEveryLine() {
    let table = ScriptTableCSV.table(fromPlainText: "开场：城市街景\n\n02:10 特写：扣具\n")
    #expect(table.headers == ["分镜稿"])
    #expect(table.rows.map { $0[0] } == ["开场：城市街景", "02:10 特写：扣具"])
}

// MARK: - 编辑器里的表格

@MainActor @Test func importingAScriptTableReplacesTheOldOne() async throws {
    let model = EditorModel()
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n第一句,特写"))
    #expect(model.scriptTable.rowCount == 1)

    var replacement = ScriptTable(headers: ["画面", "时间"], rows: [["桌面", "0:00"]])
    replacement.normalize()
    model.applyScriptTable(replacement)
    #expect(model.scriptTable.headers == ["画面", "时间"])
    #expect(model.scriptTable.rowCount == 1)
}

@MainActor @Test func editingACellKeepsEverythingElseIntact() async throws {
    let model = EditorModel()
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n第一句,特写\n第二句,全景"))
    model.updateScriptCell(row: 1, column: 0, text: "改过的第二句")
    #expect(model.scriptTable.cell(1, 0) == "改过的第二句")
    #expect(model.scriptTable.cell(0, 0) == "第一句")
    #expect(model.scriptTable.cell(1, 1) == "全景")
    // 越界写入直接忽略，不能把表写坏。
    model.updateScriptCell(row: 99, column: 0, text: "越界")
    #expect(model.scriptTable.rowCount == 2)
}

@MainActor @Test func columnWidthAndRowHeightAreClampedAndRemembered() async throws {
    let model = EditorModel()
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n第一句,特写"))

    model.setScriptColumnWidth(420, at: 0)
    model.setScriptRowHeight(88, at: 0)
    #expect(model.scriptTable.width(0) == 420)
    #expect(model.scriptTable.height(0) == 88)

    // 拖到负宽度不该把列拖没，上下限兜住。
    model.setScriptColumnWidth(-100, at: 0)
    #expect(model.scriptTable.width(0) == ScriptTable.minimumColumnWidth)
    model.setScriptRowHeight(5, at: 0)
    #expect(model.scriptTable.height(0) == ScriptTable.minimumRowHeight)
}

@MainActor @Test func rowAndColumnEditingStaysRectangular() async throws {
    let model = EditorModel()
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n第一句,特写"))
    model.addScriptRow()
    #expect(model.scriptTable.rowCount == 2)
    #expect(model.scriptTable.rows[1].count == 2)

    model.addScriptRow(after: 0)
    #expect(model.scriptTable.rowCount == 3)
    #expect(model.scriptTable.rowHeights.count == 3)

    model.addScriptColumn()
    #expect(model.scriptTable.columnCount == 3)
    #expect(model.scriptTable.rows.allSatisfy { $0.count == 3 })

    model.removeScriptColumn(1)
    #expect(model.scriptTable.columnCount == 2)
    #expect(model.scriptTable.rows.allSatisfy { $0.count == 2 })

    model.removeScriptRow(0)
    #expect(model.scriptTable.rowCount == 2)
    #expect(model.scriptTable.rowHeights.count == 2)
}

@MainActor @Test func scriptTableIsPerProjectAndRoundTrips() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-table-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "a.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "a", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜,镜头类型\n第一句,特写,实拍"))
    model.setScriptColumnWidth(500, at: 0)
    model.setScriptRowHeight(120, at: 0)
    // 界面上是拖完（onEnded）才 submit 一次，拖的过程不写盘。
    model.commitScriptTable()

    let reopened = EditorModel()
    try await reopened.openProject(url)
    #expect(reopened.scriptTable.headers == ["文稿", "分镜", "镜头类型"])
    #expect(reopened.scriptTable.cell(0, 2) == "实拍")
    // 调过的列宽行高要跟着项目记住。
    #expect(reopened.scriptTable.width(0) == 500)
    #expect(reopened.scriptTable.height(0) == 120)

    // 换项目不能串：另一个项目没有分镜稿表格。
    let other = folder.appending(path: "b.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "b", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: other
    )
    try await reopened.openProject(other)
    #expect(reopened.scriptTable.isEmpty)
}

@MainActor @Test func legacyPastedScriptIsMigratedIntoTheTable() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "legacy.codecut")
    try ProjectStore.save(
        ProjectDocument(
            name: "legacy", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm,
            frameRate: 25, storyboardScript: "开场：城市街景\n02:10 特写：扣具"
        ),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    // 以前贴在文本框里的分镜稿不能丢，第一次打开就搬进表格第一列。
    #expect(model.scriptTable.rowCount == 2)
    #expect(model.scriptTable.cell(1, 0) == "02:10 特写：扣具")
}

// MARK: - 分镜行对口播时间

/// 造一段“一个字一个词”的口播，时间和真实识别稿一样逐词铺开。
@MainActor private func editorWithVoiceover(_ text: String, from start: Double = 1, step: Double = 0.5) -> EditorModel {
    let model = EditorModel()
    // 不掐头尾、不删气口：测试里的时间就是成片时间。
    model.edgeTrim = .keep
    model.pausePlan = .off
    var words: [TranscriptWord] = []
    var time = start
    for character in text {
        words.append(TranscriptWord(text: String(character), start: time, end: time + step * 0.8))
        time += step
    }
    model.words = words
    return model
}

@MainActor @Test func matchingWritesTimesRightAfterTheScriptColumn() async throws {
    // 口播："先看一下这个包 / 再看看细节 / 然后我们收工"，一个字 0.5 秒。
    let model = editorWithVoiceover("先看一下这个包再看看细节然后我们收工")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜,镜头类型\n先看这个包,特写,实拍\n再看看细节,全景,实拍\n今天天气不错,空镜,未拍摄"))

    let matched = await model.matchScriptTableTimes()

    #expect(matched == 2)
    // 时间列插在文稿后面，不是加在最后。
    #expect(model.scriptTable.headers == ["文稿", "时间", "分镜", "镜头类型"])
    #expect(model.scriptTable.rows.allSatisfy { $0.count == 4 })
    // 中间多出来的"一下"算在两个词之间，时间从"先"到"包"。
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:04.4")
    #expect(model.scriptTable.cell(1, 1) == "00:04.5–00:06.9")
    // 口播里没有的行留空。
    #expect(model.scriptTable.cell(2, 1) == "")
    // 别的列不能被碰。
    #expect(model.scriptTable.cell(0, 2) == "特写")
}

@MainActor @Test func matchingToleratesCaseSpacingAndChineseNumerals() async throws {
    let model = EditorModel()
    model.edgeTrim = .keep
    model.pausePlan = .off
    // 识别稿常把 Pocket 三 3 分开写成三个词，分镜稿写的是 pocket3。
    let tokens: [(String, Double)] = [("Pocket", 1), ("三", 2), ("3", 3), ("火", 4), ("得", 5), ("一", 6), ("塌", 7), ("糊", 8), ("涂", 9), ("之", 10), ("后", 11)]
    model.words = tokens.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.1 + 0.5) }
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\nPocket3 火得一塌糊涂之后,外观镜头"))

    let matched = await model.matchScriptTableTimes()

    #expect(matched == 1)
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:11.5")
}

@MainActor @Test func matchingMovesAnExistingTimeColumnNextToTheScriptColumn() async throws {
    let model = editorWithVoiceover("先看这个包")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜,时间\n先看这个包,特写,"))

    await model.matchScriptTableTimes()

    #expect(model.scriptTable.headers == ["文稿", "时间", "分镜"])
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:03.4")
    #expect(model.scriptTable.cell(0, 2) == "特写")
}

@MainActor @Test func matchingPutsTheTimeColumnAfterTheScriptEvenWhenItWasFirst() async throws {
    let model = editorWithVoiceover("先看这个包")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "时间,文稿,分镜\n,先看这个包,特写"))

    await model.matchScriptTableTimes()

    #expect(model.scriptTable.headers == ["文稿", "时间", "分镜"])
    #expect(model.scriptTable.cell(0, 0) == "先看这个包")
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:03.4")
    #expect(model.scriptTable.cell(0, 2) == "特写")
}

@MainActor @Test func autoMatchingNeverCreatesTheTimeColumnOnItsOwn() async throws {
    let model = editorWithVoiceover("先看这个包")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n先看这个包,特写"))
    // 「时间」列只由按钮生成：自动对齐看到分镜稿里没有这一列时不动手。
    await model.autoMatchScriptTimesIfNeeded()
    #expect(model.scriptTable.headers == ["文稿", "分镜"])

    await model.matchScriptTableTimes()
    #expect(model.scriptTable.headers == ["文稿", "时间", "分镜"])
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:03.4")
}

@MainActor @Test func autoMatchingKeepsHandWrittenTimes() async throws {
    // 用户导入/自己写的时间：自动对齐不能覆盖它。
    let handwritten = editorWithVoiceover("先看这个包")
    handwritten.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,时间,分镜\n先看这个包,00:20.0–00:25.0,特写"))
    await handwritten.autoMatchScriptTimesIfNeeded()
    #expect(handwritten.scriptTable.cell(0, 1) == "00:20.0–00:25.0")
    // 手动点按钮仍然可以强制重算。
    await handwritten.matchScriptTableTimes()
    #expect(handwritten.scriptTable.cell(0, 1) == "00:01.0–00:03.4")
}

@MainActor @Test func editingATimeCellHandsThatColumnBackToTheUser() async throws {
    let model = editorWithVoiceover("先看这个包")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n先看这个包,特写"))
    await model.matchScriptTableTimes()
    #expect(model.scriptTable.timeColumnSignature != nil)

    // 人工把这一格改成自己核准的时间：这一列以后不再被自动刷新。
    model.updateScriptCell(row: 0, column: 1, text: "00:20.0–00:25.0")
    #expect(model.scriptTable.timeColumnSignature == nil)
    await model.autoMatchScriptTimesIfNeeded()
    #expect(model.scriptTable.cell(0, 1) == "00:20.0–00:25.0")
}

@MainActor @Test func matchingRepeatsWhenTheVoiceoverChanges() async throws {
    let model = editorWithVoiceover("先看这个包")
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜\n先看这个包,特写"))
    await model.matchScriptTableTimes()
    #expect(model.scriptTable.cell(0, 1) == "00:01.0–00:03.4")

    // 口播重新转写/修剪之后，时间要跟着更新，不能停在旧的指纹上。
    model.words = model.words.map { word in
        var word = word; word.start += 10; word.end += 10; return word
    }
    await model.autoMatchScriptTimesIfNeeded()
    #expect(model.scriptTable.cell(0, 1) == "00:11.0–00:13.4")
}

@Test func scriptTableCSVExportCanBeReimported() {
    var table = ScriptTable(headers: ["文稿", "分镜"], rows: [["带,逗号的句子", "特写"]])
    table.normalize()
    let reimported = ScriptTableCSV.table(fromCSV: ScriptTableCSV.csv(from: table))
    #expect(reimported.headers == table.headers)
    #expect(reimported.rows == table.rows)
}
