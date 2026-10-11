import Foundation
import Testing
@testable import CodeCutMac

// MARK: - 时间列反解

@Test func scriptTimeRangeReadsBackTheTimeColumn() {
    let range = ScriptTimeMatcher.timeRange("01:04.3–01:08.9")
    #expect(range?.start == 64.3)
    #expect(range?.end == 68.9)
    // 手写的普通连字符也要认。
    #expect(ScriptTimeMatcher.timeRange("0:03-0:07")?.end == 7)
}

@Test func scriptTimeRangeRejectsCellsThatArentTimeRanges() {
    #expect(ScriptTimeMatcher.timeRange("特写").map { $0.start } == nil)
    #expect(ScriptTimeMatcher.timeRange("01:08.9–01:04.3").map { $0.start } == nil)
    #expect(ScriptTimeMatcher.timeRange("").map { $0.start } == nil)
}

// MARK: - 挑素材

private func brollAsset(
    _ name: String,
    tags: [String] = [],
    summary: String,
    motion: BrollMotion = .staticShot,
    pickScore: Int = 90,
    duration: Double = 20,
    pickStart: Double = 1,
    pickEnd: Double? = nil
) -> BrollAsset {
    BrollAsset(
        path: "/tmp/\(name)",
        name: name,
        duration: duration,
        width: 1920,
        height: 1080,
        analysis: .init(
            tags: tags.map { BrollTag(identifier: $0, label: $0, confidence: 0.9) },
            motion: motion,
            product: .init(start: pickStart, end: min(duration, pickEnd ?? (pickStart + 4)), score: pickScore, summary: summary)
        )
    )
}

private func storyboardRow(_ script: String, shot: String, note: String = "", start: Double = 10, end: Double = 13, row: Int = 0, external: Bool = false) -> EditorModel.BrollStoryboardRow {
    .init(row: row, script: script, shot: shot, note: note, start: start, end: end, external: external)
}

@Test func candidatesPickTheAssetThatMatchesTheLine() {
    let zipper = brollAsset("C4030.MP4", tags: ["材质", "织物"], summary: "特写拉链细节清晰")
    let body = brollAsset("C4025.MP4", tags: ["容器", "行李箱"], summary: "黑色包主体清晰")
    let white = brollAsset("C4065.MP4", tags: ["家具", "容器"], summary: "米白包在画面中，但非主体")
    let row = storyboardRow("，连拉链也做了防水的设计，", shot: "特写")

    let candidates = EditorModel.brollCandidates(for: row, in: [body, white, zipper])

    #expect(candidates.first?.name == "C4030.MP4")
    // 一条都对不上的素材不参与，省得把整库都丢给模型。
    #expect(!candidates.contains { $0.name == "C4065.MP4" })
}

@Test func candidatesAreEmptyForRowsThatAskForOutsideFootage() {
    // 标了「未拍摄 / 网络素材」的镜头本来就要去外面找素材，本地库不掺和。
    let row = storyboardRow("自从pocket3火得一塌糊涂之后", shot: "网络素材", note: "网络素材", external: true)
    let assets = [brollAsset("C4025.MP4", tags: ["容器"], summary: "黑色包主体清晰")]
    #expect(EditorModel.brollCandidates(for: row, in: assets).isEmpty)
}

@Test func candidatesFallBackToShotTypeWhenNothingMatchesLiterally() {
    // 「包的内侧由两个格挡分成了三块空间」这种话，画面标签里根本没有对应词，
    // 但分镜写着固定镜头，就按拍法把固定镜头的素材端上来让模型判断。
    let row = storyboardRow("包的内侧由两个格挡分成了三块空间，", shot: "UL1实拍", note: "固定镜头+MG动画")
    let still = brollAsset("C4033.MP4", tags: ["材质"], summary: "特写包身缝线与拉链", motion: .staticShot)
    let moving = brollAsset("C4035.MP4", tags: ["容器"], summary: "包体结构清晰", motion: .mixed)
    let candidates = EditorModel.brollCandidates(for: row, in: [still, moving])
    #expect(candidates.map(\.name) == ["C4033.MP4"])
}

