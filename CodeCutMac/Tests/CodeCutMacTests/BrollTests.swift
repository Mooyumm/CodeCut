import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CodeCutMac

// MARK: - 运动方向判定
//
// 阈值是在真实 B-roll 素材上标定出来的，这些用例把它们固定住，
// 以后再调参数必须是有意识的行为。

@Test func brollMotionStaysStaticBelowThreshold() {
    #expect(BrollAnalyzer.motionDirection(horizontal: 0.2, vertical: -0.4) == .staticShot)
    #expect(BrollAnalyzer.motionDirection(horizontal: 0, vertical: 0) == .staticShot)
}

@Test func brollMotionUsesScreenCoordinates() {
    // x 向右为正、y 向下为正：观众看到的画面往哪走就是哪。
    #expect(BrollAnalyzer.motionDirection(horizontal: 12, vertical: 0.3) == .panRight)
    #expect(BrollAnalyzer.motionDirection(horizontal: -12, vertical: 0.3) == .panLeft)
    #expect(BrollAnalyzer.motionDirection(horizontal: 0.4, vertical: 12) == .tiltDown)
    #expect(BrollAnalyzer.motionDirection(horizontal: 0.4, vertical: -12) == .tiltUp)
}

@Test func brollMotionFallsBackToDiagonalWhenBothAxesMove() {
    // 水平 4%、垂直 3.5%：谁也没比谁大 1.45 倍，判为斜向。
    #expect(BrollAnalyzer.motionDirection(horizontal: 4, vertical: 3.5) == .diagonal)
}

@Test func brollMotionReportsBackAndForthAsMixed() {
    // 前后来回、首尾几乎回到原点：这时候说“向右”是错的。
    #expect(BrollAnalyzer.motionDirection(horizontal: 0.4, vertical: 0.2, reversing: true) == .mixed)
}

@Test func brollZoomNeedsSubstantialDivergence() {
    #expect(BrollAnalyzer.zoomDirection(divergence: 0.8) == .none)
    #expect(BrollAnalyzer.zoomDirection(divergence: 6.2) == .pushIn)
    #expect(BrollAnalyzer.zoomDirection(divergence: -6.2) == .pullOut)
}

// MARK: - 标签
@Test func brollTagLabelsAreLocalizedAndFallBackReadably() {
    #expect(BrollTag.label(for: "computer") == "电脑")
    #expect(BrollTag.label(for: "coffee_mug") == "咖啡杯")
    // 词表里没有的标识不能变成空白，至少要能读。
    #expect(BrollTag.label(for: "some_unknown_thing") == "Some unknown thing")
}

// MARK: - 搜索与筛选
@MainActor @Test func brollLibrarySearchMatchesTagsMotionAndFileName() {
    let model = EditorModel()
    var keyboard = BrollAsset(path: "/tmp/a.MP4", name: "C4025.MP4", duration: 9, width: 3840, height: 2160)
    keyboard.analysis = BrollAnalysis(tags: [BrollTag(identifier: "keyboard", label: "键盘", confidence: 0.8)], motion: .panRight)
    var desk = BrollAsset(path: "/tmp/b.MP4", name: "C4026.MP4", duration: 4, width: 1920, height: 1080)
    desk.analysis = BrollAnalysis(tags: [BrollTag(identifier: "desk", label: "书桌", confidence: 0.5)], motion: .staticShot)
    model.brollAssets = [keyboard, desk]

    model.brollQuery = "键盘"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4025.MP4"])

    model.brollQuery = "4026"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4026.MP4"])

    model.brollQuery = ""
    model.brollMotionFilter = .staticShot
    #expect(model.visibleBrollAssets.map(\.name) == ["C4026.MP4"])
    #expect(model.analyzedBrollCount == 2)
}

@MainActor @Test func removingBrollOnlyDropsItFromTheLibrary() {
    let model = EditorModel()
    let asset = BrollAsset(path: "/tmp/c.MP4", name: "c.MP4", duration: 3, width: 1920, height: 1080)
    model.brollAssets = [asset]
    model.selectedBrollID = asset.id

    model.removeBrollAssets([asset.id])
    #expect(model.brollAssets.isEmpty)
    #expect(model.selectedBrollID == nil)
}

// MARK: - 落盘
@MainActor @Test func brollAssetsSurviveAProjectRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-broll-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "broll.codecut")

    var asset = BrollAsset(path: "/tmp/d.MP4", name: "d.MP4", duration: 12.5, width: 3840, height: 2160)
    asset.analysis = BrollAnalysis(
        tags: [BrollTag(identifier: "coffee_mug", label: "咖啡杯", confidence: 0.71)],
        motion: .tiltUp,
        zoom: .pushIn,
        energy: .gentle,
        horizontalShift: -0.4,
        verticalShift: -9.3,
        divergence: 4.2,
        activity: 21.7,
        shiftPerSecond: 1.28
    )
    let document = ProjectDocument(
        name: "broll", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm,
        frameRate: 25, brollAssets: [asset]
    )
    try ProjectStore.save(document, to: url)
    let restored = try ProjectStore.load(from: url)

    #expect(restored.brollAssets?.count == 1)
    let analysis = try #require(restored.brollAssets?.first?.analysis)
    #expect(analysis.motion == .tiltUp)
    #expect(analysis.zoom == .pushIn)
    #expect(analysis.tags.first?.label == "咖啡杯")
    #expect(abs(analysis.shiftPerSecond - 1.28) < 0.0001)
}

@MainActor @Test func openingAProjectWithoutBrollAssetsStartsEmpty() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-broll-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "legacy.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "legacy", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    #expect(model.brollAssets.isEmpty)
    #expect(model.selectedBrollID == nil)
}

// MARK: - 产品镜头挑选
//
// pick() 是纯函数：给一组采样帧结论和速度，算出“这条素材哪一段能用来展示产品”。
// 这几个用例固定住三件事：主体帧要能扩成片段、晃的邻居要截断、没产品就是 0 分。

private func verdict(_ index: Int, _ time: Double, _ presence: BrollProductPresence, confidence: Int = 90, sharpness: Int = 80, note: String = "") -> BrollFrameVerdict {
    BrollFrameVerdict(index: index, time: time, presence: presence, confidence: confidence, sharpness: sharpness, note: note)
}

@Test func productPickGrowsAStableStretchAroundTheBestFrame() {
    let frames = [
        verdict(0, 0.0, .none, confidence: 80),
        verdict(1, 1.0, .visible, confidence: 70),
        verdict(2, 2.0, .mainSubject, confidence: 95, note: "包在画面中间"),
        verdict(3, 3.0, .visible, confidence: 75),
        verdict(4, 4.0, .none, confidence: 60)
    ]
    let pick = ProductPicker.pick(verdicts: frames, times: frames.map(\.time), speeds: [0.2, 0.3, 0.1, 0.4, 0.6], duration: 6)

    #expect(pick.containsProduct)
    #expect(pick.isUsable)
    #expect(pick.presence == .mainSubject)
    #expect(pick.score > 60)
    // 片段要包住主体帧（2s）和两侧还有产品的帧。
    #expect(pick.start <= 1.0)
    #expect(pick.end >= 3.0)
    #expect(pick.summary == "包在画面中间")
    // 依据里要写清“这一段为什么能用”，而不是描述镜头语言。
    #expect(pick.reasons.contains { $0.contains("产品最清楚") })
    #expect(pick.reasons.contains { $0.contains("适合当产品定格") })
}

@Test func productPickStopsAtShakyNeighbourFrames() {
    let frames = [
        verdict(0, 0.0, .visible),
        verdict(1, 1.0, .visible),
        verdict(2, 2.0, .mainSubject, confidence: 95),
        verdict(3, 3.0, .visible),
        verdict(4, 4.0, .visible)
    ]
    // 3 号点之后镜头在晃：不能把晃动的那一段一起推荐出去。
    let pick = ProductPicker.pick(verdicts: frames, times: frames.map(\.time), speeds: [0.2, 0.2, 0.3, 7.5, 7.5], duration: 6)

    #expect(pick.presence == .mainSubject)
    // 3 号采样点之后镜头开始晃：推荐片段要在晃起来之前收住，不能把晃动的那一段算进来。
    #expect(pick.end < 4.0)
    #expect(pick.start <= 1.0)
    #expect(pick.reasons.contains { $0.contains("缓慢移动") || $0.contains("基本不动") })
}

@Test func productPickScoresZeroWhenTheProductNeverShows() {
    let frames = [
        verdict(0, 0.0, .none, confidence: 10),
        verdict(1, 1.0, .none, confidence: 5),
        verdict(2, 2.0, .none, confidence: 5)
    ]
    // 就算这条素材又稳又长，没拍到产品也不能给分——否则界面上会像是“能用”。
    let pick = ProductPicker.pick(verdicts: frames, times: frames.map(\.time), speeds: [0, 0, 0], duration: 20)

    #expect(pick.score == 0)
    #expect(!pick.containsProduct)
    #expect(!pick.isUsable)
    #expect(pick.duration == 0)
    #expect(pick.reasons.contains { $0.contains("没有认出产品") })
}

@Test func productPickSummaryDescribesTheRecommendedFrame() {
    let frames = [
        verdict(0, 0.0, .hinted, confidence: 30, sharpness: 20, note: "模糊不清，无法确认"),
        verdict(1, 1.0, .mainSubject, confidence: 95, sharpness: 90, note: "斜挎包挂在身前")
    ]
    // 结论不能用第一个“疑似”的帧：那是另一帧的判断，会让人以为推荐的片段是糊的。
    let pick = ProductPicker.pick(verdicts: frames, times: frames.map(\.time), speeds: [0.2, 0.2], duration: 5)
    #expect(pick.summary == "斜挎包挂在身前")
}

@Test func productPickWithoutFramesIsEmpty() {
    let pick = ProductPicker.pick(verdicts: [], times: [], speeds: [], duration: 10)
    #expect(pick.score == 0)
    #expect(!pick.containsProduct)
}

@Test func productPresenceCodeFallsBackToNone() {
    #expect(BrollProductPresence.from(code: 3) == .mainSubject)
    #expect(BrollProductPresence.from(code: 2) == .visible)
    #expect(BrollProductPresence.from(code: 1) == .hinted)
    #expect(BrollProductPresence.from(code: 0) == .none)
    // 模型偶尔会吐越界值：一律降级成“未见产品”，不要崩也不要错判成主体。
    #expect(BrollProductPresence.from(code: 9) == .none)
    #expect(BrollProductPresence.from(code: -1) == .none)
}

// MARK: - 产品档案与分镜表

@Test func productProfileNeedsANameOrADescription() {
    var profile = ProductProfile()
    #expect(!profile.isConfigured)
    profile.name = "NAYOSMART UL1 斜挎包"
    #expect(profile.isConfigured)
    #expect(profile.promptBlock.contains("NAYOSMART UL1 斜挎包"))
}

@Test func productNotesGoIntoThePromptAndCanStandAlone() {
    var profile = ProductProfile()
    // 只写补充说明也算建好了档案：brief 读漏了，人补一句就该能开始挑镜头。
    profile.notes = "这次只推黑色款"
    #expect(profile.isConfigured)
    #expect(profile.promptBlock.contains("补充说明：这次只推黑色款"))

    profile.name = "NAYOSMART UL1 背包"
    #expect(profile.promptBlock.contains("产品名称：NAYOSMART UL1 背包"))
    // 空白的补充说明不能污染提示词。
    profile.notes = "   "
    #expect(!profile.promptBlock.contains("补充说明"))
}

@MainActor @Test func productNotesAreEditableAndSavedWithTheProject() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "notes.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "notes", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    model.updateProductNotes("不要让包挡住脸")
    try model.save()

    let reopened = EditorModel()
    try await reopened.openProject(url)
    #expect(reopened.productProfile.notes == "不要让包挡住脸")
    #expect(reopened.productProfile.isConfigured)
}

@MainActor @Test func storyboardScriptIsPerProjectAndRoundTrips() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-script-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "script.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "script", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    #expect(model.storyboardScript.isEmpty)
    model.updateStoryboardScript("开场：城市街景推近\n02:10 特写：扣具")
    try model.save()

    let reopened = EditorModel()
    try await reopened.openProject(url)
    #expect(reopened.storyboardScript.contains("特写：扣具"))

    // 换一个项目要清空，文稿不能串项目。
    let other = folder.appending(path: "other.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "other", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: other
    )
    try await reopened.openProject(other)
    #expect(reopened.storyboardScript.isEmpty)
    #expect(reopened.manuscript.isEmpty)
}

@MainActor @Test func productFilterAndSortRankPickedBrollFirst() {
    let model = EditorModel()
    var good = BrollAsset(path: "/tmp/good.MP4", name: "good.MP4", duration: 6, width: 3840, height: 2160)
    good.analysis = BrollAnalysis(product: BrollProductPick(
        start: 1, end: 3, score: 88,
        frames: [verdict(0, 1, .mainSubject)],
        reasons: ["a"], summary: "包在画面里"
    ))
    var weak = BrollAsset(path: "/tmp/weak.MP4", name: "weak.MP4", duration: 6, width: 3840, height: 2160)
    weak.analysis = BrollAnalysis(product: BrollProductPick(
        start: 0, end: 0, score: 12,
        frames: [verdict(0, 1, .visible, confidence: 45, sharpness: 30)],
        reasons: ["b"], summary: ""
    ))
    let none = BrollAsset(path: "/tmp/none.MP4", name: "none.MP4", duration: 6, width: 3840, height: 2160)
    model.brollAssets = [none, weak, good]

    // 默认按推荐分排，没挑过的排在后面。
    #expect(model.visibleBrollAssets.map(\.name) == ["good.MP4", "weak.MP4", "none.MP4"])

    model.brollSortByPick = false
    #expect(model.visibleBrollAssets.map(\.name) == ["none.MP4", "weak.MP4", "good.MP4"])

    model.brollProductFilter = .visible
    #expect(model.visibleBrollAssets.map(\.name) == ["weak.MP4", "good.MP4"])

    model.brollProductFilter = .mainSubject
    #expect(model.visibleBrollAssets.map(\.name) == ["good.MP4"])

    // 注意这里必须显式写 .some(.none)：直接赋值 .none 会被当成“没有筛选”。
    model.brollProductFilter = BrollProductPresence?.some(.none)
    #expect(model.visibleBrollAssets.map(\.name) == ["none.MP4"])

    #expect(model.pickedBrollCount == 2)
    #expect(model.productBrollCount == 2)
}

@MainActor @Test func addingAPickToTheStoryboardCarriesTheSourceRange() {
    let model = EditorModel()
    var asset = BrollAsset(path: "/tmp/product.MP4", name: "product.MP4", duration: 8, width: 3840, height: 2160)
    asset.analysis = BrollAnalysis(
        tags: [BrollTag(identifier: "backpack", label: "双肩包", confidence: 0.8)],
        motion: .staticShot,
        product: BrollProductPick(
            start: 2.5, end: 5.0, score: 91,
            frames: [verdict(0, 3.0, .mainSubject)],
            reasons: ["3.0s 这一帧产品最清楚"],
            summary: "斜挎包挂在身前"
        )
    )
    model.brollAssets = [asset]

    model.addBrollPickToStoryboard(asset.id)

    let item = try! #require(model.storyboards.first)
    #expect(model.storyboards.count == 1)
    // 分镜要记住“用哪条素材的哪一段”，后面才能真的按它去剪。
    #expect(item.brollPath == "/tmp/product.MP4")
    #expect(item.brollStart == 2.5)
    #expect(item.brollEnd == 5.0)
    #expect(item.description == "斜挎包挂在身前")
    #expect(model.selectedStoryboardID == item.id)
}

@MainActor @Test func addingAPickWithoutAProductDoesNothing() {
    let model = EditorModel()
    var asset = BrollAsset(path: "/tmp/empty.MP4", name: "empty.MP4", duration: 8, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(product: BrollProductPick(score: 0, frames: [verdict(0, 0, .none)], reasons: ["没产品"], summary: ""))
    model.brollAssets = [asset]

    model.addBrollPickToStoryboard(asset.id)
    #expect(model.storyboards.isEmpty)
}

@MainActor @Test func addingAShortPickToTheStoryboardIsRefusedWithAReason() {
    let model = EditorModel()
    var asset = BrollAsset(path: "/tmp/short.MP4", name: "short.MP4", duration: 8, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(product: BrollProductPick(
        start: 2.0, end: 2.2, score: 70,
        frames: [verdict(0, 2.0, .mainSubject)],
        reasons: ["拍到了，但只有 0.2 秒"], summary: ""
    ))
    model.brollAssets = [asset]

    model.addBrollPickToStoryboard(asset.id)
    #expect(model.storyboards.isEmpty)
    if case .failed(let text) = model.taskState {
        #expect(text.contains("太短"))
    } else {
        Issue.record("片段太短时应该给出说明，而不是静默什么都不做")
    }
}

@MainActor @Test func productProfileSurvivesProjectRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-product-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "product.codecut")

    var profile = ProductProfile()
    profile.name = "NAYOSMART UL1 斜挎包"
    profile.summary = "黑色 200D 尼龙小提花斜挎包"
    profile.features = ["UTX-Duraflex 扣具", "侧面隐藏口袋"]
    profile.avoid = ["双肩包", "托特包"]
    profile.referenceImages = [ProductReferenceImage(path: "/tmp/ref.png", caption: "ref")]
    profile.builtAt = Date(timeIntervalSince1970: 1_700_000_000)

    var asset = BrollAsset(path: "/tmp/product.MP4", name: "product.MP4", duration: 8, width: 3840, height: 2160)
    asset.analysis = BrollAnalysis(product: BrollProductPick(start: 1, end: 3, score: 77, frames: [verdict(2, 2, .visible)], reasons: ["r"], summary: "s"))

    try ProjectStore.save(
        ProjectDocument(
            name: "product", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm,
            frameRate: 25, brollAssets: [asset], productProfile: profile
        ),
        to: url
    )
    let restored = try ProjectStore.load(from: url)

    #expect(restored.productProfile?.name == "NAYOSMART UL1 斜挎包")
    #expect(restored.productProfile?.features.count == 2)
    #expect(restored.brollAssets?.first?.productPick?.score == 77)
    #expect(restored.brollAssets?.first?.hasProduct == true)
}

// MARK: - 画面里的物品
//
// 这一层要回答的是“这条素材里有什么”：每一件是什么、算不算清单里的产品、
// 谁是主角（焦点在谁身上）、焦点在哪几帧换了人。

/// 造一条候选产品，方便测编号映射。
private func candidate(_ index: Int, _ name: String, color: String = "", sku: String = "") -> BrollCandidate {
    BrollCandidate(index: index, productID: UUID(), name: name, sku: sku, color: color)
}

@Test func objectsMapToCatalogItemsByIndex() {
    let candidates = [candidate(1, "NAYOSMART UL1 斜挎包", color: "黑色", sku: "UL1-BK"),
                      candidate(2, "NAYOSMART UL1 斜挎包", color: "米白", sku: "UL1-IV")]
    let parsed = ProductPicker.objects([
        ["name": "黑色斜挎包", "product_index": 1, "role": "subject", "position": "center", "sharpness": 88, "confidence": 90, "note": "扣具清楚"],
        ["name": "杯子", "product_index": 0, "role": "background", "position": "left", "sharpness": 30, "confidence": 70]
    ], candidates: candidates)

    #expect(parsed.count == 2)
    // 认出清单里的产品时，名字用清单里的（含颜色），这样归组不会串色。
    #expect(parsed[0].label == "NAYOSMART UL1 斜挎包 · 黑色")
    #expect(parsed[0].productID == candidates[0].productID)
    #expect(parsed[0].sku == "UL1-BK")
    #expect(parsed[0].role == .subject)
    #expect(parsed[0].spot == .center)
    #expect(parsed[0].sharpness == 88)
    // 不在清单里的东西不能被算成产品。
    #expect(parsed[1].productID == nil)
    #expect(parsed[1].role == .background)
    #expect(parsed[1].spot == .left)
}

@Test func objectsSurviveBadModelOutput() {
    let candidates = [candidate(1, "斜挎包", color: "黑色")]
    let parsed = ProductPicker.objects([
        // 清单编号越界：不能硬塞成 1 号产品。
        ["name": "不知道什么东西", "product_index": 9, "role": "unknown", "sharpness": 200, "confidence": -5],
        // 名字是空的：丢掉。
        ["name": "   ", "product_index": 1],
        // 完全不是字典：丢掉。
        "垃圾",
        // 清单里的产品没写角色：按陪衬算，不能当成“认不出来”。
        ["name": "斜挎包", "product_index": 1, "position": "middle", "sharpness": 60]
    ], candidates: candidates)

    #expect(parsed.count == 2)
    #expect(parsed[0].label == "不知道什么东西")
    #expect(parsed[0].productID == nil)
    #expect(parsed[0].sharpness == 100)
    #expect(parsed[0].confidence == 0)
    #expect(parsed[1].productID != nil)
    #expect(parsed[1].role == .supporting)
    #expect(parsed[1].spot == .center)
}

@Test func objectsAreCappedSoAFrameStaysAListNotAStory() {
    let parsed = ProductPicker.objects(
        (1...8).map { ["name": "东西\($0)", "product_index": 0, "role": "background"] },
        candidates: []
    )
    #expect(parsed.count == ProductPicker.objectLimit)
}

/// 造一帧结论：presence 只是“目标产品在不在”，objects 才是“画面里有什么”。
private func frame(_ index: Int, _ time: Double, _ objects: [BrollObject]) -> BrollFrameVerdict {
    BrollFrameVerdict(index: index, time: time, presence: .visible, confidence: 80, sharpness: 70, objects: objects)
}

private func object(_ label: String, product: UUID? = nil, role: BrollObjectRole = .unknown, spot: BrollSpot? = nil, sharpness: Int = 50, confirmed: Bool = false) -> BrollObject {
    BrollObject(slot: 1, label: label, productID: product, role: role, spot: spot, sharpness: sharpness)
}

@Test func inventoryMergesTheSameProductAcrossFrames() {
    let bag = UUID()
    let frames = [
        frame(0, 0.0, [object("斜挎包 · 黑色", product: bag, role: .subject, sharpness: 70)]),
        frame(1, 2.0, [object("斜挎包 · 黑色", product: bag, role: .supporting, sharpness: 90)]),
        frame(2, 4.0, [object("杯子", role: .background, sharpness: 40)])
    ]
    let inventory = BrollInventory.build(frames: frames)

    // 同一款产品在几帧里出现，合并成一件，不是三件。
    #expect(inventory.items.count == 2)
    let merged = inventory.items[0]
    #expect(merged.label == "斜挎包 · 黑色")
    #expect(merged.times == [0.0, 2.0])
    #expect(merged.sharpest == 90)
    #expect(merged.sharpestTime == 2.0)
    // 角色取更像“产品”的那个：主体 > 陪衬。
    #expect(merged.role == .subject)
    #expect(inventory.products.count == 1)
    #expect(inventory.background.map(\.label) == ["杯子"])
}

@Test func inventorySubjectFollowsFocusOnTheSharpestItem() {
    // 一帧里两样东西：镜头对焦在包上，人只是陪衬。
    let bag = UUID()
    let frames = [
        frame(0, 0.0, [object("斜挎包 · 黑色", product: bag, role: .subject, spot: .center, sharpness: 92),
                       object("路人", role: .supporting, spot: .left, sharpness: 35)]),
        frame(1, 2.0, [object("斜挎包 · 黑色", product: bag, role: .subject, spot: .right, sharpness: 88),
                       object("路人", role: .supporting, spot: .left, sharpness: 30)])
    ]
    let inventory = BrollInventory.build(frames: frames)

    // 主角就是焦点所在的那件：最清楚的那个。
    #expect(inventory.subject?.label == "斜挎包 · 黑色")
    #expect(inventory.subject?.focusCount == 2)
    #expect(inventory.focusTrack.map(\.label) == ["斜挎包 · 黑色", "斜挎包 · 黑色"])
    #expect(inventory.focusSwitches == 0)
    // 排在最前面的应该是主角。
    #expect(inventory.items.first?.label == "斜挎包 · 黑色")
}