@Test func candidatesSkipAssetsAlreadyUsedOnAnEarlierLine() {
    let first = brollAsset("C4030.MP4", tags: ["材质"], summary: "特写拉链细节清晰")
    let second = brollAsset("C4032.MP4", tags: ["织物"], summary: "特写拉链，清晰可见")
    let row = storyboardRow("，连拉链也做了防水的设计，", shot: "特写")

    let candidates = EditorModel.brollCandidates(for: row, in: [first, second], used: [first.path])

    #expect(candidates.first?.name == "C4032.MP4")
}

// MARK: - 排位置

@Test func placementStartsAtTheLineAndRunsToTheEndOfTheFootage() {
    let asset = brollAsset("A.MP4", summary: "特写", duration: 30, pickStart: 2.5)
    let placement = EditorModel.makeBrollPlacement(asset: asset, row: storyboardRow("x", shot: "特写", start: 10, end: 13), reason: "test")

    // 片段入点就是这句台词开始的时间。
    #expect(placement?.start == 10)
    // 素材内部从本机模型挑出的入点开始用，一直播到这条素材结束（2.5 → 30 秒），不强行盖住台词。
    #expect(placement?.sourceIn == 2.5)
    #expect(placement?.sourceOut == 30)
    #expect(placement?.end == 37.5)
    #expect(placement?.duration == 27.5)
}

@Test func placementNeverRunsPastTheEndOfTheFootage() {
    // 模型挑出来的入点快到素材结尾了，也不能越过素材本身。
    let asset = brollAsset("C.MP4", summary: "特写", duration: 6, pickStart: 5.5)
    let placement = EditorModel.makeBrollPlacement(asset: asset, row: storyboardRow("x", shot: "特写", start: 10, end: 13), reason: "test")
    #expect(placement?.start == 10)
    #expect(placement?.sourceIn == 5.5)
    #expect(placement?.sourceOut == 6)
    #expect(placement?.end == 10.5)
}

@Test func placementStartsFromZeroWhenTheLibraryHasNoRecommendation() {
    let asset = BrollAsset(path: "/tmp/D.MP4", name: "D.MP4", duration: 12, width: 1920, height: 1080, analysis: .init(tags: [BrollTag(identifier: "容器", label: "容器", confidence: 0.9)], motion: .staticShot))
    let placement = EditorModel.makeBrollPlacement(asset: asset, row: storyboardRow("x", shot: "特写", start: 10, end: 13), reason: "test")
    #expect(placement?.start == 10)
    #expect(placement?.sourceIn == 0)
    #expect(placement?.end == 22)
}

@Test func placementStopsWhenTheFootageRunsOut() {
    // 素材只剩 1 秒，台词有 3 秒：铺到素材用完为止，入点仍然对上台词开始的时间。
    let asset = brollAsset("B.MP4", summary: "特写", duration: 6, pickStart: 5)
    let placement = EditorModel.makeBrollPlacement(asset: asset, row: storyboardRow("x", shot: "特写", start: 10, end: 13), reason: "test")

    #expect(placement?.start == 10)
    #expect(placement?.end == 11)
    #expect(placement?.sourceOut == 6)
}

@Test func placementsThatNeedMoreThanOneTrackGetOne() {
    func clip(_ row: Int, _ start: Double, _ end: Double) -> BrollPlacement {
        .init(row: row, path: "/tmp/\(row).mp4", name: "\(row).mp4", track: 1, start: start, end: end, sourceIn: 0, sourceOut: end - start)
    }
    // 第 1、3 条在时间上叠住了，第 2 条正好接在第 1 条后面：两条轨道就够，不用三条。
    let packed = EditorModel.packBrollTracks([clip(0, 0, 5), clip(1, 6, 9), clip(2, 4, 8)])

    #expect(packed.count == 3)
    #expect(packed.first { $0.row == 0 }?.track == 1)
    #expect(packed.first { $0.row == 2 }?.track == 2)
    #expect(packed.first { $0.row == 1 }?.track == 1)
    #expect(Set(packed.map(\.track)) == [1, 2])
}

@Test func backToBackPlacementsShareOneTrack() {
    func clip(_ row: Int, _ start: Double, _ end: Double) -> BrollPlacement {
        .init(row: row, path: "/tmp/\(row).mp4", name: "\(row).mp4", track: 1, start: start, end: end, sourceIn: 0, sourceOut: end - start)
    }
    let packed = EditorModel.packBrollTracks([clip(0, 0, 5), clip(1, 5, 8)])
    #expect(packed.allSatisfy { $0.track == 1 })
}