@Test func inventoryReportsFocusPullingFromOneItemToAnother() {
    // 先对焦在黑包上，后面焦点转到白包上：这是一次对焦转移，不是“画面里有两个包”。
    let black = UUID()
    let white = UUID()
    let frames = [
        frame(0, 0.0, [object("斜挎包 · 黑色", product: black, role: .subject, sharpness: 90),
                       object("斜挎包 · 米白", product: white, role: .supporting, sharpness: 30)]),
        frame(1, 2.0, [object("斜挎包 · 黑色", product: black, role: .supporting, sharpness: 25),
                       object("斜挎包 · 米白", product: white, role: .subject, sharpness: 88)])
    ]
    let inventory = BrollInventory.build(frames: frames)

    #expect(inventory.focusSwitches == 1)
    #expect(inventory.focusTrack.map(\.label) == ["斜挎包 · 黑色", "斜挎包 · 米白"])
    // 两件都是清单里认出来的产品，都要能归组。
    #expect(inventory.products.count == 2)
    #expect(inventory.unknowns.isEmpty)
}

@Test func inventoryKeepsUnknownsSeparateFromBackgroundAndGear() {
    let frames = [
        frame(0, 0.0, [object("方形小包", role: .unknown, spot: .right, sharpness: 66),
                       object("桌面", role: .background, sharpness: 20),
                       object("相机", role: .gear, sharpness: 15)])
    ]
    let inventory = BrollInventory.build(frames: frames)

    // 不认识的、又不是背景也不是设备的那件才需要问用户“这是竞品吗”。
    #expect(inventory.unknowns.map(\.label) == ["方形小包"])
    #expect(inventory.background.map(\.label) == ["桌面"])
    #expect(inventory.gear.map(\.label) == ["相机"])
}

@Test func inventoryFallsBackToTheMarkedSubjectWhenSharpnessIsMissing() {
    // 模型偶尔不填清晰度：这时候退回它自己标的主体，而不是随便挑第一件。
    let frames = [
        frame(0, 0.0, [object("杯子", role: .background, sharpness: 0),
                       object("斜挎包", role: .subject, sharpness: 0)])
    ]
    let inventory = BrollInventory.build(frames: frames)
    #expect(inventory.subject?.label == "斜挎包")
}

@Test func assetInventoryIsNilUntilSomethingIsRecognized() {
    var asset = BrollAsset(path: "/tmp/a.MP4", name: "a.MP4", duration: 5, width: 1920, height: 1080)
    #expect(asset.inventory == nil)

    // 只跑过 Vision 识别：还没有物品，界面不该显示这一块。
    asset.analysis = BrollAnalysis(tags: [BrollTag(identifier: "bag", label: "包", confidence: 0.6)])
    #expect(asset.inventory == nil)

    asset.analysis = BrollAnalysis(product: BrollProductPick(frames: [frame(0, 0.0, [object("斜挎包", role: .subject, sharpness: 60)])]))
    #expect(asset.inventory?.items.count == 1)
}

@Test func aProductOnlyScanIsNotCountedAsContentRecognition() {
    // 只跑过物品识别时会给这条素材补一个空壳：不能因此就说“已识别画面内容”，
    // 否则卡片会拿着默认值说它“固定镜头”，运动筛选也会跟着错。
    var asset = BrollAsset(path: "/tmp/a.MP4", name: "a.MP4", duration: 5, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(product: BrollProductPick(frames: [frame(0, 0.0, [object("斜挎包", role: .subject, sharpness: 60)])]))
    #expect(!asset.isAnalyzed)
    #expect(asset.inventory?.items.count == 1)

    asset.analysis?.tags = [BrollTag(identifier: "backpack", label: "双肩包", confidence: 0.5)]
    #expect(asset.isAnalyzed)
}

@MainActor @Test func previewMomentTargetsTheSelectedAssetAndFiresEveryTime() {
    let model = EditorModel()
    let first = BrollAsset(path: "/tmp/a.MP4", name: "a.MP4", duration: 10, width: 1920, height: 1080)
    let second = BrollAsset(path: "/tmp/b.MP4", name: "b.MP4", duration: 10, width: 1920, height: 1080)
    model.brollAssets = [first, second]

    // 没选中素材时不发跳转请求。
    model.previewBrollMoment(1)
    #expect(model.brollPreviewRequest == nil)

    model.selectedBrollID = second.id
    model.previewBrollMoment(2.5)
    #expect(model.brollPreviewRequest?.assetID == second.id)
    #expect(model.brollPreviewRequest?.time == 2.5)

    // 同一个时间点连点两次也要重新触发，不然点第二下没反应。
    let firstID = model.brollPreviewRequest?.id
    model.previewBrollMoment(2.5)
    #expect(model.brollPreviewRequest?.id != firstID)

    // 负时间要夹到 0。
    model.previewBrollMoment(-3)
    #expect(model.brollPreviewRequest?.time == 0)
}

@Test func recognizedObjectsSurviveProjectRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-objects-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "objects.codecut")

    let productID = UUID()
    var asset = BrollAsset(path: "/tmp/product.MP4", name: "product.MP4", duration: 8, width: 3840, height: 2160)
    asset.analysis = BrollAnalysis(product: BrollProductPick(
        start: 0, end: 3, score: 80,
        frames: [frame(0, 1.0, [object("斜挎包 · 黑色", product: productID, role: .subject, spot: .center, sharpness: 91),
                                object("未知小包", role: .unknown, spot: .right, sharpness: 40)])],
        reasons: [], summary: "包在画面中间"
    ))
    try ProjectStore.save(
        ProjectDocument(
            name: "objects", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm,
            frameRate: 25, brollAssets: [asset]
        ),
        to: url
    )
    let restored = try ProjectStore.load(from: url)

    let frames = try #require(restored.brollAssets?.first?.productPick?.frames)
    #expect(frames.first?.objects.count == 2)
    #expect(frames.first?.objects.first?.label == "斜挎包 · 黑色")
    #expect(frames.first?.objects.first?.productID == productID)
    #expect(frames.first?.objects.first?.spot == .center)
    #expect(restored.brollAssets?.first?.inventory?.unknowns.map(\.label) == ["未知小包"])
}

@Test func framesWrittenBeforeObjectsExistedStillDecode() throws {
    // 老项目里的帧结论没有 objects 字段，必须还能读，界面退回原来的样子。
    let json = """
    {"id": "\(UUID().uuidString)", "path": "/tmp/a.MP4", "name": "a.MP4", "duration": 5, "width": 1920, "height": 1080,
     "analysis": {"tags": [], "motion": "固定镜头", "zoom": "无变焦", "energy": "稳定",
      "horizontalShift": 0, "verticalShift": 0, "divergence": 0, "activity": 0, "shiftPerSecond": 0,
      "product": {"start": 1, "end": 2, "score": 80, "reasons": [], "summary": "s",
       "analyzedAt": "2026-01-01T00:00:00Z", "engine": "本地视觉模型",
       "frames": [{"index": 0, "time": 1, "presence": "含产品", "confidence": 80, "sharpness": 70, "note": "包在画面里"}]},
      "analyzedAt": "2026-01-01T00:00:00Z", "engine": "Apple Vision"}}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let asset = try decoder.decode(BrollAsset.self, from: Data(json.utf8))

    #expect(asset.productPick?.frames.first?.objects.isEmpty == true)
    #expect(asset.inventory == nil)
    #expect(asset.productPick?.score == 80)
}

// MARK: - 产品清单

@Test func catalogItemsBecomeNumberedCandidates() {
    var profile = ProductProfile()
    profile.name = "NAYOSMART UL1 斜挎包"
    var black = ProductCatalogItem(name: "NAYOSMART UL1 斜挎包", color: "黑色")
    black.sku = "UL1-BK"
    black.referenceImages = [ProductReferenceImage(path: "/tmp/不存在的图.jpg")]
    var white = ProductCatalogItem(name: "NAYOSMART UL1 斜挎包", color: "米白")
    white.sku = "UL1-IV"
    profile.catalog = [black, white]

    let candidates = ProductPicker.candidates(for: profile)
    #expect(candidates.count == 2)
    // 编号从 1 开始，模型回答的 product_index 就是它。
    #expect(candidates.map(\.index) == [1, 2])
    #expect(candidates.map(\.productID) == [black.id, white.id])
    #expect(candidates[0].displayLabel == "NAYOSMART UL1 斜挎包 · 黑色")
    #expect(candidates[1].displayLabel == "NAYOSMART UL1 斜挎包 · 米白")
}

@Test func legacyProfileWithoutCatalogBecomesASingleStableProduct() {
    var profile = ProductProfile()
    profile.name = "NAYOSMART UL1 斜挎包"
    let first = profile.products
    let second = profile.products
    #expect(first.count == 1)
    // 没有清单的老档案也得有稳定身份，不然同款产品在不同次识别里会被当成两件。
    #expect(first.first?.id == second.first?.id)
    #expect(first.first?.id == StableID.make("profile:NAYOSMART UL1 斜挎包"))

    // 换了产品就换身份。
    profile.name = "另一个包"
    #expect(profile.products.first?.id != first.first?.id)
}

@Test func productListingNumbersTheShotsInOrder() {
    let candidates = [
        BrollCandidate(index: 1, productID: UUID(), name: "斜挎包", color: "黑色", images: [Data([1]), Data([2])]),
        BrollCandidate(index: 2, productID: UUID(), name: "斜挎包", color: "米白")
    ]
    let listing = ProductPicker.listing(candidates)
    #expect(listing.contains("1) 斜挎包 · 黑色 —— 附图 1-2"))
    #expect(listing.contains("2) 斜挎包 · 米白 —— 没有参考图"))
}

@Test func promptWithoutAProductListOnlyAsksForItems() {
    // 没读 brief 的时候也能先认物品：这时候不能让模型硬判“是不是这款产品”。
    let prompt = ProductPicker.promptText(profile: ProductProfile(), candidates: [], referenceCount: 0)
    #expect(prompt.contains("没有给产品清单"))
    #expect(prompt.contains("presence_code 一律填 0"))
    #expect(prompt.contains("role"))

    let candidates = [candidate(1, "斜挎包", color: "黑色")]
    let withList = ProductPicker.promptText(profile: ProductProfile(), candidates: candidates, referenceCount: 1)
    #expect(withList.contains("1) 斜挎包 · 黑色"))
    #expect(withList.contains("product_index"))

    // 逐帧会变的东西（时间点）不能出现在这段固定文字里：
    // 它一变，前面攒下来的前缀缓存就废了，参考图要重新编码一遍（实测 5 秒变 16 秒）。
    #expect(!withList.contains("2.5"))
    #expect(ProductPicker.frameNote(2.5).contains("0:02.5"))
    #expect(ProductPicker.frameNote(2.5) != ProductPicker.frameNote(3.5))
}

@Test func picksWithoutATargetRoundTripAndOldOnesStillHaveOne() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-notarget-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "notarget.codecut")

    var asset = BrollAsset(path: "/tmp/a.MP4", name: "a.MP4", duration: 6, width: 1920, height: 1080)
    var pick = BrollProductPick(frames: [frame(0, 0.0, [object("斜挎包", role: .subject, sharpness: 70)])])
    pick.hasTarget = false
    asset.analysis = BrollAnalysis(product: pick)
    try ProjectStore.save(
        ProjectDocument(name: "n", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25, brollAssets: [asset]),
        to: url
    )

    let restored = try ProjectStore.load(from: url)
    #expect(restored.brollAssets?.first?.productPick?.hasTarget == false)
    #expect(restored.brollAssets?.first?.inventory?.items.count == 1)

    // 老项目里的识别结果没有 hasTarget 字段，要按“有目标产品”读，界面才不会突然少一块。
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(BrollProductPick.self, from: Data("""
    {"start": 0, "end": 0, "score": 0, "frames": [], "reasons": [], "summary": "", "engine": "本地视觉模型"}
    """.utf8))
    #expect(legacy.hasTarget)
}

@MainActor @Test func confirmingACompetitorFeedsTheNextAnalysis() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-competitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "competitor.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "c", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    model.confirmBrollCompetitor("方形小包")
    model.ignoreBrollObject("桌面")
    try model.save()

    let reopened = EditorModel()
    try await reopened.openProject(url)
    #expect(reopened.productProfile.knownCompetitors == ["方形小包"])
    #expect(reopened.productProfile.knownIgnored == ["桌面"])
    // 确认过的竞品要进提示词，下次识别时模型直接按竞品判断。
    #expect(reopened.productProfile.promptBlock.contains("方形小包"))
}

/// 造一张真图文件。候选参考图是真的去解码文件的，路径不存在就拿不到图，测不出借用问题。
private func writeTestPNG(_ folder: URL, _ name: String) throws -> String {
    let width = 64, height = 48
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let url = folder.appending(path: name)
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url.path
}

@Test func catalogItemsDoNotBorrowEachOthersReferenceImages() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-refs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let shot = try writeTestPNG(folder, "shot.png")
    var profile = ProductProfile()
    profile.name = "斜挎包"
    profile.referenceImages = [ProductReferenceImage(path: shot, caption: "档案级")]
    var black = ProductCatalogItem(name: "斜挎包", color: "黑色")
    black.referenceImages = [ProductReferenceImage(path: shot, caption: "黑色")]
    let white = ProductCatalogItem(name: "斜挎包", color: "米白")
    profile.catalog = [black, white]

    let candidates = ProductPicker.candidates(for: profile)
    #expect(candidates.count == 2)
    #expect(candidates[0].images.count == 1)
    // 米白款没有自己的图时不能借用黑色款的：模型会把黑色认成米白，颜色分组就串了。
    #expect(candidates[1].images.isEmpty)

    // 只有一条候选（老档案、或者只给了一组图）时，档案级的图就是它的图。
    profile.catalog = nil
    let single = ProductPicker.candidates(for: profile)
    #expect(single.count == 1)
    #expect(single[0].images.count == 1)
}

// MARK: - 用认出来的物品搜索和筛选

/// 造一件带颜色 / SKU 的物品，用来测搜索。
private func detailedObject(
    _ label: String,
    product: UUID? = nil,
    color: String = "",
    sku: String = "",
    role: BrollObjectRole = .subject,
    sharpness: Int = 80
) -> BrollObject {
    BrollObject(slot: 1, label: label, productID: product, sku: sku, color: color, role: role, sharpness: sharpness)
}

@MainActor private func modelWithRecognizedItems() -> EditorModel {
    let model = EditorModel()
    let bagID = UUID()

    var black = BrollAsset(path: "/tmp/black.MP4", name: "C4025.MP4", duration: 6, width: 1920, height: 1080)
    black.analysis = BrollAnalysis(product: BrollProductPick(frames: [
        frame(0, 0.0, [detailedObject("NAYOSMART UL1 斜挎包 · 黑色", product: bagID, color: "黑色", sku: "UL1-BK", sharpness: 88),
                       object("桌面", role: .background, sharpness: 20)])
    ]))

    var white = BrollAsset(path: "/tmp/white.MP4", name: "C4026.MP4", duration: 5, width: 1920, height: 1080)
    white.analysis = BrollAnalysis(product: BrollProductPick(frames: [
        frame(0, 0.0, [detailedObject("NAYOSMART UL1 斜挎包 · 米白", product: UUID(), color: "米白", sku: "UL1-IV", sharpness: 70),
                       detailedObject("方形小包", role: .unknown, sharpness: 55)])
    ]))
    model.brollAssets = [black, white]
    return model
}

@MainActor @Test func brollSearchFindsItemsByColorAndSku() {
    let model = modelWithRecognizedItems()

    // 颜色、SKU、角色名都应该能搜到 —— 认出物品之后，找素材靠的就是这些词。
    model.brollQuery = "黑色"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4025.MP4"])

    model.brollQuery = "ul1-iv"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4026.MP4"])

    model.brollQuery = "背景"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4025.MP4"])

    model.brollQuery = "4026"
    #expect(model.visibleBrollAssets.map(\.name) == ["C4026.MP4"])
}

@MainActor @Test func pendingUnknownsAreCountedAndFilterable() {
    let model = modelWithRecognizedItems()

    #expect(model.scannedBrollCount == 2)
    #expect(model.analyzedBrollCount == 0)   // 只跑过物品识别，没看过画面内容
    #expect(model.pendingUnknownBrollCount == 1)

    model.brollOnlyPendingUnknown = true
    #expect(model.visibleBrollAssets.map(\.name) == ["C4026.MP4"])

    // 确认过之后就不该再出现在“待确认”里，筛选也应该把它放走。
    model.confirmBrollCompetitor("方形小包")
    #expect(model.pendingUnknownBrollCount == 0)
    #expect(model.visibleBrollAssets.isEmpty)
}

// MARK: - 整条链路
//
// 上面测的都是各段。这里用固定的模型回答跑完整条路：
// 逐帧回答 → 帧结论 → 物品清单；以及 brief → 产品清单。

@Test func cannedFrameAnswersBecomeAnItemList() {
    let candidates = [candidate(1, "NAYOSMART UL1 斜挎包", color: "黑色", sku: "UL1-BK"),
                      candidate(2, "NAYOSMART UL1 斜挎包", color: "米白", sku: "UL1-IV")]
    // 模型每帧的真实回答长这样：一个产品档位 + 一张物品清单。
    let answers: [[String: Any]] = [
        ["presence_code": 3, "confidence": 92, "sharpness": 88, "note": "包在画面中间",
         "objects": [
            ["name": "黑色斜挎包", "product_index": 1, "role": "subject", "position": "center", "sharpness": 90, "confidence": 93],
            ["name": "桌面", "product_index": 0, "role": "background", "position": "bottom", "sharpness": 20, "confidence": 80]
         ]],
        ["presence_code": 1, "confidence": 60, "sharpness": 55, "note": "焦点转到另一个包上",
         "objects": [
            ["name": "米白斜挎包", "product_index": 2, "role": "subject", "position": "right", "sharpness": 86, "confidence": 88],
            ["name": "方盒", "product_index": 0, "role": "unknown", "position": "left", "sharpness": 40, "confidence": 30]
         ]]
    ]
    let frames = answers.enumerated().map { index, answer in
        ProductPicker.verdict(index: index, time: Double(index) * 2, object: answer, candidates: candidates)
    }
    let inventory = BrollInventory.build(frames: frames)

    // 两帧各自的产品档位单独存，物品清单跨帧合并。
    #expect(frames.map(\.presence) == [.mainSubject, .hinted])
    #expect(inventory.products.map(\.sku) == ["UL1-BK", "UL1-IV"])
    #expect(inventory.background.map(\.label) == ["桌面"])
    #expect(inventory.unknowns.map(\.label) == ["方盒"])
    // 焦点从黑包换到白包：这条素材里有对焦转移，两件都是清单里的产品。
    #expect(inventory.subject?.label == "NAYOSMART UL1 斜挎包 · 黑色")
    #expect(inventory.focusSwitches == 1)
}

@Test func aTextBriefTurnsIntoOneCatalogEntryPerColor() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-brief-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let brief = folder.appending(path: "brief.txt")
    try "NAYOSMART UL1 斜挎包，本季主推黑色与米白两色。".write(to: brief, atomically: true, encoding: .utf8)
    let source = try BriefSourceReader.read(brief)

    let productName = "测试斜挎包 \(UUID().uuidString.prefix(6))"
    defer { try? FileManager.default.removeItem(at: LocalVLM.supportDirectory.appending(path: "ProductRefs/\(productName)")) }
    var prompts: [String] = []
    let result = try await ProductBriefReader.buildProfile(from: source, progress: { _, _ in }) { options in
        prompts.append(options.prompt)
        return [
            "name": productName,
            "summary": "黑色与米白两色尼龙斜挎包",
            "features": ["正面扣具", "侧面隐藏口袋"],
            "avoid": ["双肩包"],
            "products": [
                ["name": productName, "sku": "UL1-BK", "color": "黑色", "features": ["正面扣具"], "shots": []],
                ["name": productName, "sku": "UL1-IV", "color": "米白", "features": [], "shots": []]
            ]
        ]
    }

    // 提示词里必须明确要求“一个颜色一条”，否则模型只会给一个产品。
    #expect(prompts.first?.contains("每个颜色都要单独列一条") == true)
    #expect(result.profile.catalog?.count == 2)
    #expect(result.profile.catalog?.map(\.sku) == ["UL1-BK", "UL1-IV"])
    #expect(result.profile.catalog?.map(\.color) == ["黑色", "米白"])
    // 档案本身也要有内容，老界面（名字 / 特征 / 不要误判成）才不会空着。
    #expect(result.profile.name == productName)
    #expect(result.profile.avoid == ["双肩包"])

    // 产品清单直接就能变成识别候选。
    let candidates = ProductPicker.candidates(for: result.profile)
    #expect(candidates.map(\.displayLabel) == ["\(productName) · 黑色", "\(productName) · 米白"])
}

@Test func briefPhotosAreAttachedToTheColorTheyBelongTo() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-briefimg-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 用一张真图当 brief：这样“提出来的图”列表里至少有一张，能验证图有没有挂到该挂的那一条上。
    let shotPath = try writeTestPNG(folder, "product.png")
    let source = try BriefSourceReader.read(URL(fileURLWithPath: shotPath))
    #expect(!source.candidates.isEmpty)

    let productName = "测试双色包 \(UUID().uuidString.prefix(6))"
    defer { try? FileManager.default.removeItem(at: LocalVLM.supportDirectory.appending(path: "ProductRefs/\(productName)")) }
    let result = try await ProductBriefReader.buildProfile(from: source, progress: { _, _ in }) { _ in
        [
            "name": productName,
            "products": [
                ["name": productName, "sku": "UL1-BK", "color": "黑色", "shots": [1]],
                ["name": productName, "sku": "UL1-IV", "color": "米白", "shots": []]
            ]
        ]
    }

    let catalog = try #require(result.profile.catalog)
    #expect(catalog.count == 2)
    #expect(catalog[0].referenceImages.count == 1)
    // 米白那一条没有图，不能借用黑色那一条的。
    #expect(catalog[1].referenceImages.isEmpty)
    #expect(FileManager.default.fileExists(atPath: catalog[0].referenceImages[0].path))
}

// MARK: - 竞品候选
//
// 用户要的是“不是 brief 里、也不是背景的东西，你要向我确认”。
// 光有“看不出是什么”不够：一件明显是产品、但不是我们那款的（别家同类），也要冒出来问。

@Test func otherProductsAreParsedAndNeedConfirmation() {
    let candidates = [candidate(1, "NAYOSMART UL1 斜挎包", color: "黑色")]
    let parsed = ProductPicker.objects([
        ["name": "另一家的斜挎包", "product_index": 0, "role": "other_product", "position": "right", "sharpness": 74, "confidence": 66],
        ["name": "看不出是什么", "product_index": 0, "role": "unknown", "sharpness": 30],
        ["name": "桌面", "product_index": 0, "role": "background", "sharpness": 10]
    ], candidates: candidates)

    #expect(parsed[0].role == .otherProduct)
    #expect(parsed[0].role.needsConfirmation)
    #expect(parsed[1].role == .unknown)
    #expect(parsed[2].role == .background)
    #expect(!parsed[2].role.needsConfirmation)

    let inventory = BrollInventory.build(frames: [frame(0, 0.0, parsed)])
    #expect(inventory.otherProducts.map(\.label) == ["另一家的斜挎包"])
    // 要确认的是两件：不认识的 + 别家的产品；桌面不用问。
    #expect(inventory.pending.map(\.label) == ["另一家的斜挎包", "看不出是什么"])
    #expect(inventory.background.map(\.label) == ["桌面"])
}

@Test func aProductFromAnotherBrandIsNotSwallowedBySupporting() {
    // 同一件东西，一帧被当成普通陪衬、另一帧被认成别家产品：后者更该被看见，不能被合并掉。
    let frames = [
        frame(0, 0.0, [object("另一家的双肩包", role: .supporting, sharpness: 60)]),
        frame(1, 2.0, [object("另一家的双肩包", role: .otherProduct, sharpness: 55)])
    ]
    let inventory = BrollInventory.build(frames: frames)
    #expect(inventory.items.count == 1)
    #expect(inventory.items[0].role == .otherProduct)
    #expect(inventory.pending.count == 1)
}

@MainActor @Test func confirmingAnOtherBrandProductClearsItFromPending() {
    let model = EditorModel()
    var asset = BrollAsset(path: "/tmp/a.MP4", name: "a.MP4", duration: 6, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(product: BrollProductPick(frames: [
        frame(0, 0.0, [object("另一家的双肩包", role: .otherProduct, sharpness: 70)])
    ]))
    model.brollAssets = [asset]

    #expect(model.pendingUnknownBrollCount == 1)
    model.confirmBrollCompetitor("另一家的双肩包")
    #expect(model.pendingUnknownBrollCount == 0)
    // 确认过之后也不能再从“只看待确认”里冒出来。
    model.brollOnlyPendingUnknown = true
    #expect(model.visibleBrollAssets.isEmpty)
}

// MARK: - 模型回答格式漂移
//
// 提示词写的是英文码，但这是中文提示词下的模型，偶尔会直接用中文回答。
// 认不出来就当“不认识”会把整条素材变成一堆待确认的噪音，所以中英文都要认。

@Test func rolesAndPositionsAcceptChineseAnswers() {
    let candidates = [candidate(1, "斜挎包", color: "黑色")]
    let parsed = ProductPicker.objects([
        ["name": "斜挎包", "product_index": 1, "role": "主体", "position": "画面中间", "sharpness": 82],
        ["name": "另一家的包", "product_index": 0, "role": "竞品", "position": "右侧", "sharpness": 61],
        ["name": "桌面", "product_index": 0, "role": "背景道具", "position": "下方", "sharpness": 20],
        ["name": "相机", "product_index": 0, "role": "拍摄设备", "position": "右上角", "sharpness": 15]
    ], candidates: candidates)

    #expect(parsed.map(\.role) == [.subject, .otherProduct, .background, .gear])
    #expect(parsed.map(\.spot) == [.center, .right, .bottom, .topRight])
    // 清单里的产品照常归到清单那一条，不会因为中文回答就认不出来。
    #expect(parsed[0].productID == candidates[0].productID)

    let inventory = BrollInventory.build(frames: [frame(0, 0.0, parsed)])
    #expect(inventory.pending.map(\.label) == ["另一家的包"])
    #expect(inventory.background.map(\.label) == ["桌面"])
    #expect(inventory.gear.map(\.label) == ["相机"])
}

@Test func theSameThingWrittenTwiceInOneFrameCountsOnce() {
    let parsed = ProductPicker.objects([
        ["name": "桌面", "product_index": 0, "role": "background", "sharpness": 10],
        ["name": "桌面", "product_index": 0, "role": "background", "sharpness": 45]
    ], candidates: [])

    // 同一帧里写了两遍：留更清楚的那条，出现时间点也只算一次。
    #expect(parsed.count == 1)
    #expect(parsed[0].sharpness == 45)

    let inventory = BrollInventory.build(frames: [frame(0, 2.0, parsed)])
    #expect(inventory.items.count == 1)
    #expect(inventory.items[0].times == [2.0])
    #expect(inventory.items[0].frameIndexes == [0])
}

// MARK: - 按产品分组
//
// 分组是“实拍里真的认出来”的结果，不是 brief 的目录：
// brief 给了三个颜色，片子里只拍到黑白两个，就只长两个文件夹。

@MainActor private func catalogItem(_ color: String, _ sku: String, name: String = "NAYOSMART UL1 斜挎包") -> ProductCatalogItem {
    var item = ProductCatalogItem(name: name, color: color)
    item.sku = sku
    return item
}

@MainActor private func asset(_ name: String, objects: [BrollObject], at time: Double = 1.0) -> BrollAsset {
    var asset = BrollAsset(path: "/tmp/\(name)", name: name, duration: 6, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(product: BrollProductPick(frames: [frame(0, time, objects)]))
    return asset
}

@MainActor @Test func groupsOnlyContainProductsActuallySeenInTheFootage() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    let white = catalogItem("米白", "UL1-IV")
    let olive = catalogItem("橄榄绿", "UL1-OL")
    model.productProfile.catalog = [black, white, olive]

    let blackClip = asset("black.MP4", objects: [detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", sharpness: 85)])
    let whiteClip = asset("white.MP4", objects: [detailedObject("斜挎包 · 米白", product: white.id, color: "米白", sharpness: 70)])
    // 这条只有背景，没认到任何产品。
    let emptyClip = asset("desk.MP4", objects: [object("桌面", role: .background, sharpness: 20)])
    model.brollAssets = [blackClip, whiteClip, emptyClip]

    let groups = model.brollGroups
    // 橄榄绿 brief 里给了、片子里没有 → 不建分组。
    #expect(groups.map(\.sku) == ["UL1-BK", "UL1-IV"])
    #expect(groups.map(\.count) == [1, 1])
    #expect(groups[0].assets.map(\.name) == ["black.MP4"])
    #expect(model.brollUngroupedCount == 1)
}

@MainActor @Test func oneAssetCanSitInTwoProductFolders() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    let white = catalogItem("米白", "UL1-IV")
    model.productProfile.catalog = [black, white]

    // 一条素材里两个颜色都真正拍到了（镜头里有对焦转移，两件各自当过主角）：
    // 它要在两个文件夹里各出现一次。
    var clip = BrollAsset(path: "/tmp/two.MP4", name: "two.MP4", duration: 6, width: 1920, height: 1080)
    clip.analysis = BrollAnalysis(product: BrollProductPick(frames: [
        frame(0, 2.0, [
            detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .subject, sharpness: 90),
            detailedObject("斜挎包 · 米白", product: white.id, color: "米白", role: .supporting, sharpness: 62)
        ]),
        frame(1, 4.0, [
            detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .supporting, sharpness: 58),
            detailedObject("斜挎包 · 米白", product: white.id, color: "米白", role: .subject, sharpness: 92)
        ])
    ]))
    model.brollAssets = [clip]

    let groups = model.brollGroups
    #expect(groups.map(\.sku) == ["UL1-BK", "UL1-IV"])
    // 两个分组里是同一份素材（同一个 id），不是复制出来的两份。
    #expect(groups.first?.assets.map(\.id) == [clip.id])
    #expect(groups.last?.assets.map(\.id) == [clip.id])
    #expect(model.brollUngroupedCount == 0)

    // 每个产品各自最清楚的一刻：黑色在 2.0，米白在 4.0。
    #expect(clip.bestMoment(of: black.id) == 2.0)
    #expect(clip.bestMoment(of: white.id) == 4.0)
    #expect(clip.bestMoment(of: UUID()) == nil)
}

@MainActor @Test func groupsRespectSearchAndKeepCatalogOrder() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    let white = catalogItem("米白", "UL1-IV")
    model.productProfile.catalog = [black, white]
    model.brollAssets = [
        asset("black.MP4", objects: [detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", sharpness: 85)]),
        asset("white.MP4", objects: [detailedObject("斜挎包 · 米白", product: white.id, color: "米白", sharpness: 70)])
    ]

    // 顺序跟着产品清单：清单里黑在前，分组里黑也在前。
    #expect(model.brollGroups.map(\.sku) == ["UL1-BK", "UL1-IV"])

    // 搜索是全局的：搜“米白”之后只留下米白那个分组。
    model.brollQuery = "米白"
    #expect(model.brollGroups.map(\.sku) == ["UL1-IV"])
    #expect(model.brollUngroupedCount == 0)

    // 搜不到产品的时候，分组清空，但素材还在左栏（未归入）。
    model.brollQuery = "不存在的东西"
    #expect(model.brollGroups.isEmpty)
}

@MainActor @Test func groupsIgnoreUnmatchedItemsEvenWhenTheyAreTheSubject() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    model.productProfile.catalog = [black]
    // 主角是个没认出来的东西：它不该变成一个产品分组。
    model.brollAssets = [
        asset("unknown.MP4", objects: [object("方盒", role: .unknown, sharpness: 88)])
    ]
    #expect(model.brollGroups.isEmpty)
    #expect(model.brollUngroupedCount == 1)
}

// MARK: - 运动曲线
//
// 用户要的是量化：轨迹、速度、以及在哪些区间里是静止/匀速/加速/晃。
// 光流本身只能真跑视频才测得了，所以这里把「从采样点算结论」这一段钉住。

private func motionSample(_ time: Double, x: Double, y: Double, speed: Double, direction: Double = 0, divergence: Double = 0) -> BrollMotionSample {
    BrollMotionSample(time: time, x: x, y: y, speed: speed, direction: direction, divergence: divergence)
}

/// 按「每一步画面挪了多少」拼一条轨迹，0.2 秒一个采样点。
/// 切可用片段看的是轨迹本身，用位移而不是速度来构造，才能和真素材一致。
/// `divergence` 是每一步的径向发散度：小于 0 是拉远，大于 0 是推近。
private func trajectory(_ steps: [(dx: Double, dy: Double)], interval: Double = 0.2, divergence: Double = 0) -> [BrollMotionSample] {
    var samples = [motionSample(0, x: 0, y: 0, speed: 0)]
    var x = 0.0, y = 0.0
    for (index, step) in steps.enumerated() {
        x += step.dx; y += step.dy
        let speed = (step.dx * step.dx + step.dy * step.dy).squareRoot() / interval
        samples.append(motionSample(Double(index + 1) * interval, x: x, y: y, speed: speed, divergence: divergence))
    }
    return samples
}

@Test func motionCurveSplitsHoldFromMovement() {
    // 前 1 秒基本不动（速度 0.1），后面匀速移动（速度 1.0）。
    var samples: [BrollMotionSample] = []
    var x = 0.0
    for index in 0...10 {
        let speed = index <= 4 ? 0.1 : 1.0
        if index > 0 { x += 0.2 * speed }
        samples.append(motionSample(Double(index) * 0.2, x: x, y: 0, speed: index == 0 ? 0 : speed))
    }
    let phases = BrollMotionCurve.phases(from: samples, window: 0.6)

    #expect(phases.first?.kind == .hold)
    #expect(phases.last?.kind == .steady)
    // 阶段要连成一条时间轴，中间不能有空档。
    for (previous, next) in zip(phases, phases.dropFirst()) {
        #expect(abs(previous.end - next.start) < 0.0001)
    }
}

@Test func motionCurveCallsBackAndForthUnsettled() {
    // 来回摆：走的路不少，净位移却几乎回到原点。
    var samples: [BrollMotionSample] = [motionSample(0, x: 0, y: 0, speed: 0)]
    for index in 1...9 {
        samples.append(motionSample(Double(index) * 0.2, x: index % 2 == 0 ? 3 : -3, y: 0, speed: 2.0))
    }
    let phases = BrollMotionCurve.phases(from: samples, window: 0.6)

    // 整条都是来回晃：相邻同类阶段会合并，所以是一段盖住整条采样。
    let phase = phases.first
    #expect(phases.count == 1)
    #expect(phase?.kind == .unsettled)
    #expect(abs((phase?.start ?? -1) - samples[0].time) < 0.0001)
    #expect(abs((phase?.end ?? -1) - samples[samples.count - 1].time) < 0.0001)
    // 来回晃的素材不该被说成“向右移动”。
    #expect(!phases.contains { $0.kind == .accelerating })
}

@Test func motionCurveSpotsAcceleration() {
    var samples: [BrollMotionSample] = []
    var x = 0.0
    for index in 0...9 {
        let speed = 0.4 * (1 + Double(index) * 0.5)
        if index > 0 { x += 0.2 * speed }
        samples.append(motionSample(Double(index) * 0.2, x: x, y: 0, speed: index == 0 ? 0 : speed))
    }
    let phases = BrollMotionCurve.phases(from: samples, window: 0.6)
    #expect(phases.contains { $0.kind == .accelerating })
}

@Test func motionCurveSummaryReportsNetShiftAndPeakSpeed() {
    let samples = [
        motionSample(0, x: 0, y: 0, speed: 0),
        motionSample(0.5, x: 3, y: 4, speed: 2.0),
        motionSample(1.0, x: 6, y: 8, speed: 1.0)
    ]
    let curve = BrollMotionCurve(samples: samples, duration: 1.0)

    #expect(curve.isUsable)
    // 3-4-5 的两倍：净位移 10%。
    #expect(abs(curve.netShift - 10) < 0.0001)
    #expect(curve.peakSpeed == 2.0)
    #expect(abs(curve.averageSpeed - 10) < 0.0001)
    // 两段各 5%：活跃度和净位移一样，说明是直着走不是来回。
    #expect(abs(curve.activity - 10) < 0.0001)

    // 采样点不够时不能装成有曲线。
    #expect(!BrollMotionCurve(samples: [samples[0], samples[1]]).isUsable)
}
// MARK: - 可用片段
//
// 「可用片段」是剪辑真正要的东西：一条素材里哪几段能剪进去。
// 判定只看运动轨迹，不需要产品识别、不需要联网，所以这里用构造出来的轨迹钉住规则。

@Test func usableSegmentsKeepOnlyTheSteadyPartOfALockedOffShot() {
    // 固定镜头：开头挪了 1 秒机器、中间 3 秒不动、结尾又挪了 1 秒。
    var steps: [(dx: Double, dy: Double)] = Array(repeating: (dx: 0.8, dy: 0.0), count: 5)   // 0.0–1.0 秒
    steps += Array(repeating: (dx: 0.0, dy: 0.0), count: 15)                                    // 1.0–4.0 秒
    steps += Array(repeating: (dx: 0.8, dy: 0.0), count: 5)                                  // 4.0–5.0 秒

    let segments = BrollMotionCurve.usableSegments(from: trajectory(steps))

    // 只有中间静止的那一段算镜头；前后挪机器的两下不是内容。
    #expect(segments.count == 1)
    #expect(segments.first?.kind == .lockedOff)
    #expect(abs((segments.first?.start ?? -1) - 1.0) < 0.001)
    #expect(abs((segments.first?.end ?? -1) - 4.0) < 0.001)
}

@Test func usableSegmentsSplitASliderRoundTripIntoTwoShots() {
    // 滑轨：往右推 3 秒，再往左推回来 3 秒。一个来回是两个可用片段。
    let steps = Array(repeating: (dx: 0.6, dy: 0.0), count: 15) + Array(repeating: (dx: -0.6, dy: 0.0), count: 15)

    let segments = BrollMotionCurve.usableSegments(from: trajectory(steps))

    #expect(segments.count == 2)
    #expect(segments.first?.kind == .oneWay)
    #expect(segments.first?.motion == .panRight)
    #expect(abs((segments.first?.duration ?? 0) - 3.0) < 0.001)
    #expect(segments.last?.kind == .oneWay)
    #expect(segments.last?.motion == .panLeft)
    // 两段首尾相接，中间不能留缝。
    #expect(abs((segments.first?.end ?? -1) - (segments.last?.start ?? -1)) < 0.001)
}

@Test func usableSegmentsIgnoreHoldsShorterThanTheMinimum() {
    // 中间只停了 0.8 秒：短于最短时长，只能算运镜的过渡，不能当固定镜头用。
    var steps: [(dx: Double, dy: Double)] = Array(repeating: (dx: 0.6, dy: 0.0), count: 8)
    steps += Array(repeating: (dx: 0.0, dy: 0.0), count: 4)
    steps += Array(repeating: (dx: 0.6, dy: 0.0), count: 8)

    let segments = BrollMotionCurve.usableSegments(from: trajectory(steps))
    #expect(!segments.contains { $0.kind == .lockedOff })

    // 停够 1.2 秒就该认出来。
    var longer: [(dx: Double, dy: Double)] = Array(repeating: (dx: 0.6, dy: 0.0), count: 8)
    longer += Array(repeating: (dx: 0.0, dy: 0.0), count: 6)
    longer += Array(repeating: (dx: 0.6, dy: 0.0), count: 8)
    #expect(BrollMotionCurve.usableSegments(from: trajectory(longer)).contains { $0.kind == .lockedOff })
}

@Test func usableSegmentsSplitAtAFocusSwitch() {
    // 整条都是固定镜头，但 1.8 秒处焦点从产品换到了背景：前后不是一个镜头。
    let samples = trajectory(Array(repeating: (dx: 0.0, dy: 0.0), count: 20))

    let segments = BrollMotionCurve.usableSegments(from: samples, focusSwitchTimes: [1.8])

    #expect(segments.count == 2)
    #expect(segments.allSatisfy { $0.kind == .lockedOff })
    // 切点落在两个半段之间，两半都记着是在这里切开的。
    #expect(abs((segments.first?.end ?? -1) - (segments.last?.start ?? -1)) < 0.001)
    #expect(segments.allSatisfy { $0.focusSwitchTime != nil })

    // 切换点离端点太近（两边凑不够一段）就不切，别切出半秒的碎片。
    let tooClose = BrollMotionCurve.usableSegments(from: samples, focusSwitchTimes: [0.2])
    #expect(tooClose.count == 1)
    #expect(tooClose.first?.hasInnerFocusSwitch == true)
}

@Test func usableSegmentsKeepAShortPushInAtTheEndOfALockedOffShot() {
    // 固定镜头收尾推近 1 秒：变焦是真镜头，不能和“挪机器”一起丢掉。
    var steps: [(dx: Double, dy: Double)] = Array(repeating: (dx: 0.0, dy: 0.0), count: 15)
    steps += Array(repeating: (dx: 0.12, dy: 0.0), count: 5)

    let segments = BrollMotionCurve.usableSegments(from: trajectory(steps, divergence: 1.2))

    #expect(segments.count == 2)
    #expect(segments.first?.kind == .lockedOff)
    #expect(segments.last?.zoom == .pushIn)
}

@Test func usableSegmentsKeepSmallDriftAsItsOwnKind() {
    // 轻微的上下摇：2.4 秒里慢慢往下走了 2.4%，没走出去。
    let segments = BrollMotionCurve.usableSegments(from: trajectory(Array(repeating: (dx: 0.0, dy: 0.2), count: 12)))

    #expect(segments.count == 1)
    #expect(segments.first?.kind == .drift)
    #expect(abs((segments.first?.netShift ?? 0) - 2.4) < 0.001)
}

@Test func usableSegmentsNeedNoProductRecognition() {
    let samples = trajectory(Array(repeating: (dx: 0.6, dy: 0.0), count: 15))
    var asset = BrollAsset(path: "/tmp/pan.MP4", name: "pan.MP4", duration: 3, width: 1920, height: 1080)
    // 只算过运动曲线：没跑产品识别，也没有焦点数据。
    asset.analysis = BrollAnalysis(motionCurve: BrollMotionCurve(samples: samples, duration: 3))

    let segments = asset.usableSegments
    #expect(segments.count == 1)
    #expect(segments.first?.kind == .oneWay)

    // 连曲线都没有时，不能装成切出了东西。
    var bare = BrollAsset(path: "/tmp/bare.MP4", name: "bare.MP4", duration: 3, width: 1920, height: 1080)
    bare.analysis = nil
    #expect(bare.usableSegments.isEmpty)
}

@Test func curveSampleCountFollowsDuration() {
    // 采样点按时长定：短素材有下限，长素材有上限，免得批量识别失控。
    #expect(BrollAnalyzer.curveSampleCount(for: 4) == BrollAnalyzer.curveSampleMinimum)
    #expect(BrollAnalyzer.curveSampleCount(for: 12) == BrollAnalyzer.curveSampleMaximum)
    #expect(BrollAnalyzer.curveSampleCount(for: 600) == BrollAnalyzer.curveSampleMaximum)
    #expect(BrollAnalyzer.curveSampleCount(for: 0) == BrollAnalyzer.curveSampleMinimum)
}

// MARK: - 手动出入点与勾选

/// 造一条三秒的横移素材，用来测片段的调整。
@MainActor private func panAsset() -> BrollAsset {
    var asset = BrollAsset(path: "/tmp/pan.MP4", name: "pan.MP4", duration: 3, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(motionCurve: BrollMotionCurve(
        samples: trajectory(Array(repeating: (dx: 0.6, dy: 0.0), count: 15)),
        duration: 3
    ))
    return asset
}

@MainActor @Test func adjustingSegmentBoundariesKeepsTheSegmentIdentity() {
    let model = EditorModel()
    let asset = panAsset()
    model.brollAssets = [asset]

    let detected = model.brollAssets[0].usableSegments[0]
    model.setBrollSegmentBoundary(asset.id, segmentID: detected.id, isStart: true, time: 0.5)
    model.setBrollSegmentBoundary(asset.id, segmentID: detected.id, isStart: false, time: 2.5)
    model.setBrollSegmentApproved(asset.id, segmentID: detected.id, approved: true)

    let edited = model.brollAssets[0].usableSegments[0]
    // id 必须还是识别时那一个 —— 它跟着当前出入点变的话，手动调整下次就找不回来了。
    #expect(edited.id == detected.id)
    #expect(abs(edited.start - 0.5) < 0.001)
    #expect(abs(edited.end - 2.5) < 0.001)
    #expect(edited.isAdjusted)
    #expect(edited.approved)
}

@MainActor @Test func boundariesCannotBeDraggedPastEachOther() {
    let model = EditorModel()
    let asset = panAsset()
    model.brollAssets = [asset]

    let detected = model.brollAssets[0].usableSegments[0]
    // 入点拖到出点后面：得被挡住，不能剪出一段倒着的片段。
    model.setBrollSegmentBoundary(asset.id, segmentID: detected.id, isStart: true, time: 99)
    let clamped = model.brollAssets[0].usableSegments[0]
    #expect(clamped.duration > 0.19)
    #expect(clamped.start < clamped.end)

    // 超出素材末尾的出点也一样。
    model.setBrollSegmentBoundary(asset.id, segmentID: detected.id, isStart: false, time: 99)
    #expect(model.brollAssets[0].usableSegments[0].end <= asset.duration + 0.001)
}

@MainActor @Test func clearingASegmentGoesBackToWhatWasDetected() {
    let model = EditorModel()
    let asset = panAsset()
    model.brollAssets = [asset]

    let detected = model.brollAssets[0].usableSegments[0]
    model.setBrollSegmentBoundary(asset.id, segmentID: detected.id, isStart: true, time: 0.5)
    model.setBrollSegmentApproved(asset.id, segmentID: detected.id, approved: true)
    model.clearBrollSegmentEdit(asset.id, segmentID: detected.id)

    let restored = model.brollAssets[0].usableSegments[0]
    #expect(abs(restored.start - detected.start) < 0.001)
    #expect(!restored.isAdjusted)
    #expect(!restored.approved)
    // 全清了就不该在项目里留个空壳。
    #expect(model.brollAssets[0].segmentEdits == nil)
}

@MainActor @Test func segmentEditsSurviveAProjectRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-segment-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "segments.codecut")

    var asset = panAsset()
    let id = BrollMotionCurve.segmentID(
        kind: .oneWay,
        start: asset.usableSegments[0].start,
        end: asset.usableSegments[0].end
    )
    asset.segmentEdits = [id: BrollSegmentEdit(start: 0.5, end: 2.5, approved: true)]

    let document = ProjectDocument(
        name: "segments", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm,
        frameRate: 25, brollAssets: [asset]
    )
    try ProjectStore.save(document, to: url)
    let restored = try #require(ProjectStore.load(from: url).brollAssets?.first)

    // 勾选和手动出入点是剪辑决定，重开项目必须还在。
    #expect(restored.segmentEdits?[id]?.approved == true)
    #expect(restored.segmentEdits?[id]?.start == 0.5)
    #expect(restored.usableSegments.first(where: { $0.id == id })?.approved == true)
}

@MainActor @Test func previewingASegmentAsksThePreviewToStopAtItsEnd() {
    let model = EditorModel()
    let asset = panAsset()
    model.brollAssets = [asset]
    model.selectedBrollID = asset.id

    let segment = model.brollAssets[0].usableSegments[0]
    model.playBrollSegment(asset.id, segment)

    let request = try! #require(model.brollPreviewRequest)
    #expect(request.assetID == asset.id)
    #expect(abs(request.time - segment.start) < 0.001)
    // 带着出点：预览面板播到这里会自己停住。
    #expect(request.stopAt == segment.end)

    // 只是跳到某一帧的请求不能带停止点，否则会莫名开始播。
    model.previewBrollMoment(1.2)
    #expect(model.brollPreviewRequest?.stopAt == nil)
}

@MainActor @Test func segmentEditsThatNoLongerMatchAnythingAreIgnored() {
    // 重算运动曲线之后片段会重新切，项目里可能留着对不上号的旧调整 —— 不能拿它去改别的段。
    var asset = panAsset()
    asset.segmentEdits = ["固定镜头@9.000-12.000": BrollSegmentEdit(start: 1, end: 2, approved: true)]

    #expect(asset.usableSegments.count == 1)
    #expect(!asset.usableSegments[0].isAdjusted)
    #expect(!asset.usableSegments[0].approved)
}

@Test func motionCurveSurvivesProjectRoundTrip() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-curve-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "curve.codecut")

    let samples = [
        motionSample(0.5, x: 0, y: 0, speed: 0),
        motionSample(1.0, x: 1.2, y: -0.4, speed: 2.4, direction: -18, divergence: 3.1),
        motionSample(1.5, x: 2.9, y: -0.9, speed: 3.1, direction: -15, divergence: 4.4)
    ]
    var curve = BrollMotionCurve(samples: samples, duration: 3.0)
    curve.phases = BrollMotionCurve.phases(from: samples)
    var asset = BrollAsset(path: "/tmp/curve.MP4", name: "curve.MP4", duration: 3, width: 1920, height: 1080)
    asset.analysis = BrollAnalysis(motionCurve: curve)
    try ProjectStore.save(
        ProjectDocument(name: "curve", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25, brollAssets: [asset]),
        to: url
    )

    let restored = try #require(ProjectStore.load(from: url).brollAssets?.first?.analysis?.motionCurve)
    #expect(restored.samples.count == 3)
    #expect(abs(restored.samples[2].x - 2.9) < 0.0001)
    #expect(restored.samples[2].direction == -15)
    #expect(abs(restored.netShift - samples[2].magnitude) < 0.0001)
}

@Test func analysesWithoutAMotionCurveStillDecode() throws {
    // 老项目里没有运动曲线这一层，读出来是 nil，界面就不显示这一块。
    let json = """
    {"tags": [], "motion": "固定镜头", "zoom": "无变焦", "energy": "稳定",
     "horizontalShift": 0, "verticalShift": 0, "divergence": 0, "activity": 0, "shiftPerSecond": 0,
     "analyzedAt": "2026-01-01T00:00:00Z", "engine": "Apple Vision"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let analysis = try decoder.decode(BrollAnalysis.self, from: Data(json.utf8))
    #expect(analysis.motionCurve == nil)
    #expect(analysis.motion == .staticShot)
}

// MARK: - 光流到轨迹（用已知位移的画面当基准）
//
// 上面测的是“从采样点算结论”。这一段测的是更前面的一步：
// 真图进 → Vision 光流 → 累计位移。画面位移是已知的，所以算错了一眼看得出来。

/// 整幅随机灰块纹理，内容整体向右移动 `shift` 像素。
///
/// 刻意不用条纹：条纹是周期图案，对稠密光流是病态输入（位移有多个解，实测根本测不准），
/// 拿它当基准只会得出“光流是坏的”这种错误结论。整幅都有纹理、且不带周期，位移才有唯一解。
private func textureImage(width: Int, height: Int, shift: Int) -> CGImage? {
    let block = 6
    let columns = width / block + 2
    let rows = max(1, height / block)
    var gray = [UInt8](repeating: 0, count: columns * rows)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for index in gray.indices {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        gray[index] = UInt8((seed >> 40) & 0xFF)
    }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let row = min(max(y / block, 0), rows - 1)
        for x in 0..<width {
            let column = min(max((x - shift) / block, 0), columns - 1)
            let value = gray[row * columns + column]
            let index = (y * width + x) * 4
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

/// 说明：光流报的是画面宽高的百分比，但**幅度是这套算法自己的刻度**（合成图案上实测约为真值的
/// 四成，识别结果里的“首尾位移”用的是同一个估计量）。所以这里断言的是方向、单调性和阶段，
/// 而不是绝对像素值 —— 绝对刻度要靠真实素材标定，不能拿合成图当真理。
@Test func opticalFlowCurveFollowsARightwardPan() throws {
    let width = 480, height = 270
    // 内容每步向右 8 像素，共 5 步。
    let frames = try (0..<6).map { index -> (time: Double, image: CGImage) in
        (Double(index) * 0.25, try #require(textureImage(width: width, height: height, shift: index * 8)))
    }
    let curve = BrollAnalyzer.motionCurve(frames: frames, duration: 1.5)

    #expect(curve.isUsable)
    let last = try #require(curve.samples.last)
    // 方向对：一直往右，上下基本不动。
    #expect(last.x > 1.5)
    #expect(abs(last.y) < 1.0)
    // 单调：每一步都在往右走，不会中途回退。
    let xs = curve.samples.map(\.x)
    #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 })
    // 方向角接近 0°（向右）。
    #expect(curve.samples.dropFirst().allSatisfy { abs($0.direction) < 30 })
    // 匀速移动不该被算成“静止”，阶段之间也不能有空档。
    #expect(!curve.phases.allSatisfy { $0.kind == .hold })
    for (previous, next) in zip(curve.phases, curve.phases.dropFirst()) {
        #expect(abs(previous.end - next.start) < 1e-6)
    }
}

@Test func opticalFlowCurveSeesAStaticShotAsHold() throws {
    // 同一个画面重复出现：必须判成静止，不能因为光流噪声被“走”出位移。
    let image = try #require(textureImage(width: 480, height: 270, shift: 0))
    let frames = (0..<5).map { (time: Double($0) * 0.25, image: image) }
    let curve = BrollAnalyzer.motionCurve(frames: frames, duration: 1.0)

    #expect(curve.isUsable)
    #expect(curve.netShift < 0.2)
    #expect(curve.peakSpeed < BrollAnalyzer.steadyPerSecond)
    #expect(!curve.phases.isEmpty)
    #expect(curve.phases.allSatisfy { $0.kind == .hold })
}

@Test func motionCurveNeedsAtLeastThreeFrames() throws {
    // 两帧算不出曲线，不能硬编一个出来。
    let image = try #require(textureImage(width: 320, height: 180, shift: 0))
    let curve = BrollAnalyzer.motionCurve(frames: [(0, image), (0.5, image)], duration: 1.0)
    #expect(!curve.isUsable)
    #expect(curve.samples.isEmpty)
}

// MARK: - 米白色的幽灵（真实素材上踩过的坑）
//
// 实拍里只有黑色的包，识别结果却报出一堆"米白色"。查下来是两份原因叠加：
// 1) brief 里"官方参数页"那张实物图被同时挂到了每个颜色上，模型拿着黑包官图去认米白；
// 2) 同一件东西被模型同时报成"黑色（主体）"和"米白色（陪衬）"，而陪衬的匹配以前照样进分组。

@Test func oneBriefPhotoIsNeverAttachedToTwoColors() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-shares-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 两张不同的 brief 图（一张是"黑包"官图，一张是别页的图）。
    let first = try writeTestPNG(folder, "page6.png")
    let second = try writeTestPNG(folder, "page12.png")
    let source = BriefSource(
        url: folder.appending(path: "brief.pdf"),
        format: .pdf,
        text: "NAYOSMART UL1 斜挎包：黑色 / 米白色",
        blocks: [],
        candidates: [
            BriefCandidate(label: "第 6 页 第 1 张图", path: first, pageIndex: 6),
            BriefCandidate(label: "第 12 页 第 1 张图", path: second, pageIndex: 12)
        ],
        previewPDF: folder.appending(path: "preview.pdf")
    )

    let productName = "测试两色包 \(UUID().uuidString.prefix(6))"
    defer { try? FileManager.default.removeItem(at: LocalVLM.supportDirectory.appending(path: "ProductRefs/\(productName)")) }

    // 模型把两个颜色都指到第 1 张图（真实 brief 上很常见）。
    let result = try await ProductBriefReader.buildProfile(from: source, progress: { _, _ in }) { _ in
        [
            "name": productName,
            "products": [
                ["name": productName, "color": "黑色", "shots": [1]],
                ["name": productName, "color": "米白色", "shots": [1, 2]]
            ]
        ]
    }

    let catalog = try #require(result.profile.catalog)
    let black = try #require(catalog.first { $0.color == "黑色" })
    let ivory = try #require(catalog.first { $0.color == "米白色" })
    // 第 1 张图按清单顺序归给黑色；米白不能也挂着它（否则模型会拿黑包的图认米白）。
    #expect(black.referenceImages.count == 1)
    #expect(ivory.referenceImages.map(\.caption) == ["第 12 页 第 1 张图"])
    #expect(Set(black.referenceImages.map(\.path)).isDisjoint(with: Set(ivory.referenceImages.map(\.path))))
}

@MainActor @Test func aBagThatIsOnlyEverInTheBackgroundDoesNotGetItsOwnFolder() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    let ivory = catalogItem("米白色", "UL1-IV")
    model.productProfile.catalog = [black, ivory]

    // 真实数据长这样：黑包是主体 95 分，米白只当陪衬、还更糊。
    model.brollAssets = [
        asset("C4025.MP4", objects: [
            detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .subject, sharpness: 95),
            detailedObject("斜挎包 · 米白色", product: ivory.id, color: "米白色", role: .supporting, sharpness: 75)
        ])
    ]

    let inventory = try? #require(model.brollAssets.first?.inventory)
    // 认出来了，但只算“疑似”：这一条并不是在拍米白。
    #expect(inventory?.suspected.map(\.label) == ["斜挎包 · 米白色"])
    #expect(inventory?.appearances.map(\.productID) == [black.id])

    // 分组只收“确实拍到”的颜色：只有一个黑包文件夹。
    #expect(model.brollGroups.map(\.sku) == ["UL1-BK"])
    #expect(model.brollGroups.first?.count == 1)
    #expect(model.brollUngroupedCount == 0)
}

@MainActor @Test func aGenuinelySeenColorStillGetsItsFolder() {
    // 反过来也要成立：米白真当上主角过，就必须进米白文件夹，不能被上面那条规则误伤。
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    let ivory = catalogItem("米白色", "UL1-IV")
    model.productProfile.catalog = [black, ivory]
    model.brollAssets = [
        asset("mix.MP4", objects: [
            detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .subject, sharpness: 95),
            detailedObject("斜挎包 · 米白色", product: ivory.id, color: "米白色", role: .supporting, sharpness: 70)
        ]),
        asset("ivoryOnly.MP4", objects: [
            detailedObject("斜挎包 · 米白色", product: ivory.id, color: "米白色", role: .subject, sharpness: 92)
        ])
    ]
    #expect(model.brollGroups.map(\.sku) == ["UL1-BK", "UL1-IV"])
    #expect(model.brollGroups.last?.assets.map(\.name) == ["ivoryOnly.MP4"])
}