// MARK: - 模型返回的挑选结果

@Test func brollPicksIgnoreRowsAndIndexesTheModelInvented() {
    let requests = [
        AIClient.BrollChoiceRequest(row: 0, script: "a", shot: "特写", note: "", candidates: ["x", "y"]),
        AIClient.BrollChoiceRequest(row: 5, script: "b", shot: "", note: "", candidates: ["z"])
    ]
    let raw = #"{"picks":[{"row":1,"pick":2},{"row":5,"pick":9},{"row":99,"pick":1},{"row":6,"pick":"1"}]}"#
    let picks = AIClient.parseBrollPicks(raw, requests: requests)
    // 1 号行选第 2 条、6 号行（也就是 requests 里的第 5 行）选第 1 条；编出来的行号和越界序号一律丢掉。
    #expect(picks == [0: 2, 5: 1])
}

// MARK: - 整条链路

@MainActor @Test func autoPlaceUsesTheModelPickAndWritesPlacementsOnTracks() async throws {
    let model = EditorModel()
    model.edgeTrim = .keep
    model.pausePlan = .off
    // 两句台词：第一句 0–2.4 秒，第二句 2.5–4.9 秒。
    var words: [TranscriptWord] = []
    for (index, character) in "先看这个包再看看细节".enumerated() {
        let start = Double(index) * 0.5
        words.append(TranscriptWord(text: String(character), start: start, end: start + 0.4))
    }
    model.words = words
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜,镜头类型\n先看这个包,外观镜头,特写\n再看看细节,特写,特写"))
    model.brollAssets = [
        brollAsset("C4025.MP4", tags: ["容器", "行李箱"], summary: "黑色包主体清晰"),
        brollAsset("C4030.MP4", tags: ["材质", "织物"], summary: "特写拉链细节清晰")
    ]
    await model.matchScriptTableTimes()
    // 本机模型这一步在测试里换成假的：第一行挑第 1 条候选，第二行说都不合适。
    model.brollChooser = { requests in
        var picks: [Int: Int] = [:]
        for request in requests { picks[request.row] = request.row == 0 ? 1 : 0 }
        return picks
    }

    let placed = await model.autoPlaceBroll()

    #expect(placed == 1)
    #expect(model.brollPlacements.count == 1)
    let placement = try #require(model.brollPlacements.first)
    #expect(placement.row == 0)
    #expect(placement.track == 1)
    // 入点对上「先看这个包」开始的时间。
    #expect(placement.start == 0)
    // 台词只念到 2.4 秒，片段本身 19 秒（素材 20 秒、入点 1 秒），不强行盖住台词也不会被切短。
    #expect(placement.end == 19)
    #expect(model.brollPlacementTracks.count == 1)
}

@MainActor @Test func autoPlaceFallsBackToTheClosestAssetWhenTheModelSaysNothing() async throws {
    let model = EditorModel()
    model.edgeTrim = .keep
    model.pausePlan = .off
    var words: [TranscriptWord] = []
    for (index, character) in "连拉链也做了防水的设计".enumerated() {
        let start = Double(index) * 0.5
        words.append(TranscriptWord(text: String(character), start: start, end: start + 0.4))
    }
    model.words = words
    model.applyScriptTable(ScriptTableCSV.table(fromCSV: "文稿,分镜,镜头类型\n连拉链也做了防水的设计,特写,特写"))
    model.brollAssets = [brollAsset("C4030.MP4", tags: ["材质"], summary: "特写拉链细节清晰")]
    await model.matchScriptTableTimes()
    // 模型没给结论（比如没跑起来）：按本地最接近的一条兜底，并写清楚这是兜底。
    model.brollChooser = { _ in [:] }

    let placed = await model.autoPlaceBroll()

    #expect(placed == 1)
    #expect(model.brollPlacements.first?.name == "C4030.MP4")
    #expect(model.brollPlacements.first?.reason.contains("兜底") == true)
}

@MainActor @Test func clearingPlacementsCanBeUndone() async throws {
    let model = EditorModel()
    model.brollPlacements = [.init(row: 0, path: "/tmp/A.MP4", name: "A.MP4", track: 1, start: 0, end: 3, sourceIn: 0, sourceOut: 3)]
    model.clearBrollPlacements()
    #expect(model.brollPlacements.isEmpty)

    model.undo()
    #expect(model.brollPlacements.count == 1)
}