@Test func aColorThatContradictsTheCatalogEntryIsNotAMatch() {
    let black = candidate(1, "斜挎包", color: "黑色", sku: "UL1-BK")
    let ivory = candidate(2, "斜挎包", color: "米白色", sku: "UL1-IV")
    let candidates = [black, ivory]

    // 模型说“认到 2 号（米白）”，但它自己写的颜色是黑色 —— 颜色对不上，不算这一款。
    let contradicted = ProductPicker.objects([
        ["name": "黑色斜挎包", "color": "黑色", "product_index": 2, "role": "subject", "sharpness": 90]
    ], candidates: candidates)
    #expect(contradicted.count == 1)
    #expect(contradicted[0].productID == nil)
    #expect(contradicted[0].label == "黑色斜挎包")

    // 颜色是同一类的说法（米白 / 象牙白 / 白）照常认。
    for color in ["米白", "象牙白", "白色"] {
        let matched = ProductPicker.objects([
            ["name": "包", "color": color, "product_index": 2, "role": "subject", "sharpness": 90]
        ], candidates: candidates)
        #expect(matched[0].productID == ivory.productID)
    }

    // 没给颜色、或者说了个认不出的颜色（"深色"）时不要否定匹配 —— 拿不准的信息不参与判断。
    let silent = ProductPicker.objects([
        ["name": "包", "product_index": 1, "role": "subject", "sharpness": 90]
    ], candidates: candidates)
    #expect(silent[0].productID == black.productID)
    let vague = ProductPicker.objects([
        ["name": "包", "color": "深色", "product_index": 1, "role": "subject", "sharpness": 90]
    ], candidates: candidates)
    #expect(vague[0].productID == black.productID)
}

// MARK: - 拖进 B-roll 页
//
// 以前 B-roll 页没有自己的接收区，拖进来的文件会被顶层那个“导入主视频”接走，
// B-roll 片段就这么变成了口播的主视频（真实踩过）。

@MainActor @Test func droppingSomethingThatIsNotVideoSaysSo() async {
    let model = EditorModel()
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let note = folder.appending(path: "笔记.txt")
    try? "这不是视频".write(to: note, atomically: true, encoding: .utf8)

    // 单个非视频文件
    await model.addBrollAssetsFromDrop([note])
    #expect(model.brollAssets.isEmpty)
    if case .failed(let text) = model.taskState {
        #expect(text.contains("没有可用的视频文件"))
    } else {
        Issue.record("拖进非视频文件时应该说清楚，而不是静默什么都不做")
    }

    // 文件夹里也没有视频
    await model.addBrollAssetsFromDrop([folder])
    #expect(model.brollAssets.isEmpty)
}

@MainActor @Test func droppingAFolderScansItForVideos() async {
    let model = EditorModel()
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-dropdir-\(UUID().uuidString)", directoryHint: .isDirectory)
    let nested = folder.appending(path: "子目录", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 相机卡里的 B-roll 常常分层存放：要递归扫，而且不能把 xml 之类的旁挂文件当成素材。
    try? Data([0x00]).write(to: nested.appending(path: "C4073.MP4"))
    try? "sidecar".write(to: nested.appending(path: "C4073M01.XML"), atomically: true, encoding: .utf8)

    await model.addBrollAssetsFromDrop([folder])
    // 这个假 mp4 读不出画面：应该被算作“读不出画面”，而不是悄悄成功或崩掉。
    if case .failed(let text) = model.taskState {
        #expect(text.contains("读不出画面"))
    } else {
        Issue.record("假视频应该报“读不出画面”，实际是 \(model.taskState)")
    }
    #expect(model.brollAssets.isEmpty)
}

// MARK: - 抽帧档位
//
// 帧数就是本地模型的调用次数：每问一帧实测 10–20 秒，所以这是"要快要全"的主开关。

@Test func scanModePicksFirstMiddleAndLast() throws {
    let image = try #require(textureImage(width: 24, height: 16, shift: 0))
    let frames = (0..<5).map { BrollAnalyzer.SampleFrame(index: $0, time: Double($0), cgImage: image) }
    // 一帧档问中间那帧（首尾常常是刚起机 / 已经停机）。
    #expect(ProductPicker.firstPassIndexes(in: frames, wanted: 1) == [2])
    // 三帧档问首 / 中 / 尾。
    #expect(ProductPicker.firstPassIndexes(in: frames, wanted: 3) == [0, 2, 4])
    // 五帧档就是全问。
    #expect(ProductPicker.firstPassIndexes(in: frames, wanted: 5) == [0, 1, 2, 3, 4])
}

@Test func askedFrameSpeedsStayAlignedWhenOnlySomeFramesAreAsked() throws {
    let image = try #require(textureImage(width: 24, height: 16, shift: 0))
    let frames = (0..<5).map { BrollAnalyzer.SampleFrame(index: $0, time: Double($0) * 0.5, cgImage: image) }
    let all = [1.0, 2.0, 3.0, 4.0]
    // 全问时和原来的分段速度一致。
    #expect(ProductPicker.speedsForAskedFrames(allSpeeds: all, frames: frames, askedIndexes: [0, 1, 2, 3, 4]) == all)
    // 只问首 / 中 / 尾时给出两段（每一段是中间那几步的累加）。
    let sparse = ProductPicker.speedsForAskedFrames(allSpeeds: all, frames: frames, askedIndexes: [0, 2, 4])
    #expect(sparse.count == 2)
    #expect(abs(sparse[0] - 1.5) < 0.0001)
    #expect(abs(sparse[1] - 3.5) < 0.0001)
    // 只问一帧时没有"段"可言。
    #expect(ProductPicker.speedsForAskedFrames(allSpeeds: all, frames: frames, askedIndexes: [2]).isEmpty)
}

// MARK: - 手动归类
//
// 模型认不出来的东西照样要能归类：局部特写（没有全景）、不在 brief 里的对比产品。
// 用户要的是：把素材拖进产品文件夹、自己新建文件夹命名、多选一起放。

@MainActor @Test func manualAssignmentPutsAnUnrecognizedClipIntoAProductFolder() throws {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    model.productProfile.catalog = [black]
    // 一条局部特写：模型什么都没认出来。
    let closeup = asset("C4025.MP4", objects: [])
    model.brollAssets = [closeup]
    #expect(model.brollGroups.isEmpty)
    #expect(model.brollUngroupedCount == 1)

    model.assignBrollAssets([closeup.id], to: black.id)

    // 手动放进去之后就该出现在这个文件夹里。
    let groups = model.brollGroups
    #expect(groups.map(\.sku) == ["UL1-BK"])
    #expect(groups.first?.assets.map(\.name) == ["C4025.MP4"])
    #expect(groups.first?.isManual == false)
    #expect(model.brollUngroupedCount == 0)
    // 识别结果没有被伪造：它依然没认到东西，只是被手动归了类。
    #expect(model.brollAssets.first?.inventory?.appearances.isEmpty ?? true)
}

@MainActor @Test func manualFolderCanBeCreatedNamedAndFilled() throws {
    let model = EditorModel()
    let first = asset("compare1.MP4", objects: [])
    let second = asset("compare2.MP4", objects: [])
    model.brollAssets = [first, second]

    let folderID = try #require(model.createBrollFolder(named: "对比产品"))
    #expect(model.brollGroups.map(\.label) == ["对比产品"])
    #expect(model.brollGroups.first?.isManual == true)
    #expect(model.brollGroups.first?.count == 0)

    // 多选一起放进去。
    model.assignBrollAssets([first.id, second.id], to: folderID)
    #expect(model.brollGroups.first?.assets.map(\.name) == ["compare1.MP4", "compare2.MP4"])
    #expect(model.brollUngroupedCount == 0)

    // 同名文件夹不让重复建。
    #expect(model.createBrollFolder(named: "对比产品") == nil)
    // 改名。
    model.renameBrollFolder(folderID, to: "竞品对比")
    #expect(model.brollGroups.map(\.label) == ["竞品对比"])
}

@MainActor @Test func removingFromAFolderSticksEvenWhenRecognitionSaysOtherwise() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    model.productProfile.catalog = [black]
    // 这条模型认成黑色（主体），但用户觉得认错了，要从这个文件夹里拿出去。
    let clip = asset("wrong.MP4", objects: [detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .subject, sharpness: 90)])
    model.brollAssets = [clip]
    #expect(model.brollGroups.first?.count == 1)

    model.removeBrollAssets([clip.id], from: black.id)
    #expect(model.brollGroups.isEmpty)
    #expect(model.brollUngroupedCount == 1)

    // 再手动放回去，剔除记录要撤掉。
    model.assignBrollAssets([clip.id], to: black.id)
    #expect(model.brollGroups.first?.count == 1)
}

@MainActor @Test func manualFoldersAndAssignmentsSurviveProjectRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-manual-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "manual.codecut")
    try ProjectStore.save(
        ProjectDocument(name: "manual", sourcePath: "", suggestions: [], breaths: [], breathMode: .confirm, frameRate: 25),
        to: url
    )

    let model = EditorModel()
    try await model.openProject(url)
    let clip = asset("closeup.MP4", objects: [])
    model.brollAssets = [clip]
    let folderID = try #require(model.createBrollFolder(named: "局部特写"))
    model.assignBrollAssets([clip.id], to: folderID)
    try model.save()

    let reopened = EditorModel()
    try await reopened.openProject(url)
    #expect(reopened.productProfile.customFolders.map(\.name) == ["局部特写"])
    #expect(reopened.brollAssets.first?.manualFolderIDs == [folderID])
    #expect(reopened.brollGroups.map(\.label) == ["局部特写"])
    #expect(reopened.brollGroups.first?.assets.map(\.name) == ["closeup.MP4"])
}

@Test func dragPayloadOnlyDecodesOurOwnDrops() {
    let a = UUID(), b = UUID()
    let encoded = BrollDragPayload.encode([a, b])
    #expect(BrollDragPayload.decode(encoded) == [a, b])
    // 别处拖过来的普通文字不能被当成素材。
    #expect(BrollDragPayload.decode("随便一段文字").isEmpty)
    #expect(BrollDragPayload.decode("codecut-broll-assets:不是UUID").isEmpty)
}

@MainActor @Test func deletingAManualFolderKeepsTheAssets() throws {
    let model = EditorModel()
    let clip = asset("x.MP4", objects: [])
    model.brollAssets = [clip]
    let folderID = try #require(model.createBrollFolder(named: "临时"))
    model.assignBrollAssets([clip.id], to: folderID)
    #expect(model.brollGroups.count == 1)

    model.deleteBrollFolder(folderID)
    #expect(model.brollGroups.isEmpty)
    // 素材还在；只是文件夹没了。
    #expect(model.brollAssets.count == 1)
    #expect(model.brollUngroupedCount == 1)
}

// MARK: - 多选与标签

@MainActor @Test func shiftClickSelectsARangeAndCommandTogglesOne() {
    let model = EditorModel()
    let clips = (1...5).map { asset("clip\($0).MP4", objects: []) }
    model.brollAssets = clips

    // 普通点一下：只选一条。
    model.selectBroll(clips[1].id, extend: false)
    #expect(model.brollSelection == [clips[1].id])

    // ⇧ 点第四条：从锚点拉到它。
    model.selectBroll(clips[3].id, extend: false, range: true)
    #expect(model.brollSelection == Set(clips[1...3].map(\.id)))

    // ⇧ 往回拉也成立。
    model.selectBroll(clips[0].id, extend: false, range: true)
    #expect(model.brollSelection == Set(clips[0...1].map(\.id)))

    // ⌘ 点是加一条 / 再点减一条。
    model.selectBroll(clips[2].id, extend: true)
    #expect(model.brollSelection.contains(clips[2].id))
    model.selectBroll(clips[2].id, extend: true)
    #expect(!model.brollSelection.contains(clips[2].id))
}

@MainActor @Test func aManuallyFiledClipShowsWhichFolderItIsIn() throws {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    model.productProfile.catalog = [black]
    let clip = asset("closeup.MP4", objects: [])
    model.brollAssets = [clip]

    let folderID = try #require(model.createBrollFolder(named: "对比产品"))
    model.assignBrollAssets([clip.id], to: black.id)
    model.assignBrollAssets([clip.id], to: folderID)

    // 拖进文件夹之后，手动归属要记在素材上（卡片就是靠它打标签）。
    #expect(model.brollAssets.first?.manualFolderIDs == [black.id, folderID])
    let folders = model.brollFolders(of: clip)
    #expect(folders.map(\.name) == ["NAYOSMART UL1 斜挎包 · 黑色", "对比产品"])
    #expect(folders.map(\.manual) == [false, true])
}

@MainActor @Test func aClipInNoFolderIsCountedAsUngrouped() {
    let model = EditorModel()
    let black = catalogItem("黑色", "UL1-BK")
    model.productProfile.catalog = [black]
    model.brollAssets = [
        asset("filed.MP4", objects: [detailedObject("斜挎包 · 黑色", product: black.id, color: "黑色", role: .subject, sharpness: 90)]),
        asset("loose.MP4", objects: [])
    ]
    #expect(model.brollUngroupedCount == 1)
    // 手动把剩下那条也归类，未归入就归零。
    model.assignBrollAssets([model.brollAssets[1].id], to: black.id)
    #expect(model.brollUngroupedCount == 0)
}
