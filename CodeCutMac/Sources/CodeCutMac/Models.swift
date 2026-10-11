import AVKit
import AppKit
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
    /// 只对重复句有意义：这一处按鱼骨图看是“读错”还是“成段重录、可能换了语气”。
    var repetitionKind: RepetitionKind? = nil

    enum Kind: String, Codable, CaseIterable, Sendable { case filler, correction, repetition, invalid }
    enum State: String, Codable, Sendable { case pending, kept, deleted }

    /// 鱼骨图判断法：没出差错的那一遍是主干，节点上的分支就是重复的几遍。
    /// 分支多长决定了它是不是“读错”。
    enum RepetitionKind: String, Codable, Sendable {
        /// 分支只有一句话或半句：读错重录，保留最后一遍就行，可以自动处理。
        case misread
        /// 分支是成段的好几句话：可能是在试不同语气，必须由人在两版里选一个。
        case alternateTake
    }
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

/// 删掉气口之后，在每个停顿处保留多少静音，让句子之间重新有层次。
enum PausePlan: String, Codable, CaseIterable, Sendable {
    case off, tight, standard, relaxed

    var label: String {
        switch self {
        case .off: "全部剪掉"
        case .tight: "紧凑"
        case .standard: "标准"
        case .relaxed: "舒缓"
        }
    }
    /// 句子与句子之间至少保留的静音（秒）
    var sentenceKeep: Double {
        switch self {
        case .off: 0
        case .tight: 0.2
        case .standard: 0.3
        case .relaxed: 0.5
        }
    }
    /// 章节/段落之间（说话人自己的长停顿）保留的静音（秒）
    var chapterKeep: Double {
        switch self {
        case .off: 0
        case .tight: 0.5
        case .standard: 0.8
        case .relaxed: 1.2
        }
    }
    var summary: String {
        switch self {
        case .off: "气口全部剪掉，句子直接相接（原始行为）"
        case .tight: "每句后留 0.2 秒，章节处留 0.5 秒"
        case .standard: "每句后留 0.3 秒，章节处留 0.8 秒"
        case .relaxed: "每句后留 0.5 秒，章节处留 1.2 秒"
        }
    }
}

/// 片头 / 片尾没有台词的那一段怎么处理。
///
/// 没有台词不代表没有画面，所以默认剪掉一小段留白，同时保留一个可以随时切回的开关：
/// 有些片子开头就是刻意的空镜或 B-roll，那就不该动它。
enum EdgeTrimPlan: String, Codable, CaseIterable, Sendable {
    case keep
    case trim

    var label: String {
        switch self {
        case .keep: "保留"
        case .trim: "剪掉"
        }
    }

    var isTrimming: Bool { self == .trim }

    var summary: String {
        switch self {
        case .keep: "片头片尾原样保留，不做任何裁剪"
        case .trim: "剪掉片头片尾没有台词的部分，只留一点点前导/收尾"
        }
    }
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
    /// 这一镜如果已经选定实在的 B-roll 素材，把素材和用它哪一段记下来。
    var brollPath: String? = nil
    var brollStart: Double? = nil
    var brollEnd: Double? = nil
}

/// 排到时间线上的 B-roll 片段：哪条素材、放哪条轨道、成片时间的入点／出点、用素材的哪一段。
///
/// 硬规则只有一条：`start` 就是这句台词开始的时间（片段的入点对上台词的入点）。
/// 长度不强行盖住台词：从素材入点一直播到素材结束，于是相邻两条经常叠住；
/// 同一时刻放不下两条片段时才多开一条轨道，轨道越少越好。
struct BrollPlacement: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// 分镜稿里的行号（0 基）：这一条是为哪一行排的。
    var row: Int
    var path: String
    var name: String
    /// 轨道序号，从 1 开始。
    var track: Int
    /// 成片时间（和字幕、分镜时间轴同一套时间）。
    var start: Double
    var end: Double
    /// 素材内部的入点／出点。
    var sourceIn: Double
    var sourceOut: Double
    /// 为什么排这一条：模型给的一句话，或者兜底说明。
    var reason: String = ""

    var duration: Double { max(0, end - start) }
    var sourceDuration: Double { max(0, sourceOut - sourceIn) }
}

// MARK: - B-roll 素材与本地 AI 分析

/// B-roll 素材里画面的运动方向（屏幕坐标：以观众看到的方向为准）。
enum BrollMotion: String, Codable, CaseIterable, Sendable {
    case staticShot = "固定镜头"
    case panRight = "向右移动"
    case panLeft = "向左移动"
    case tiltDown = "向下移动"
    case tiltUp = "向上移动"
    case diagonal = "斜向移动"
    case mixed = "往复移动"

    var symbol: String {
        switch self {
        case .staticShot: "pause.circle"
        case .panRight: "arrow.right.circle"
        case .panLeft: "arrow.left.circle"
        case .tiltDown: "arrow.down.circle"
        case .tiltUp: "arrow.up.circle"
        case .diagonal: "arrow.up.right.circle"
        case .mixed: "arrow.triangle.2.circlepath.circle"
        }
    }

    var isMoving: Bool { self != .staticShot }
}

/// 变焦方向：和横移/纵移是两件事，所以单独做一维。
enum BrollZoom: String, Codable, CaseIterable, Sendable {
    case none = "无变焦"
    case pushIn = "推近"
    case pullOut = "拉远"

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .pushIn: "plus.magnifyingglass"
        case .pullOut: "minus.magnifyingglass"
        }
    }
}

/// 运动幅度：用来判断这条素材能不能撑住一个较长的镜头。
enum BrollMotionEnergy: String, Codable, CaseIterable, Sendable {
    case steady = "稳定"
    case gentle = "轻缓"
    case strong = "明显"

    var symbol: String {
        switch self {
        case .steady: "waveform.path"
        case .gentle: "waveform.path.ecg"
        case .strong: "waveform.path.ecg.rectangle"
        }
    }
}

/// 一条画面内容标签。identifier 是 Vision 给出的原始分类标识，label 是中文显示名。
struct BrollTag: Identifiable, Codable, Equatable, Sendable {
    var identifier: String
    var label: String
    var confidence: Double
    var id: String { identifier }
}

// MARK: - 运动曲线

/// 运动曲线上的一个采样点。
///
/// x / y 是从起点累计的位移，单位是**画面宽 / 高的百分比**（和 BrollAnalysis 里的位移同一套单位），
/// 所以 4K 和 1080p 的曲线可以直接比。x 向右为正、y 向下为正，以观众看到的方向为准。
struct BrollMotionSample: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    /// 到上一个采样点之间的瞬时速度（画面宽/高百分比 / 秒）。
    var speed: Double
    /// 瞬时方向，单位度：0 = 向右，90 = 向下（负值是向上 / 向左）。
    var direction: Double
    /// 径向发散度：大于 0 表示画面在往外扩（推近）。
    var divergence: Double = 0

    var magnitude: Double { (x * x + y * y).squareRoot() }
}

/// 这条素材这一段是怎么动的。剪辑时真正能用的是区间，不是一个全片平均值。
enum BrollMotionPhaseKind: String, Codable, CaseIterable, Sendable {
    case hold = "静止"
    case steady = "匀速移动"
    case accelerating = "加速"
    case decelerating = "减速"
    case unsettled = "来回晃动"

    var symbol: String {
        switch self {
        case .hold: "pause.circle"
        case .steady: "arrow.right.circle"
        case .accelerating: "speedometer"
        case .decelerating: "slowmo"
        case .unsettled: "arrow.left.arrow.right.circle"
        }
    }
}

/// 一段运动阶段：从几秒到几秒是“静止 / 匀速移动 / 加速 / 减速 / 来回晃动”。
struct BrollMotionPhase: Identifiable, Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var kind: BrollMotionPhaseKind

    var id: String { "\(kind.rawValue)@\(start)" }
    var duration: Double { max(0, end - start) }
}

/// 一条素材的完整运动曲线：逐点轨迹 + 速度 + 阶段划分。
///
/// 文字描述（“向右移动”）只说了一个方向，这里给的是整条片子怎么动的：
/// 轨迹、速度曲线、以及在哪些时间段里是静止、匀速、在加速、还是手持晃动。
struct BrollMotionCurve: Codable, Equatable, Sendable {
    var samples: [BrollMotionSample] = []
    var phases: [BrollMotionPhase] = []
    var duration: Double = 0
    var analyzedAt = Date()
    var engine = "Apple Vision 光流"

    var isUsable: Bool { samples.count >= 3 }
    /// 首尾之间的净位移（画面宽/高的百分比）。
    var netShift: Double { samples.last?.magnitude ?? 0 }
    /// 采样覆盖到的那几段时间（用来算平均速度，不被片头片尾稀释）。
    var sampledDuration: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.time - first.time)
    }
    var peakSpeed: Double { samples.map(\.speed).max() ?? 0 }
    var averageSpeed: Double {
        guard sampledDuration > 0 else { return 0 }
        return netShift / sampledDuration
    }
    /// 画面活跃度：逐点位移的累加，用来区分“真的固定”和“晃来晃去”。
    var activity: Double {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            let dx = pair.1.x - pair.0.x, dy = pair.1.y - pair.0.y
            return total + (dx * dx + dy * dy).squareRoot()
        }
    }
    var maxDivergence: Double { samples.map(\.divergence).max() ?? 0 }
    var minDivergence: Double { samples.map(\.divergence).min() ?? 0 }

    /// 把速度序列切成阶段。滑动窗口判类型，相邻同类合并成一段。纯函数，方便单测。
    static func phases(from samples: [BrollMotionSample], window: Double = 0.6) -> [BrollMotionPhase] {
        guard samples.count >= 3 else { return [] }
        // 先按滑动窗口判类型。
        var marks: [(start: Double, end: Double, count: Int, kind: BrollMotionPhaseKind)] = []
        var index = 0
        // 浮点边界要放一点余量：0.2×3 在浮点里是 0.6000000000000001，
        // 不放余量会把本该 4 个点的窗口切成 3 个点。
        let limit = window + 1e-9
        while index < samples.count {
            let windowStart = samples[index].time
            var end = index
            while end + 1 < samples.count, samples[end + 1].time - windowStart <= limit { end += 1 }
            marks.append((windowStart, samples[end].time, end - index + 1, classify(Array(samples[index...end]))))
            index = end + 1
        }
        // 尾巴上不足 3 个点的窗口判不出趋势，并回上一段，
        // 否则末尾会多出一小截假的“匀速移动”。
        if marks.count >= 2, (marks.last?.count ?? 0) < 3 { marks.removeLast() }

        // 再把窗口合成连续区间：每一段一直画到下一段的开头，时间轴上不能留缝。
        // 剪辑和阶段条靠的就是这个区间。
        var phases: [BrollMotionPhase] = []
        for (offset, mark) in marks.enumerated() {
            let end = offset + 1 < marks.count ? marks[offset + 1].start : samples[samples.count - 1].time
            if let last = phases.last, last.kind == mark.kind {
                phases[phases.count - 1].end = end
            } else {
                phases.append(BrollMotionPhase(start: mark.start, end: end, kind: mark.kind))
            }
        }
        return phases
    }

    /// 判定一个窗口属于哪种运动。阈值和 BrollAnalyzer 标定过的那套保持一致。
    private static func classify(_ window: [BrollMotionSample]) -> BrollMotionPhaseKind {
        guard window.count >= 2, let first = window.first, let last = window.last else { return .hold }
        let speeds = window.map(\.speed)
        let average = speeds.reduce(0, +) / Double(speeds.count)
        if average < BrollAnalyzer.steadyPerSecond { return .hold }

        // 走过不少路、但没走出去：多半是在来回动 / 手持晃。
        var activity = 0.0
        for (previous, next) in zip(window, window.dropFirst()) {
            let dx = next.x - previous.x, dy = next.y - previous.y
            activity += (dx * dx + dy * dy).squareRoot()
        }
        let net = ((last.x - first.x) * (last.x - first.x) + (last.y - first.y) * (last.y - first.y)).squareRoot()
        if activity > 0.2, net < activity * 0.5 { return .unsettled }

        // 速度趋势：首尾各取三分之一的中位数，避免单个采样点带偏结论。
        let third = max(1, speeds.count / 3)
        let head = median(Array(speeds.prefix(third)))
        let tail = median(Array(speeds.suffix(third)))
        if head > 0.05, tail > head * 1.35 { return .accelerating }
        if head > 0.05, tail < head * 0.7 { return .decelerating }
        return .steady
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: 可用片段

/// 一段“能剪进去”的镜头是怎么动的。
///
/// 这三类是剪辑时真正会区别对待的：固定镜头取稳定那一段；移动镜头每完成一个
/// 单向过程算一段（滑轨过去再回来是两段）；小幅漂移（轻微摇、手持微晃）照样能用，
/// 只是要标出来它是哪一种。
enum BrollSegmentKind: String, Codable, CaseIterable, Sendable {
    case lockedOff = "固定镜头"
    case oneWay = "单向移动"
    case drift = "小幅漂移"

    var symbol: String {
        switch self {
        case .lockedOff: "pause.circle"
        case .oneWay: "arrow.right.circle"
        case .drift: "wind"
        }
    }

    var detail: String {
        switch self {
        case .lockedOff: "画面基本不动的一段：前后调整机位的那两下在段外，不算进来"
        case .oneWay: "画面朝一个方向走完的一趟；过去再回来是两段，不是一段"
        case .drift: "走了但没走出去：轻微的上下摇、手持漂移，当稳定空镜用"
        }
    }
}

/// 一条 B-roll 里真正能剪进去的一段。
///
/// 它只说“素材的哪一段能用”，不说“用在哪里” —— 接到哪一句台词上是分镜表的事。
struct BrollUsableSegment: Identifiable, Codable, Equatable, Sendable {
    /// 片段的身份：由识别切出来的那一刻决定，手动调出入点不会改它。
    /// 改了就对不上存下来的手动调整了，所以 id 和当前的 start/end 是两回事。
    var id: String
    /// 在源素材里的起止时间，单位秒。
    var start: Double
    var end: Double
    var kind: BrollSegmentKind
    /// 这一段画面往哪走。固定镜头和原地漂移是 `.staticShot`。
    var motion: BrollMotion
    /// 段内平均速度，单位是画面宽/秒 —— 越小越稳。
    var averageSpeed: Double
    /// 段内累计走了多远（画面宽/高的百分比）。来回晃动时它远大于净位移。
    var travelled: Double
    /// 段内净位移（画面宽/高的百分比）：起点到终点实际挪开了多少。
    var netShift: Double
    /// 这一段是推近、拉远还是无变焦。它和横移/纵移是两回事，所以单独记一维。
    var zoom: BrollZoom = .none
    /// 切开这一段的焦点切换时刻：段的首尾挨着它的那一个。两个半段上都会记着。
    var focusSwitchTime: Double? = nil
    /// 段里还有一处焦点切换，但离端点太近，切开了两边都不够长。
    var hasInnerFocusSwitch: Bool = false
    /// 用户手动调过出入点。
    var isAdjusted: Bool = false
    /// 用户打勾认可“这段可以用”。
    var approved: Bool = false

    var duration: Double { max(0, end - start) }
    var timecodeRange: String { "\(BrollProductPick.timecode(start))–\(BrollProductPick.timecode(end))" }
}

/// 用户对某一段的改动：调过的出入点，以及“这段我认可”。
/// 键是识别切出来的片段 id —— 重新识别会把改动丢掉，这是有意的：段都重新切了，
/// 旧的手动调整已经对不上原来那一段。
struct BrollSegmentEdit: Codable, Equatable, Sendable {
    /// 手动入点 / 出点，单位秒。nil = 用识别切出来的位置。
    var start: Double? = nil
    var end: Double? = nil
    var approved = false

    var isEmpty: Bool { start == nil && end == nil && !approved }
}

extension BrollMotionCurve {
    /// 一段可用片段的最短时长。短于它的只当运镜的起手/收尾，不当镜头。
    static let minimumSegmentDuration = 1.0
    /// 净位移小于它就不说“往某个方向移动”，改叫小幅漂移（画面宽/高的百分比）。
    /// 比 `staticShift`（1.5）松一点：低于静止线是固定镜头，刚过线但没走远是漂移。
    private static let driftShift = 3.0
    /// 方向转过这么多度就算一个转折：一趟来回要切成两段。
    private static let turnAngle = 120.0 * Double.pi / 180
    /// 判转折时的位移下限（画面宽/高的百分比）。低于它的方向是噪声，不作数。
    private static let turnEpsilon = 0.05
    /// 贴着片头/片尾、短于它的移动，在固定镜头里当“挪机器”，不当镜头。
    private static let repositioningDuration = 2.0

    /// 从运动曲线里切出可用片段。纯函数，不碰视频也不碰模型，方便钉住判定规则。
    ///
    /// 判定顺序：先把每个采样步分成“静止 / 移动”，再去掉孤立噪声，然后按连续同类
    /// 合成段；移动段还要按方向转折再切一刀，一趟来回才是两段；最后按焦点切换点切开。
    /// 每一步都要求凑够 `minDuration`，所以起手、转折、收尾这些过渡自然被排除在外。
    static func usableSegments(
        from samples: [BrollMotionSample],
        focusSwitchTimes: [Double] = [],
        minDuration: Double = minimumSegmentDuration
    ) -> [BrollUsableSegment] {
        guard samples.count >= 4 else { return [] }

        // 每一步的位移向量。「稳不稳」看的是画面真的走了多少，所以从轨迹的
        // 相邻两点算，而不是用现成的标量速度字段 —— 那个字段是同一套光流算的，
        // 但轨迹才是切段的依据。
        struct Step {
            var from: Int
            var dx: Double
            var dy: Double
            var divergence: Double
            var moved: Bool
        }
        var steps: [Step] = []
        for index in 1..<samples.count {
            let seconds = samples[index].time - samples[index - 1].time
            guard seconds > 0.001 else { continue }
            let dx = samples[index].x - samples[index - 1].x
            let dy = samples[index].y - samples[index - 1].y
            let speed = (dx * dx + dy * dy).squareRoot() / seconds
            steps.append(Step(
                from: index - 1,
                dx: dx,
                dy: dy,
                divergence: samples[index].divergence,
                moved: speed >= BrollAnalyzer.steadyPerSecond
            ))
        }
        guard steps.count >= 3 else { return [] }

        // 孤立的一步多半是光流噪声：左右两边一致、中间不一样，就并回两边。
        var moved = steps.map(\.moved)
        for _ in 0..<2 {
            guard moved.count >= 3 else { break }
            for index in 1..<(moved.count - 1)
            where moved[index] != moved[index - 1] && moved[index - 1] == moved[index + 1] {
                moved[index] = moved[index - 1]
            }
        }

        // 连续同类的步先合成一段。
        var runs: [(range: ClosedRange<Int>, moved: Bool)] = []
        var runStart = 0
        for index in 1..<steps.count where moved[index] != moved[runStart] {
            runs.append((runStart...(index - 1), moved[runStart]))
            runStart = index
        }
        runs.append((runStart...(steps.count - 1), moved[runStart]))

        // 移动段再按方向切开：滑轨过去、再回来，是两段可用片段。
        // 用「这一段的净位移方向」和「这一步的方向」比，而不是比左右/上下轴 ——
        // 环绕、弧线运镜的方向在画面里是连续旋转的，比轴会误判成来回。
        var pieces: [(range: ClosedRange<Int>, moved: Bool, cut: Double?, inner: Bool)] = []
        for run in runs {
            guard run.moved else {
                pieces.append((run.range, false, nil, false))
                continue
            }
            var netX = 0.0, netY = 0.0
            var pieceStart = run.range.lowerBound
            for index in run.range {
                let step = steps[index]
                let net = (netX * netX + netY * netY).squareRoot()
                let distance = (step.dx * step.dx + step.dy * step.dy).squareRoot()
                if net > turnEpsilon, distance > 0.001,
                   (netX * step.dx + netY * step.dy) / (net * distance) < cos(turnAngle) {
                    pieces.append((pieceStart...(index - 1), true, nil, false))
                    pieceStart = index
                    netX = 0; netY = 0
                }
                netX += step.dx; netY += step.dy
            }
            pieces.append((pieceStart...run.range.upperBound, true, nil, false))
        }

        // 焦点切换：段里换了焦点，就从切换点切开 —— 前后不是同一个镜头。
        // 焦点数据来自物品识别（3 或 5 帧），粒度粗，所以只当一个粗略的切点。
        var split: [(range: ClosedRange<Int>, moved: Bool, cut: Double?, inner: Bool)] = []
        for piece in pieces {
            let start = samples[steps[piece.range.lowerBound].from].time
            let end = samples[steps[piece.range.upperBound].from + 1].time
            guard end - start >= minDuration else { continue }
            let cuts = focusSwitchTimes
                .filter { $0 - start >= minDuration && end - $0 >= minDuration }
                .sorted()
            guard !cuts.isEmpty else {
                let inner = focusSwitchTimes.contains { $0 > start && $0 < end }
                split.append((piece.range, piece.moved, nil, inner))
                continue
            }
            // 切开的位置落在哪一步上：结束时间第一次越过切点的那一步。
            var partStart = piece.range.lowerBound
            var pending: Double? = nil
            for cut in cuts {
                guard let index = (partStart...piece.range.upperBound).first(where: { samples[steps[$0].from + 1].time >= cut }),
                      index > partStart else { continue }
                split.append((partStart...(index - 1), piece.moved, cut, false))
                partStart = index
                pending = cut
            }
            split.append((partStart...piece.range.upperBound, piece.moved, pending, false))
        }
        // 最后一段一段地算净位移、平均速度，并定它属于哪一类镜头。
        var segments: [BrollUsableSegment] = []
        for part in split {
            let first = steps[part.range.lowerBound]
            let last = steps[part.range.upperBound]
            let start = samples[first.from].time
            let end = samples[last.from + 1].time
            guard end - start >= minDuration else { continue }

            var netX = 0.0, netY = 0.0, travelled = 0.0, divergence = 0.0
            for index in part.range {
                let step = steps[index]
                netX += step.dx; netY += step.dy
                travelled += (step.dx * step.dx + step.dy * step.dy).squareRoot()
                divergence += step.divergence
            }
            let netShift = (netX * netX + netY * netY).squareRoot()
            let zoom = BrollAnalyzer.zoomDirection(divergence: divergence)
            let kind: BrollSegmentKind
            if !part.moved {
                kind = .lockedOff
            } else if netShift < driftShift, zoom == .none {
                // 走了但没走出去，也没在变焦：轻微的摇、手持漂移。
                kind = .drift
            } else {
                kind = .oneWay
            }
            let motion = kind == .lockedOff
                ? BrollMotion.staticShot
                : BrollAnalyzer.motionDirection(horizontal: netX, vertical: netY)
            segments.append(BrollUsableSegment(
                id: Self.segmentID(kind: kind, start: start, end: end),
                start: start,
                end: end,
                kind: kind,
                motion: motion,
                averageSpeed: travelled / max(0.05, end - start),
                travelled: travelled,
                netShift: netShift,
                zoom: zoom,
                focusSwitchTime: part.cut,
                hasInnerFocusSwitch: part.inner
            ))
        }
        segments.sort { $0.start < $1.start }

        // 固定镜头前后挪机器的那两下不是内容，是调整。
        // 判据要同时满足才丢：贴着片头或片尾、这条素材本身有稳定段、短于 2 秒、而且
        // 不是变焦。光有“贴着边”不够 —— 一条从头摇到尾的素材，两头的运动就是内容；
        // 结尾那一下推近也是真镜头，不能一起丢掉。
        if segments.contains(where: { $0.kind == .lockedOff }) {
            let clipStart = samples.first?.time ?? 0
            let clipEnd = samples.last?.time ?? 0
            segments.removeAll { segment in
                guard segment.kind != .lockedOff, segment.duration < repositioningDuration, segment.zoom == .none else { return false }
                return abs(segment.start - clipStart) < 0.001 || abs(segment.end - clipEnd) < 0.001
            }
        }
        return segments
    }

    /// 片段的身份：类型 + 识别切出来的起止时间。
    static func segmentID(kind: BrollSegmentKind, start: Double, end: Double) -> String {
        String(format: "%@@%.3f-%.3f", kind.rawValue, start, end)
    }
}

/// 本地 AI 对一条 B-roll 素材的分析结果。
struct BrollAnalysis: Codable, Equatable, Sendable {
    /// 画面内容标签，按置信度从高到低。
    var tags: [BrollTag] = []
    /// 画面主导运动方向。
    var motion: BrollMotion = .staticShot
    /// 变焦方向。
    var zoom: BrollZoom = .none
    /// 运动幅度。
    var energy: BrollMotionEnergy = .steady
    /// 首尾两帧之间的累计位移，单位是画面宽/高的百分比；x 向右为正，y 向下为正。
    var horizontalShift: Double = 0
    var verticalShift: Double = 0
    /// 累计径向发散度：大于 0 表示画面向外扩（推近），小于 0 表示向内收（拉远）。
    var divergence: Double = 0
    /// 整条素材的画面活跃度：逐段位移的累加，用来区分“真的固定”和“晃来晃去”。
    var activity: Double = 0
    /// 位移速度：每秒移动画面宽/高的百分之几，用来判断“慢慢漂”还是“明显运动”。
    var shiftPerSecond: Double = 0
    /// 本地视觉大模型给出的“这条素材有没有拍到产品、哪一段最适合展示产品”。
    /// 没跑过产品识别时是 nil，所以老项目里的识别结果依然能读。
    var product: BrollProductPick? = nil
    var analyzedAt = Date()
    var engine = "Apple Vision"

    /// 这条素材里认出来的物品清单：有什么、谁是主角、焦点在哪几帧换了人。
    /// 由产品识别的逐帧结果现算，不单独存盘 —— 帧结论改了，清单就跟着改。
    var inventory: BrollInventory { BrollInventory.build(frames: product?.frames ?? []) }
    /// 密集采样的运动曲线：轨迹、速度、阶段划分。老项目没有这个字段。
    var motionCurve: BrollMotionCurve? = nil
}

/// 媒体库里的 B-roll 素材。属于项目级数据，随项目一起落盘。
struct BrollAsset: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var name: String
    var duration: Double
    var width: Int
    var height: Int
    var analysis: BrollAnalysis?
    /// 手动归进去的文件夹（产品清单里的产品 ID，或者手动文件夹的 ID）。
    var manualFolders: [UUID]? = nil
    /// 手动从某个文件夹里剔除：识别错了、或者用户不想让它待在那儿。
    var excludedFolders: [UUID]? = nil
    /// 手动调过的可用片段出入点、以及打勾认可的段。键是片段 id。
    /// 只存“改过什么”，切段本身还是每次从运动曲线现算 —— 改了运动曲线，段跟着变。
    var segmentEdits: [String: BrollSegmentEdit]? = nil

    var resolutionLabel: String { width > 0 && height > 0 ? "\(width)×\(height)" : "—" }
    var manualFolderIDs: [UUID] { manualFolders ?? [] }
    var excludedFolderIDs: [UUID] { excludedFolders ?? [] }
    /// 画面内容（标签、运动）识别跑过没有。
    /// 只跑过产品识别时会给这条素材补一个只放物品结论的壳，那种情况不算“已识别内容” ——
    /// 否则卡片会拿着默认值说这条是“固定镜头”，运动筛选也会跟着错。
    var isAnalyzed: Bool { !(analysis?.tags.isEmpty ?? true) }
    /// 产品识别的结论。没有就是没跑过。
    var productPick: BrollProductPick? { analysis?.product }
    /// 这条素材认出来的物品清单：有什么、谁是主角、焦点在哪几帧换了人。
    /// 没跑过产品识别、或者一帧都没认出东西时是 nil。
    var inventory: BrollInventory? {
        guard let inventory = analysis?.inventory, !inventory.items.isEmpty else { return nil }
        return inventory
    }
    var hasProduct: Bool { productPick?.containsProduct ?? false }
    /// 用来排序的分数：没跑过产品识别时退回运动稳定性，保证列表始终有顺序。
    var pickScore: Int { productPick?.score ?? 0 }

    /// 这条素材里某个产品最清楚的一刻：先找它是主角的那一帧，没有就退回它最清楚的一帧。
    func bestMoment(of productID: UUID) -> Double? {
        guard let items = inventory?.items.filter({ $0.productID == productID }), !items.isEmpty else { return nil }
        return (items.first { $0.focusCount > 0 } ?? items[0]).sharpestTime
    }

    /// 给本地粗筛用的一整段可搜索文本：画面标签、画面结论、认出来的物品、运动方向。
    var matchHaystack: String {
        var parts: [String] = []
        if let analysis {
            parts.append(analysis.tags.map(\.label).joined(separator: "、"))
            parts.append(analysis.motion.rawValue)
        }
        if let summary = productPick?.summary, !summary.isEmpty { parts.append(summary) }
        if let items = inventory?.items, !items.isEmpty { parts.append(items.map(\.label).joined(separator: "、")) }
        return parts.joined(separator: "｜").lowercased()
    }

    /// 给本机模型看的一句话：文件名、时长、画面标签、画面结论、认出来的物品。
    /// 模型只在这一句话里挑，看不到别的，也就不会编出库里没有的素材。
    var matchLine: String {
        var parts: [String] = ["\(name)｜\(String(format: "%.1f", duration))s"]
        if let analysis, !analysis.tags.isEmpty { parts.append(analysis.tags.prefix(6).map(\.label).joined(separator: "、")) }
        if let summary = productPick?.summary, !summary.isEmpty { parts.append(summary) }
        if let items = inventory?.items, !items.isEmpty { parts.append(items.prefix(3).map(\.label).joined(separator: "、")) }
        return parts.joined(separator: "｜")
    }

    /// 这条素材里能直接剪进去的段。
    ///
    /// 只依赖运动曲线，**不需要产品识别**：环境空镜、花絮、产品清单里没有的东西
    /// 也能切出可用片段。跑过物品识别时会把焦点切换点也算进去，段内换焦点就切开。
    var usableSegments: [BrollUsableSegment] {
        guard let curve = analysis?.motionCurve, curve.isUsable else { return [] }
        let detected = BrollMotionCurve.usableSegments(
            from: curve.samples,
            focusSwitchTimes: analysis?.inventory.focusSwitchTimes ?? []
        )
        guard let edits = segmentEdits, !edits.isEmpty else { return detected }
        return detected.map { segment in
            guard let edit = edits[segment.id] else { return segment }
            var segment = segment
            // 手动出入点不能越过素材边界，也不能把一段剪到没有 —— 至少留 0.2 秒。
            if let start = edit.start { segment.start = min(max(0, start), segment.end - 0.2) }
            if let end = edit.end { segment.end = max(min(duration, end), segment.start + 0.2) }
            segment.isAdjusted = edit.start != nil || edit.end != nil
            segment.approved = edit.approved
            return segment
        }
    }
}

/// 一个产品分组：实拍里**真的认出来**的某一款产品。
///
/// brief 里给了、但素材里压根没有的颜色不会建分组 —— 分组是实拍的结果，不是 brief 的目录。
/// 一条素材里出现了两个产品，它就会同时出现在两个分组里。
struct BrollGroup: Identifiable, Equatable {
    /// 产品清单里那一条的 ID。
    var id: UUID
    var label: String
    var sku: String = ""
    var assets: [BrollAsset] = []
    /// 手动建的文件夹（不在产品清单里，比如"对比产品"、"花絮"）。
    var isManual: Bool = false

    var count: Int { assets.count }
}

/// 用户手动建的文件夹。
///
/// 模型认不出来的东西照样要能归类：局部特写、不在 brief 里的对比产品、花絮……
/// 这类"我知道它是什么，只是你没认出来"的素材，靠手动拖进文件夹解决。
struct BrollFolder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

// MARK: - 产品档案与产品镜头挑选

/// 一帧画面上“产品出现得怎么样”。
enum BrollProductPresence: String, Codable, CaseIterable, Sendable {
    case mainSubject = "产品主体"
    case visible = "含产品"
    case hinted = "疑似产品"
    case none = "未见产品"

    var symbol: String {
        switch self {
        case .mainSubject: "scope"
        case .visible: "checkmark.circle"
        case .hinted: "questionmark.circle"
        case .none: "xmark.circle"
        }
    }

    /// 排序用：主体 > 可见 > 疑似 > 无。
    var rank: Int {
        switch self {
        case .mainSubject: 3
        case .visible: 2
        case .hinted: 1
        case .none: 0
        }
    }

    /// 把模型输出的编码（0-3）翻译成档位，越界一律按“未见产品”。
    static func from(code: Int) -> BrollProductPresence {
        switch code {
        case 3: .mainSubject
        case 2: .visible
        case 1: .hinted
        default: .none
        }
    }
}

/// 本地视觉大模型对某一个采样时刻的判断。
struct BrollFrameVerdict: Identifiable, Codable, Equatable, Sendable {
    var index: Int
    /// 在**源素材**里的时间，单位秒。
    var time: Double
    var presence: BrollProductPresence
    /// 产品的置信度 0-100。
    var confidence: Int
    /// 画面清晰度（有没有糊掉/拖影）0-100。
    var sharpness: Int
    var note: String = ""
    /// 这一帧里认出来的东西。老项目里的帧结论没有这个字段，所以默认空数组。
    /// 物品清单是“这条素材里有什么”的原料，presence/confidence 只说目标产品在不在。
    var objects: [BrollObject] = []

    var id: Int { index }
}

extension BrollFrameVerdict {
    /// 容错解码：老项目里的帧结论没有 objects（那时候还没认物品），
    /// 加字段时给默认值不够 —— Codable 的合成解码不会用默认值，缺 key 就直接抛错。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        time = try container.decode(Double.self, forKey: .time)
        presence = try container.decode(BrollProductPresence.self, forKey: .presence)
        confidence = try container.decode(Int.self, forKey: .confidence)
        sharpness = try container.decode(Int.self, forKey: .sharpness)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        objects = try container.decodeIfPresent([BrollObject].self, forKey: .objects) ?? []
    }
}

// MARK: - 画面里的物品

/// 画面里一件东西扮演的角色。
///
/// 判断“谁是主角”不看模型怎么措辞，看的是哪一个在对焦上：
/// 每个物品自己带一个清晰度，最清楚的那件就是这一帧的焦点所在。
enum BrollObjectRole: String, Codable, CaseIterable, Sendable {
    /// 这一帧最该被看到的主角物品。
    case subject = "主体"
    /// 陪衬：真的在画面里，但不是主角。
    case supporting = "陪衬"
    /// 看得出是产品，但不属于这次的产品清单 —— 很可能是竞品，要问过你才算。
    case otherProduct = "别的产品"
    /// 背景装饰。
    case background = "背景"
    /// 相机、手机、灯这类正在拍摄的设备。
    case gear = "拍摄设备"
    /// 看不出是什么的东西：不在 brief 里，也不像背景，可能就是竞品。
    case unknown = "不认识的物品"

    var symbol: String {
        switch self {
        case .subject: "scope"
        case .supporting: "circle.dashed"
        case .otherProduct: "shippingbox"
        case .background: "photo"
        case .gear: "camera"
        case .unknown: "questionmark.circle"
        }
    }

    /// 排序用：越像“产品”、越需要人看一眼的越靠前。
    /// “别的产品”排在“陪衬”前面：一件东西只要被看成别家的产品一次，就不该被后面的陪衬把话盖过去。
    var rank: Int {
        switch self {
        case .subject: 5
        case .otherProduct: 4
        case .supporting: 3
        case .unknown: 2
        case .background: 1
        case .gear: 0
        }
    }

    /// 需要你确认一下的角色：不认识的东西，和长得像别家产品的东西。
    var needsConfirmation: Bool { self == .unknown || self == .otherProduct }

    /// 模型输出的编码翻译成角色，认不出来的一律当“不认识的物品”。
    ///
    /// 提示词要求写英文码，但这是个中文提示词下的模型，偶尔会直接用中文回答
    /// （“主体”“背景道具”）。这种漂移不能当成“不认识的物品” —— 那会让整条素材
    /// 全是待确认的噪音，所以中英文都认。
    static func from(code: String) -> BrollObjectRole {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "subject", "main", "hero", "主角", "主体", "主要物品": .subject
        case "supporting", "support", "prop", "陪衬", "道具", "配角", "次要物品": .supporting
        case "other_product", "other product", "competitor", "rival", "other_brand",
             "别的产品", "其他产品", "其它产品", "竞品", "别家的产品": .otherProduct
        case "background", "bg", "背景", "背景装饰", "背景道具": .background
        case "gear", "camera", "equipment", "device", "拍摄设备", "相机", "摄影设备", "器材": .gear
        case "unknown", "unclear", "不认识", "不认识的物品", "未知物品", "看不出是什么": .unknown
        default: .unknown
        }
    }
}

/// 物品在画面里的粗略位置：左中右 × 上中下。
/// 够用来做“焦点落在左边还是右边”的判断，不需要像素级坐标。
enum BrollSpot: String, Codable, CaseIterable, Sendable {
    case topLeft = "左上"
    case top = "上"
    case topRight = "右上"
    case left = "左"
    case center = "中"
    case right = "右"
    case bottomLeft = "左下"
    case bottom = "下"
    case bottomRight = "右下"

    static func from(code: String) -> BrollSpot? {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        // 和角色一样：英文码为主，中文回答也认。
        case "top_left", "upper_left", "左上", "左上角": .topLeft
        case "top", "upper", "top_center", "upper_center", "上", "上方", "中上", "正上方": .top
        case "top_right", "upper_right", "右上", "右上角": .topRight
        case "left", "左", "左侧", "左边": .left
        case "center", "centre", "middle", "中", "中间", "中央", "画面中间", "画面中央": .center
        case "right", "右", "右侧", "右边": .right
        case "bottom_left", "lower_left", "左下", "左下角": .bottomLeft
        case "bottom", "lower", "bottom_center", "lower_center", "下", "下方", "中下", "正下方": .bottom
        case "bottom_right", "lower_right", "右下", "右下角": .bottomRight
        default: nil
        }
    }
}

/// 某一个采样帧里认出来的一件东西。
struct BrollObject: Identifiable, Codable, Equatable, Sendable {
    /// 这一帧里的第几件（从 1 开始）。同一件东西在不同帧里的编号可能不一样，合并靠身份。
    var slot: Int
    /// 显示名：认出产品时是“产品名 · 颜色”，认不出来时是模型给的名字。
    var label: String
    /// 匹配到产品清单里的哪一条；没匹配上就是 nil。
    var productID: UUID?
    var sku: String = ""
    var color: String = ""
    var role: BrollObjectRole = .unknown
    var spot: BrollSpot? = nil
    /// 这件东西在画面里清不清楚 0-100。对焦在它身上就是高分。
    var sharpness: Int = 0
    var confidence: Int = 0
    var note: String = ""

    var id: Int { slot }
    /// 跨帧合并用的身份：认出产品用产品 ID，没认出来用名字。
    var identityKey: String {
        if let productID { return "p:\(productID.uuidString)" }
        return "n:\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
    var isMatched: Bool { productID != nil }
}

/// 焦点在一帧里落在哪件东西上。
/// 焦点走向就是靠它拼出来的：相邻帧焦点不同，说明这条素材里有焦点切换。
struct BrollFocusPoint: Codable, Equatable, Sendable {
    /// 在源素材里的时间，单位秒。
    var time: Double
    var label: String
    var spot: BrollSpot? = nil
    var sharpness: Int = 0
    var isProduct: Bool = false
}

/// 让预览跳到某一刻的请求。每次的 id 都不一样，同一个时间点连点两次也会重新触发。
struct BrollPreviewRequest: Equatable {
    var id = UUID()
    var assetID: UUID
    var time: Double
    /// 播到这一刻就自动暂停：用来「预览这一段」。nil = 只跳到这一帧，不动播放状态。
    var stopAt: Double? = nil
}

/// 认物品时抽几帧。
///
/// 帧数直接决定一条素材要多久：**每抽一帧就是一次本地模型调用**（实测每次 10–20 秒），
/// 所以这是"要快要全"的主要开关。三帧是默认：首 / 中 / 尾，结论一致就不再问。
enum BrollScanMode: Int, CaseIterable, Sendable {
    case fast = 1
    case standard = 3
    case thorough = 5

    var label: String { "\(rawValue) 帧" }

    var detail: String {
        switch self {
        case .fast: "只问中间一帧，最快；镜头中途才出现产品可能漏"
        case .standard: "首 / 中 / 尾三帧，结论不一致会自动补到五帧"
        case .thorough: "五帧全问，最慢也最稳"
        }
    }
}

/// 跨帧合并之后的一件东西：这条素材里它出现了几次、哪一帧最清楚。
struct BrollInventoryItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var productID: UUID?
    var sku: String = ""
    var color: String = ""
    /// 出现过的采样帧序号与时间点。
    var frameIndexes: [Int] = []
    var times: [Double] = []
    /// 它最清楚的一帧。
    var sharpestTime: Double = 0
    var sharpest: Int = 0
    /// 它是这一帧焦点的次数：次数最多的那件就是这条素材的主角。
    var focusCount: Int = 0
    var confidence: Int = 0
    var role: BrollObjectRole = .unknown
    var note: String = ""

    var identityKey: String {
        if let productID { return "p:\(productID.uuidString)" }
        return "n:\(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
    var isMatched: Bool { productID != nil }
    /// 在素材里出现的时间点，给界面看。
    var timecodes: String { times.map(BrollProductPick.timecode).joined(separator: " · ") }
}

/// 一条素材的“物品清单”：这条片子里认出了哪些东西、谁是主角、焦点在哪几帧换了人。
struct BrollInventory: Codable, Equatable, Sendable {
    var items: [BrollInventoryItem] = []
    /// 每一帧的焦点物品，按时间排好。
    var focusTrack: [BrollFocusPoint] = []
    var analyzedAt = Date()
    var engine = ""

    /// 焦点换了几次人。大于 0 说明这条素材里有焦点切换（rack focus）。
    var focusSwitches: Int {
        var count = 0
        for (left, right) in zip(focusTrack, focusTrack.dropFirst()) where left.label != right.label { count += 1 }
        return count
    }

    /// 焦点换人的时刻：焦点从这一帧的东西换到下一帧的东西，就算在下一帧上。
    /// 粒度是识别时的采样帧（3 或 5 帧），所以这只是个粗略的切点，不是精确到帧的。
    var focusSwitchTimes: [Double] {
        var times: [Double] = []
        for (left, right) in zip(focusTrack, focusTrack.dropFirst()) where left.label != right.label {
            times.append(right.time)
        }
        return times
    }

    /// 这条素材的主角：当焦点次数最多的那件；并列时取更清楚的。
    var subject: BrollInventoryItem? {
        items.filter { $0.focusCount > 0 }.max { left, right in
            (left.focusCount, left.sharpest) < (right.focusCount, right.sharpest)
        }
    }
    /// 在清单里认出来的产品。
    var products: [BrollInventoryItem] { items.filter(\.isMatched) }
    /// 这条素材**确实拍到**的产品：至少有一帧它是主角（焦点在它身上）。
    /// 分组用这个：文件夹回答的是“这条片子在拍它”。
    var appearances: [BrollInventoryItem] { items.filter { $0.isMatched && $0.focusCount > 0 } }
    /// 只是出现在背景/陪衬里的同款：算“疑似”，列出来但不进分组。
    /// 真实素材上见过模型把同一个包同时报成黑色和米白（参考图挂错时尤其明显），
    /// 这类匹配全部只当线索。
    var suspected: [BrollInventoryItem] { items.filter { $0.isMatched && $0.focusCount == 0 } }
    /// 不知道是什么、可能就是竞品的东西。
    var unknowns: [BrollInventoryItem] { items.filter { !$0.isMatched && $0.role == .unknown } }
    /// 看得出是产品、但不在清单里的东西：很可能是竞品，要问过用户才算。
    var otherProducts: [BrollInventoryItem] { items.filter { !$0.isMatched && $0.role == .otherProduct } }
    /// 这一条素材里需要用户确认的东西：不认识的 + 像别家产品的。
    var pending: [BrollInventoryItem] { items.filter { !$0.isMatched && $0.role.needsConfirmation } }
    /// 背景装饰。
    var background: [BrollInventoryItem] { items.filter { !$0.isMatched && $0.role == .background } }
    /// 相机、手机、灯这类拍摄设备。
    var gear: [BrollInventoryItem] { items.filter { !$0.isMatched && $0.role == .gear } }

    /// 一帧里的焦点物品：最清楚的那件。模型没给清晰度时退回它自己标的主体。
    static func focus(of objects: [BrollObject]) -> BrollObject? {
        guard !objects.isEmpty else { return nil }
        let sharpest = objects.max { left, right in
            (left.sharpness, left.confidence, -left.slot) < (right.sharpness, right.confidence, -right.slot)
        }
        if let sharpest, sharpest.sharpness == 0, let marked = objects.first(where: { $0.role == .subject }) { return marked }
        return sharpest
    }

    /// 把逐帧的物品合并成一条素材的物品清单。纯函数，方便单测。
    static func build(frames: [BrollFrameVerdict], engine: String = "") -> BrollInventory {
        var items: [BrollInventoryItem] = []
        var track: [BrollFocusPoint] = []

        for frame in frames.sorted(by: { $0.index < $1.index }) {
            for object in frame.objects {
                let key = object.identityKey
                if let index = items.firstIndex(where: { $0.identityKey == key }) {
                    // 模型偶尔在同一帧里把同一件东西写两遍：出现时间点不能重复计。
                    if items[index].frameIndexes.last != frame.index {
                        items[index].frameIndexes.append(frame.index)
                        items[index].times.append(frame.time)
                    }
                    if object.sharpness > items[index].sharpest {
                        items[index].sharpest = object.sharpness
                        items[index].sharpestTime = frame.time
                        items[index].note = object.note
                    }
                    items[index].confidence = max(items[index].confidence, object.confidence)
                    // 同一件东西在不同帧里的角色可能不一样，取更像“产品”的那个。
                    if object.role.rank > items[index].role.rank { items[index].role = object.role }
                    if items[index].color.isEmpty { items[index].color = object.color }
                } else {
                    var item = BrollInventoryItem(label: object.label)
                    item.productID = object.productID
                    item.sku = object.sku
                    item.color = object.color
                    item.role = object.role
                    item.frameIndexes = [frame.index]
                    item.times = [frame.time]
                    item.sharpest = object.sharpness
                    item.sharpestTime = frame.time
                    item.confidence = object.confidence
                    item.note = object.note
                    items.append(item)
                }
            }
            if let focus = focus(of: frame.objects) {
                if let index = items.firstIndex(where: { $0.identityKey == focus.identityKey }) {
                    items[index].focusCount += 1
                }
                track.append(BrollFocusPoint(
                    time: frame.time,
                    label: focus.label,
                    spot: focus.spot,
                    sharpness: focus.sharpness,
                    isProduct: focus.isMatched
                ))
            }
        }

        // 排序：先主角，再清单里的产品，再待确认的东西，最后背景和设备。
        items.sort { left, right in
            let leftRank = rank(left), rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.times.first != right.times.first { return (left.times.first ?? 0) < (right.times.first ?? 0) }
            return left.sharpest > right.sharpest
        }
        return BrollInventory(items: items, focusTrack: track, engine: engine)
    }

    private static func rank(_ item: BrollInventoryItem) -> Int {
        if item.focusCount > 0 { return 0 }
        if item.isMatched { return 1 }
        // 需要确认的（不认识 / 像别家产品）排在背景和设备前面。
        return item.role.needsConfirmation ? 2 : 3
    }
}

/// 产品镜头挑选结果：从一条 B-roll 里选出的“能展示产品、而且镜头稳”的片段。
struct BrollProductPick: Codable, Equatable, Sendable {
    /// 推荐片段的起止时间，单位秒，针对源素材。
    var start: Double = 0
    var end: Double = 0
    /// 综合得分 0-100。
    var score: Int = 0
    var frames: [BrollFrameVerdict] = []
    /// 为什么选它：给用户看的依据，不是给模型看的。
    var reasons: [String] = []
    /// 模型对这条素材的一句话评价。
    var summary: String = ""
    /// 这次结论覆盖了几个采样帧。只问了三帧就不会写成“每一帧都看过”。
    var sampledCount: Int = 0
    /// 这次识别有没有产品清单。没有清单时只列画面里的物品，不判产品档位。
    var hasTarget: Bool = true
    var analyzedAt = Date()
    var engine = "本地视觉模型"

    var duration: Double { max(0, end - start) }
    var containsProduct: Bool { frames.contains { $0.presence.rank >= BrollProductPresence.visible.rank } }
    /// 最高档位，用来做徽章和筛选。
    var presence: BrollProductPresence { frames.map(\.presence).max(by: { $0.rank < $1.rank }) ?? .none }
    /// 推荐片段可用：够长、且确实拍到了产品。
    var isUsable: Bool { duration >= 0.6 && containsProduct }
    var timecodeRange: String { "\(Self.timecode(start))–\(Self.timecode(end))" }

    static func timecode(_ seconds: Double) -> String {
        let value = max(0, seconds)
        let minutes = Int(value) / 60
        let rest = value - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

extension BrollProductPick {
    /// 容错解码：老项目里的识别结果没有 hasTarget（那时候一定是带着产品清单跑的）。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(Double.self, forKey: .end) ?? 0
        score = try container.decodeIfPresent(Int.self, forKey: .score) ?? 0
        frames = try container.decodeIfPresent([BrollFrameVerdict].self, forKey: .frames) ?? []
        reasons = try container.decodeIfPresent([String].self, forKey: .reasons) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sampledCount = try container.decodeIfPresent(Int.self, forKey: .sampledCount) ?? 0
        hasTarget = try container.decodeIfPresent(Bool.self, forKey: .hasTarget) ?? true
        analyzedAt = try container.decodeIfPresent(Date.self, forKey: .analyzedAt) ?? Date()
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? "本地视觉模型"
    }
}

/// 产品清单里的一条：一款产品的某一个颜色。
///
/// brief 里常常给好几个产品和好几个颜色，但实拍拿到的可能只有其中几个；
/// 所以这里记的是 brief 给到的全部候选，识别到哪几个由素材说了算。
struct ProductCatalogItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// 品牌方的 SKU，brief 里写了就记下来。
    var sku: String = ""
    /// 颜色 / 款式名。
    var color: String = ""
    var features: [String] = []
    /// 这一条自己的参考图：同款不同色必须分开，不然认不出是哪个颜色。
    var referenceImages: [ProductReferenceImage] = []
    /// 送进模型时用的短标签，例如“斜挎包 · 黑色”。
    var shortLabel: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if color.isEmpty { return cleaned }
        if cleaned.contains(color) { return cleaned }
        return cleaned + " · " + color
    }
    var skuLabel: String { sku.isEmpty ? "" : "SKU \(sku)" }
}

/// 由文字算出稳定的 UUID。
///
/// 老项目里没有产品清单，只能拿产品档案本身当唯一一条候选；
/// 用名字算出固定的 ID，才能保证“同一款产品”在不同帧、不同次识别里是同一个身份。
enum StableID {
    static func make(_ text: String) -> UUID {
        let bytes = Array(text.utf8)
        func fnv(_ seed: UInt64, _ input: [UInt8]) -> UInt64 {
            var value = seed
            for byte in input {
                value ^= UInt64(byte)
                value = value &* 0x1_0000_0000_01B3
            }
            return value
        }
        let high = fnv(0x811C_9DC5, bytes)
        let low = fnv(0x0100_0193, bytes.reversed())
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { raw in
            for index in 0..<8 {
                raw[index] = UInt8(truncatingIfNeeded: high >> (56 - index * 8))
                raw[index + 8] = UInt8(truncatingIfNeeded: low >> (56 - index * 8))
            }
        }
        return UUID(uuid: uuid)
    }
}

/// 产品档案：告诉本地模型“要在这堆素材里找什么”。
/// 由品牌 brief 生成，随项目一起保存。
struct ProductProfile: Codable, Equatable, Sendable {
    var name: String = ""
    /// 外观描述，直接进模型提示词。
    var summary: String = ""
    /// 必须能认出来的关键特征。
    var features: [String] = []
    /// 容易认错的干扰项。
    var avoid: [String] = []
    /// 自己补的说明：brief 没写全、或者本地模型读漏了的点，会一起进识别提示词。
    var notes: String = ""
    var briefPath: String? = nil
    /// 左栏看的原文件预览（PDF）：本来就是 PDF 的 brief 就是它自己，
    /// Word / PPT / 图片是本机排版出来的，存在本机缓存里，下次打开项目还在。
    var previewPath: String? = nil
    var referenceImages: [ProductReferenceImage] = []
    /// brief 里给到的产品清单（一款一个颜色一条，带各自的参考图）。
    /// 老项目没有这个字段，退回“档案本身就是唯一一条产品”。
    var catalog: [ProductCatalogItem]? = nil
    /// 用户确认过的竞品名。确认一次之后，每次识别都直接告诉模型这些是竞品。
    var competitors: [String]? = nil
    /// 用户确认过“不是产品”的名字，识别时不用再问一遍。
    var ignoredObjects: [String]? = nil
    /// 用户手动建的文件夹。老项目没有这个字段。
    var folders: [BrollFolder]? = nil
    var builtAt: Date? = nil
    var engine: String = ""

    var isConfigured: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 档案里有没有值得保存的东西。
    /// 比 isConfigured 宽：只确认过竞品、只加过参考图的档案也要跟着项目存下来，
    /// 不然下次打开项目又得重新确认一遍。
    var hasContent: Bool {
        isConfigured
            || briefPath != nil
            || !referenceImages.isEmpty
            || !(catalog ?? []).isEmpty
            || !customFolders.isEmpty
            || !knownCompetitors.isEmpty
            || !knownIgnored.isEmpty
    }

    var knownCompetitors: [String] { competitors ?? [] }
    var knownIgnored: [String] { ignoredObjects ?? [] }
    /// 手动建的文件夹（不在产品清单里，比如"对比产品"、"花絮"）。
    var customFolders: [BrollFolder] { folders ?? [] }

    /// 真正拿去认产品的候选清单。brief 没给出多条（比如手写的档案）时，
    /// 把档案本身当成唯一一条，用稳定 ID 保证每次识别指向同一件东西。
    var products: [ProductCatalogItem] {
        if let catalog, !catalog.isEmpty { return catalog }
        guard isConfigured else { return [] }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [ProductCatalogItem(
            id: StableID.make("profile:\(label.isEmpty ? summary : label)"),
            name: label.isEmpty ? "目标产品" : label,
            features: features,
            referenceImages: referenceImages
        )]
    }

    /// 给模型看的产品说明。参考图会单独作为图片一起送进去。
    var promptBlock: String {
        var lines: [String] = []
        if !name.isEmpty { lines.append("产品名称：\(name)") }
        if !summary.isEmpty { lines.append("外观：\(summary)") }
        if !features.isEmpty { lines.append("关键特征：\(features.joined(separator: "、"))") }
        if !avoid.isEmpty { lines.append("不要误判成：\(avoid.joined(separator: "、"))") }
        if !knownCompetitors.isEmpty { lines.append("已经确认过的竞品：\(knownCompetitors.joined(separator: "、"))") }
        let extra = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append("补充说明：\(extra)") }
        return lines.joined(separator: "\n")
    }
}

struct ProductReferenceImage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var path: String
    var caption: String = ""
    var bookmark: Data? = nil
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
    var pausePlan: PausePlan? = nil
    var edgeTrim: EdgeTrimPlan? = nil
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
    /// 自己写的分镜稿（口播稿的分镜说明），和 AI 生成的分镜表是两回事。
    var storyboardScript: String? = nil
    /// 分镜稿表格：导入的 CSV 和在里面改过的内容。
    var scriptTable: ScriptTable? = nil
    var brollAssets: [BrollAsset]? = nil
    /// 排上时间轴的 B-roll 片段，老项目没有这个字段。
    var brollPlacements: [BrollPlacement]? = nil
    var productProfile: ProductProfile? = nil
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

    /// 第一级断句：用带标点的文稿（Word 稿 / 分镜稿台词）给逐字稿补出标点边界。
    /// 逐字识别稿本身没有标点，所以这一级只能来自文稿。文稿和识别稿可能对不上
    /// （错字、漏字、两种写法），因此用同一套带子编辑距离做对齐；对齐不可信时返回
    /// `aligned == false`，让调用方退回停顿和本地规则，绝不用错的标点去切。
    static func manuscriptBreaks(manuscript: String, in words: [TranscriptWord]) -> (breaks: Set<UUID>, aligned: Bool) {
        let trimmed = manuscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = words.filter { !$0.isDeleted }
        guard !trimmed.isEmpty, active.count > 1 else { return ([], false) }

        // 识别稿一侧：只保留可映射字符，记住每个字符属于哪个词。
        let source = active.flatMap { word in
            word.text.filter { !$0.isWhitespace && !$0.isNewline }.map { ($0, word.id) }
        }
        let flattened = source.map(\.0)
        guard flattened.count > 1 else { return ([], false) }

        // 文稿一侧：去掉标点后摊平，同时记住每个字符之前出现过句读标点。
        // 标点集合与 mandatorySentenceBreaks 一致：顿号只表并列，冒号可能属于比例，都不算断点。
        let breakPunctuation = CharacterSet(charactersIn: "，,。！？!?;；")
        var characters: [Character] = []
        var punctuationBefore: [Bool] = []
        var pendingBreak = false
        for character in trimmed {
            if character.isWhitespace || character.isNewline { continue }
            if character.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                if character.unicodeScalars.contains(where: breakPunctuation.contains) { pendingBreak = true }
                continue
            }
            characters.append(character)
            punctuationBefore.append(pendingBreak)
            pendingBreak = false
        }
        guard characters.count > 1 else { return ([], false) }

        // 文稿通常比识别稿干净（识别稿还带着 NG 和重录），允许的编辑量按识别稿长度给。
        let budget = max(4, flattened.count / 20)
        guard let mapping = articleAlignment(returned: characters, original: flattened, maxEdits: budget) else {
            return ([], false)
        }
        let covered = mapping.compactMap { $0 }.count
        guard covered >= characters.count / 2 else { return ([], false) }

        // 文稿里每个句读标点之后的首个字符，落到识别稿的哪个词，就在那个词之前断句。
        var breaks: Set<UUID> = []
        for index in characters.indices where punctuationBefore[index] {
            // 换行落在标点之前时顺延到下一个非标点字符，和 applySegmentedArticle 保持一致。
            var probe = index
            while probe < characters.count,
                  characters[probe].unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                probe += 1
            }
            guard probe < characters.count, let sourceIndex = mapping[probe], sourceIndex > 0 else { continue }
            breaks.insert(source[sourceIndex].1)
        }
        return (breaks, !breaks.isEmpty)
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
        let independentStarters = ["当", "如果", "因为", "所以", "但是", "不过", "而且", "然后", "后来", "其实", "比如", "对于", "虽然", "那", "这", "我", "我们", "他们", "最重要", "要知道", "自从"]
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
                    let boundaryIndex = segments[index + 1].lowerBound
                    let previousWord = words[words.index(before: boundaryIndex)]
                    let nextWord = words[boundaryIndex]
                    let boundaryGap = nextWord.start - previousWord.end
                    let previousCharacter = previousWord.text.last
                    let nextCharacter = nextWord.text.first
                    let brokenFunctionWord = boundaryGap < 0.35 && previousCharacter.map(incompleteEnd.contains) == true
                    let splitASCIIWord = boundaryGap < 0.35
                        && previousCharacter?.isASCII == true && previousCharacter?.isLetter == true
                        && nextCharacter?.isASCII == true && (nextCharacter?.isLetter == true || nextCharacter?.isNumber == true)
                    let looksLikeFixedWidthWrap = (24...30).contains(text.count)
                        && boundaryGap < 0.32
                        && !source.unicodeScalars.contains(where: CharacterSet(charactersIn: "。！？!?；;").contains)
                        && !independentStarters.contains(where: next.hasPrefix)
                    let dependentClause = text.count <= 12 && (source.hasSuffix("，") || source.hasSuffix(",")) && dependentStarters.contains(where: text.hasPrefix)
                    if leadingFragment || unfinished || continued || dependentClause || brokenFunctionWord || splitASCIIWord || looksLikeFixedWidthWrap {
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

    /// 第二级断句：只按字数和时长兜底切分过长的片段。断点优先选说话人真实换气的位置，
    /// 换气是逐字时间戳算出来的，不需要模型；实在没有停顿再用左右最均衡的位置。
    static func balancedSentenceBreaks(_ refined: Set<UUID>, candidates: Set<UUID>, in words: [TranscriptWord], maxCharacters: Int = 22, maxDuration: Double = 8, pauseThreshold: Double = 0.28) -> Set<UUID> {
        var breaks = refined
        func count(_ range: Range<Int>) -> Int {
            words[range].map(\.text).joined().filter { !$0.isWhitespace && !"，,。.!?！？;；".contains($0) }.count
        }
        /// 某个词之前的真实停顿，由逐字时间戳直接相减得到。
        func pauseBefore(_ index: Int) -> Double {
            guard index > 0, index < words.count else { return 0 }
            return max(0, words[index].start - words[index - 1].end)
        }
        func balance(_ range: Range<Int>, _ options: [Int]) -> Int? {
            options.min { lhs, rhs in
                abs(count(range.lowerBound..<lhs) - count(lhs..<range.upperBound)) < abs(count(range.lowerBound..<rhs) - count(rhs..<range.upperBound))
            }
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
                let tooLongByCharacters = totalCharacters > maxCharacters
                let tooLongByDuration = duration > maxDuration
                guard tooLongByCharacters || tooLongByDuration else { continue }
                let options = range.dropFirst().filter { index in
                    candidates.contains(words[index].id) && !breaks.contains(words[index].id) && count(range.lowerBound..<index) >= 5 && count(index..<range.upperBound) >= 5
                }
                guard !options.isEmpty else { continue }
                // 字数超标时断点要落在 [下限, maxCharacters] 之间；纯粹时长超标（语速很慢）
                // 时整个区间都允许，只要两边都够长。
                let lowerLimit = tooLongByCharacters ? max(5, min(8, maxCharacters / 2)) : 5
                let upperLimit = tooLongByCharacters ? maxCharacters : totalCharacters
                func withinWindow(_ index: Int) -> Bool {
                    let left = count(range.lowerBound..<index)
                    return left >= lowerLimit && left <= upperLimit
                }
                var paused = options.filter { withinWindow($0) && pauseBefore($0) >= pauseThreshold }
                if paused.isEmpty, tooLongByDuration {
                    // 时长已经严重超标却找不到明显停顿：放宽到整个区间里最大的那个微小停顿，
                    // 也不该让一条字幕跨着空白一直挂在那里。
                    paused = options.filter { pauseBefore($0) >= 0.12 }
                }
                let best: Int?
                if let anchor = paused.max(by: { pauseBefore($0) < pauseBefore($1) }) {
                    // 停顿长度接近时，再在它们之间挑左右更均衡的那个。
                    let tied = paused.filter { pauseBefore(anchor) - pauseBefore($0) <= 0.08 }
                    best = balance(range, tied) ?? anchor
                } else {
                    best = balance(range, options)
                }
                if let best { added = words[best].id; break }
            }
            guard let added else { return breaks }
            breaks.insert(added)
        }
    }

    /// 本地断句骨架，完全不调用模型：第一级文稿标点（识别稿本身没有标点，标点只能来自文稿），
    /// 第二级真实停顿，第三级自然语言规则，最后才是字数和时长兜底。
    /// 文稿与识别稿对不齐时 `manuscriptBreaks` 会拒绝返回，这里自动退化成只用停顿和本地规则。
    static func localSentenceBreaks(words: [TranscriptWord], manuscript: String = "") -> (breaks: Set<UUID>, manuscriptAligned: Bool) {
        let active = words.filter { !$0.isDeleted }
        guard active.count > 1 else { return ([], false) }
        let fromManuscript = manuscriptBreaks(manuscript: manuscript, in: active)
        let punctuation = fromManuscript.breaks.union(mandatorySentenceBreaks(in: active))
        let refined = refinedSentenceBreaks(punctuation, in: active)
        let semanticFallbacks = Set(subtitleCues(words: active).dropFirst().compactMap(\.wordIDs.first))
        let breaks = balancedSentenceBreaks(refined, candidates: refined.union(semanticFallbacks), in: active)
        return (breaks, fromManuscript.aligned)
    }

    static func subtitleCues(words: [TranscriptWord], breakBefore: Set<UUID> = [], joinBefore: Set<UUID> = [], maxCharacters: Int = 28, maxDuration: Double = 8) -> [SubtitleCue] {
        var cues: [SubtitleCue] = [], pending: [TranscriptWord] = []
        let terminal = CharacterSet(charactersIn: "。！？!?；;\n")
        let phraseBreak = CharacterSet(charactersIn: "，,：:")
        let semanticStarters = ["事情", "那时", "就被", "在短暂", "当你", "当我", "当我们", "当大家", "如果", "因为", "所以", "但是", "不过", "而且", "然后", "后来", "其实", "比如", "对于", "与其", "虽然", "即使", "只要", "自从", "从来", "而是", "让一个", "让我", "让我们", "让它", "更多", "我是", "记得", "那我们", "要知道", "根本", "真是", "去之前", "这是", "行驶", "很多时候", "我们的计划", "我们抽到", "拍摄地点", "去到处", "我很", "这几年", "我也", "像这样", "能够", "最重要", "连拉链", "在背包", "外边", "内侧", "这两个", "值得", "除了", "他们家", "包的内侧", "下方", "但它", "雨伞", "下雨", "背起来", "一个兼顾", "就足够", "如果你", "记得", "以前", "吃饭", "价格", "还需要", "一打开", "在参数层面"]
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
        func safeFallbackBoundary() -> Int? {
            let weakEnd = Set("的地得从在把被和与或为让给用对向是一两三四五六七八九十百千万亿0123456789")
            let weakStart = Set("个台块寸种些点层倍元万千百亿的地得了着过和与或0123456789")
            func isASCIIWord(_ character: Character?) -> Bool {
                guard let scalar = character?.unicodeScalars.first, character?.unicodeScalars.count == 1 else { return false }
                return CharacterSet.alphanumerics.contains(scalar) && scalar.value < 128
            }
            let options = pending.indices.dropFirst().filter { index in
                let left = joined(Array(pending[..<index])), right = joined(Array(pending[index...]))
                return left.count >= 8 && left.count <= maxCharacters && right.count >= 4
            }
            return options.min { lhs, rhs in
                func score(_ index: Int) -> Double {
                    let left = joined(Array(pending[..<index])), right = joined(Array(pending[index...]))
                    var value = Double(abs(left.count - min(22, maxCharacters)))
                    if left.last.map(weakEnd.contains) == true { value += 100 }
                    if right.first.map(weakStart.contains) == true { value += 100 }
                    if isASCIIWord(left.last), isASCIIWord(right.first) { value += 200 }
                    if semanticStarters.contains(where: right.hasPrefix) { value -= 20 }
                    value -= min(12, max(0, pending[index].start - pending[index - 1].end) * 20)
                    return value
                }
                return score(lhs) < score(rhs)
            }
        }
        for word in words where !word.isDeleted {
            if breakBefore.contains(word.id) { flush() }
            if let last = pending.last {
                let gap = word.start - last.end
                let text = joined(pending)
                let weakEnding = text.last.map { "的地得从在把被和与或一两三四五六七八九十百千万亿0123456789".contains($0) } == true
                if gap >= 0.9 || (gap >= 0.45 && text.count >= 6 && !weakEnding) { flush() }
            }
            pending.append(word)
            // Semantic clauses outrank visual length. Wait for at least two characters
            // on the new side so a one-character starter is not left by itself.
            if let amount = semanticBoundary(), joined(Array(pending.dropFirst(amount))).count >= 2 { flush(amount) }
            while pending.count > 1, joined(pending).count > maxCharacters + 2 || (pending.last!.end - pending.first!.start) > maxDuration {
                if let natural = pending.dropLast().lastIndex(where: { contains($0, phraseBreak) }) {
                    flush(pending.distance(from: pending.startIndex, to: natural) + 1)
                } else if let amount = semanticBoundary() ?? lexicalBoundary() ?? safeFallbackBoundary() {
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
            } else if let amount = semanticBoundary() ?? lexicalBoundary() ?? safeFallbackBoundary() {
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

    /// 把模型返回的整篇原文对齐回逐字稿。
    /// 重新断句不会删字，所以可以把文字从 `[序号]` 里抽出来、只发纯文本让模型在无噪声的
    /// 情况下换行，拿到返回结果后再逐字映射回 UUID。
    /// 允许极少量改动（模型顺手改了错别字或补了一个标点），但改动超过阈值就判定这次返回
    /// 不可信，避免把一个被改写的原文当成断句结果用；这种情况交给调用方重试或退回序号方案。
    static func applySegmentedArticle(_ article: String, to words: [TranscriptWord]) -> (words: [TranscriptWord], breaks: Set<UUID>)? {
        func isMapped(_ character: Character) -> Bool { character != "\n" && character != "\r" && !character.isWhitespace }
        let punctuation = CharacterSet.punctuationCharacters
        let source = words.filter { !$0.isDeleted }.flatMap { word in word.text.filter(isMapped).map { ($0, word.id) } }
        let flattened = source.map(\.0)
        let returned = Array(article.filter(isMapped))
        guard flattened.count > 1, !returned.isEmpty else { return nil }
        guard let mapping = articleAlignment(returned: returned, original: flattened, maxEdits: max(2, flattened.count / 200)) else { return nil }

        // 返回文本里每个换行落在哪个字符之前。
        var breakFlags = [Bool](repeating: false, count: returned.count)
        var pendingBreak = false, cursor = 0
        for character in article {
            if character == "\n" || character == "\r" { pendingBreak = true; continue }
            if character.isWhitespace { continue }
            guard cursor < breakFlags.count else { return nil }
            if pendingBreak { breakFlags[cursor] = true; pendingBreak = false }
            cursor += 1
        }
        guard cursor == returned.count else { return nil }

        // 标点不单独成行：换行落标点之前时顺延到下一个非标点字符，和本地规则一致。
        var breaks: Set<UUID> = []
        var carry = false
        for index in returned.indices {
            if breakFlags[index] { carry = true }
            guard carry, let sourceIndex = mapping[index], sourceIndex > 0 else { continue }
            guard !returned[index].unicodeScalars.allSatisfy({ punctuation.contains($0) }) else { continue }
            breaks.insert(source[sourceIndex].1)
            carry = false
        }
        return (words, breaks)
    }

    /// 带子（band）的编辑距离对齐：返回 `returned` 每个字符对应的 `original` 下标。
    /// 没有对应关系的字符映射为 nil。编辑次数超过 `maxEdits`、长度差异过大或矩阵超出
    /// 预算时返回 nil，表示这次返回不可信。
    static func articleAlignment(returned: [Character], original: [Character], maxEdits: Int) -> [Int?]? {
        let n = returned.count, m = original.count
        guard n > 0, m > 0, abs(n - m) <= maxEdits else { return nil }
        if returned == original { return (0..<n).map { Optional($0) } }
        let longest = max(n, m)
        guard longest <= 40_000 else { return nil }
        let band = min(128, max(32, longest / 20 + 16))
        let width = 2 * band + 1
        func center(_ row: Int) -> Int { Int((Double(row) * Double(m) / Double(n)).rounded()) }
        var offsets = [Int](repeating: 0, count: n + 1)
        for row in 0...n { offsets[row] = max(0, center(row) - band) }
        var costs = [Int](repeating: Int.max, count: (n + 1) * width)
        var operations = [UInt8](repeating: 0, count: (n + 1) * width)
        func slot(_ row: Int, _ column: Int) -> Int? {
            let offset = offsets[row]
            guard column >= offset, column < offset + width else { return nil }
            return row * width + (column - offset)
        }
        func cost(_ row: Int, _ column: Int) -> Int? { slot(row, column).map { costs[$0] } }

        for row in 0...n {
            let start = offsets[row], end = min(m, offsets[row] + width - 1)
            guard start <= end else { continue }
            for column in start...end {
                guard let position = slot(row, column) else { continue }
                if row == 0, column == 0 { costs[position] = 0; continue }
                var best = Int.max
                var operation: UInt8 = 0
                if row > 0, column > 0, let previous = cost(row - 1, column - 1), previous != Int.max {
                    let matched = returned[row - 1] == original[column - 1]
                    best = previous + (matched ? 0 : 1)
                    operation = matched ? 0 : 1
                }
                if row > 0, let previous = cost(row - 1, column), previous != Int.max, previous + 1 < best {
                    best = previous + 1
                    operation = 2
                }
                if column > 0, let previous = cost(row, column - 1), previous != Int.max, previous + 1 < best {
                    best = previous + 1
                    operation = 3
                }
                guard best != Int.max else { continue }
                costs[position] = best
                operations[position] = operation
            }
        }
        guard let end = slot(n, m), costs[end] <= maxEdits else { return nil }

        var mapping = [Int?](repeating: nil, count: n)
        var row = n, column = m
        while row > 0 || column > 0 {
            guard let position = slot(row, column) else { return nil }
            switch operations[position] {
            case 0, 1:
                mapping[row - 1] = column - 1
                row -= 1
                column -= 1
            case 2:
                row -= 1
            default:
                column -= 1
            }
        }
        return mapping
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

    /// 鱼骨图判据（阈值）：重复的那几遍里更长的一版到了这个量级，就当成“整段重录”，
    /// 可能是在试不同语气，必须交给用户选；比这短的就是读错，保留最后一遍即可。
    /// 中文口播一句话大约十几二十个字、四五秒，所以 45 字 / 12 秒 ≈ 三句以上，
    /// 正好对应“分支是一整段话”；字幕行数则是直接数节点上有几句话。
    static let toneTakeMinimumCharacters = 45
    static let toneTakeMinimumSeconds = 12.0
    static let toneTakeMinimumCues = 3

    /// 一个节点上的分支属于哪一种：读错（可自动删）还是成段重录（要人选语气）。
    static func repetitionBranchKind(characters: Int, seconds: Double, cues: Int) -> EditSuggestion.RepetitionKind {
        if cues >= toneTakeMinimumCues || characters >= toneTakeMinimumCharacters || seconds >= toneTakeMinimumSeconds { return .alternateTake }
        return .misread
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
        func orderedOverlap(_ lhs: String, _ rhs: String) -> Double {
            let a = Array(lhs), b = Array(rhs)
            guard !a.isEmpty, !b.isEmpty else { return 0 }
            var previous = Array(repeating: 0, count: b.count + 1)
            for left in a {
                var current = Array(repeating: 0, count: b.count + 1)
                for (index, right) in b.enumerated() {
                    current[index + 1] = left == right ? previous[index] + 1 : max(current[index], previous[index + 1])
                }
                previous = current
            }
            return Double(previous[b.count]) / Double(min(a.count, b.count))
        }

        /// Restart with inserted particles (的 / 是 / 了) or a nearby reorder, e.g. a
        /// half-said line immediately followed by the full line. Character-level
        /// edit distance punishes the insertions too hard, so match by ordered overlap.
        func restartWithInsertion(_ lhs: String, _ rhs: String) -> Bool {
            let shorter = min(lhs.count, rhs.count)
            let longer = max(lhs.count, rhs.count)
            guard shorter >= 6, Double(shorter) / Double(longer) >= 0.4, lhs.count <= rhs.count * 3 / 2 else { return false }
            let (small, big) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
            var remaining: [Character: Int] = [:]
            for character in big { remaining[character, default: 0] += 1 }
            var shared = 0
            for character in small where (remaining[character] ?? 0) > 0 {
                remaining[character]! -= 1
                shared += 1
            }
            guard Double(shared) / Double(shorter) >= 0.8 else { return false }
            return orderedOverlap(lhs, rhs) >= 0.8
        }
        func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
            zip(lhs, rhs).prefix { $0 == $1 }.count
        }
        typealias Candidate = (text: String, start: Double, end: Double, wordIDs: [UUID], cueCount: Int)
        var candidates: [Candidate] = []
        for start in cues.indices {
            var text = "", ids: [UUID] = []
            for end in start..<min(start + 3, cues.count) {
                if end > start, cues[end].start - cues[end - 1].end > 4 { break }
                text += cues[end].text
                ids += cues[end].wordIDs
                let value = normalized(text)
                if value.count >= 3 { candidates.append((value, cues[start].start, cues[end].end, ids, end - start + 1)) }
            }
        }
        let reference = normalized(manuscript)
        let ordered = candidates.sorted { $0.end == $1.end ? $0.text.count > $1.text.count : $0.end > $1.end }
        var results: [EditSuggestion] = [], usedEarlierIDs: Set<UUID> = [], protectedRetainedIDs: Set<UUID> = []
        for candidate in ordered where Set(candidate.wordIDs).isDisjoint(with: usedEarlierIDs.union(protectedRetainedIDs)) {
            let maxDistance = candidate.text.count <= 8 ? 10.0 : 60.0
            let nearbyLater = candidates.filter { $0.start >= candidate.end && $0.start - candidate.end <= maxDistance && Set($0.wordIDs).isDisjoint(with: usedEarlierIDs) }
            let scored = nearbyLater.compactMap { match -> (Candidate, Double, Bool)? in
                let gap = match.start - candidate.end
                let sharedPrefix = commonPrefixCount(candidate.text, match.text)
                let leadingExtra = match.text.range(of: candidate.text).map { match.text.distance(from: match.text.startIndex, to: $0.lowerBound) }
                let nearRestart = gap <= 6 && candidate.text.count <= match.text.count && candidate.text.count >= 6 && ((leadingExtra.map { $0 <= 3 } ?? false) || sharedPrefix >= max(6, candidate.text.count * 2 / 3))
                let referenceBacked = min(candidate.text.count, match.text.count) >= 10 && !reference.isEmpty && (reference.contains(candidate.text) || reference.contains(match.text))
                var score = nearRestart ? 0.95 : repetitionScore(candidate.text, match.text)
                if score == 0, gap <= 15, restartWithInsertion(candidate.text, match.text) { score = 0.8 }
                if score == 0, referenceBacked, editSimilarity(candidate.text, match.text) >= 0.65 { score = 0.65 }
                return score > 0 ? (match, score - gap * 0.005, referenceBacked) : nil
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
            let match = best.0, score = best.1, referenceBacked = best.2
            usedEarlierIDs.formUnion(candidate.wordIDs)
            protectedRetainedIDs.formUnion(match.wordIDs)
            // 鱼骨图：节点上这条分支有多长，决定它是读错还是成段重录。
            let branchCues = max(candidate.cueCount, match.cueCount)
            let branchSeconds = max(candidate.end - candidate.start, match.end - match.start)
            let kind = repetitionBranchKind(characters: max(candidate.text.count, match.text.count), seconds: branchSeconds, cues: branchCues)
            let timestamp = String(format: "%02d:%04.1f", Int(match.start) / 60, match.start.truncatingRemainder(dividingBy: 60))
            let source = referenceBacked ? "，并已参考文字稿确认表达" : ""
            let title = kind == .alternateTake ? "成段重录（两个语气选一个）" : "读错重录（保留最后一遍）"
            let reason = kind == .alternateTake
                ? "这 \(branchCues) 句在 \(timestamp) 又完整录了一遍（约 \(Int(branchSeconds.rounded())) 秒），像是同一段话换了个语气重录\(source)。我没有动它：请试听两版，选你要留的那一版。"
                : "后面在 \(timestamp) 还有相同或相似表达\(source)，前面这遍没读完整，按口播规则保留最后一遍。"
            results.append(.init(type: .repetition, title: title, reason: reason, confidence: min(1, score), wordIDs: candidate.wordIDs, retainedWordIDs: match.wordIDs, start: candidate.start, end: candidate.end, repetitionKind: kind))
        }
        return results.sorted { $0.start < $1.start }
    }

    /// 这段停顿是不是章节/段落边界：说话人自己停了很久，或者前一句已经用句末标点收尾。
    static func isParagraphBreak(_ breath: BreathCandidate, threshold: Double = 0.9) -> Bool {
        if breath.duration >= threshold { return true }
        return breath.leftText.last.map { "。！？!?…".contains($0) } ?? false
    }

    /// 章节停顿：说话人自己停了这么久，就当成一段的结束。断句窗口按它切开，
    /// 让窗口接缝落在说话人的呼吸上，而不是落在句子中间。
    static let chapterPauseThreshold = 0.9

    /// 长视频分段断句的窗口划分。先按长停顿定章节，再按字数预算把相邻章节打包成窗口，
    /// 过长的章节先在内部顺着较大的停顿切开。返回的区间首尾相接、完整覆盖整篇、互不重叠。
    static func segmentationWindows(in words: [TranscriptWord], targetCharacters: Int = 1200) -> [Range<Int>] {
        guard !words.isEmpty else { return [] }
        func characters(_ range: Range<Int>) -> Int { words[range].reduce(0) { $0 + $1.text.count } }

        var chapters: [Range<Int>] = [], chapterStart = 0
        for index in words.indices.dropFirst() where words[index].start - words[index - 1].end >= chapterPauseThreshold {
            chapters.append(chapterStart..<index)
            chapterStart = index
        }
        chapters.append(chapterStart..<words.count)

        var pieces: [Range<Int>] = []
        for chapter in chapters {
            guard characters(chapter) > targetCharacters else { pieces.append(chapter); continue }
            var start = chapter.lowerBound, cursor = chapter.lowerBound
            while cursor < chapter.upperBound {
                cursor += 1
                guard characters(start..<cursor) >= targetCharacters else { continue }
                let floor = start + max(1, (cursor - start) / 2)
                let cut = stride(from: cursor - 1, through: floor, by: -1)
                    .first { words[$0].start - words[$0 - 1].end >= 0.45 } ?? cursor
                pieces.append(start..<cut)
                start = cut
                cursor = cut
            }
            if start < chapter.upperBound { pieces.append(start..<chapter.upperBound) }
        }

        guard let first = pieces.first else { return [] }
        var windows: [Range<Int>] = [], currentStart = first.lowerBound
        for (index, piece) in pieces.enumerated() where index > 0 {
            guard characters(currentStart..<piece.upperBound) > targetCharacters else { continue }
            windows.append(currentStart..<piece.lowerBound)
            currentStart = piece.lowerBound
        }
        windows.append(currentStart..<words.count)
        return windows
    }

    /// 一段被剪掉的气口，末尾要还给时间线的静音长度。
    static func pauseRetention(_ breath: BreathCandidate, plan: PausePlan) -> Double {
        guard plan != .off, breath.duration > 0 else { return 0 }
        return min(breath.duration, isParagraphBreak(breath) ? plan.chapterKeep : plan.sentenceKeep)
    }

    static func deletedRanges(words: [TranscriptWord], breaths: [BreathCandidate], pause: PausePlan = .off, padding: Double = 0.05) -> [TimeRange] {
        let wordRanges = words.filter(\.isDeleted).map { TimeRange(start: max(0, $0.start - padding), end: $0.end + padding) }
        let deletedBreaths = breaths.filter { $0.state == .deleted }
        var ranges = merge(wordRanges + deletedBreaths.map { TimeRange(start: $0.start, end: $0.end) })
        guard pause != .off else { return ranges }
        // 每个删除区间末尾落在气口里时，把最后一段静音还给时间线：这样句子结尾
        // 会留下一点呼吸感，而不是和下一句贴死。删除区间末尾若已经是被删掉的字，
        // 那附近本来就没有静音可还，保持原样。
        for index in ranges.indices {
            let end = ranges[index].end
            guard let breath = deletedBreaths.last(where: { $0.start < end - 0.001 && end <= $0.end + 0.001 }) else { continue }
            let keep = min(pauseRetention(breath, plan: pause), ranges[index].duration)
            ranges[index].end = max(ranges[index].start, end - keep)
        }
        return ranges.filter { $0.end > $0.start }
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
    var messages: [ChatMessage] = [.init(role: .assistant, text: "导入素材后，我会生成逐词文字稿并提出可撤销的剪辑建议。")]
    var manuscript = ""
    var prompt = ""
    var taskState: TaskState = .idle
    var showImporter = false
    var showProjectImporter = false
    var showRelinkImporter = false
    /// 项目目录变化后自增，用来让侧栏项目列表立刻刷新。
    var projectListRevision = 0
    var showExporter = false
    var showSettings = false
    var selectedTab = MediaTab.transcript
    var breathMode = BreathMode.confirm { didSet { applyBreathMode(); autosave() } }
    var dedupeMode = DedupeMode.confirm { didSet { autosave() } }
    var breathThreshold = 0.45 { didSet { refreshBreaths() } }
    var pausePlan: PausePlan = .standard { didSet { autosave() } }
    /// 片头片尾没有台词的那一段：默认剪掉，只留一点点前导/收尾。
    var edgeTrim: EdgeTrimPlan = .trim { didSet { autosave() } }
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
    /// B-roll 媒体库：项目级数据，随项目落盘。
    var brollAssets: [BrollAsset] = []
    /// 已排到时间线上的 B-roll 片段（分镜页「AI 排 B-roll」的结果），随项目保存。
    var brollPlacements: [BrollPlacement] = []
    /// 挑素材这一步的注入点：不设就走本机模型；测试里换成假的就不去启动本地服务。
    @ObservationIgnored var brollChooser: (@Sendable ([AIClient.BrollChoiceRequest]) async throws -> [Int: Int])?
    var selectedBrollID: UUID?
    /// 多选（⌘ 点选）：手动归类时一次拖好几条。
    var brollSelection: Set<UUID> = []
    /// 多选的锚点：⇧ 点选时从这里拉到目标那一条。
    var brollSelectionAnchor: UUID?
    /// 识别结果里点某个时间点，预览跳过去核对。
    var brollPreviewRequest: BrollPreviewRequest?
    /// B-roll 预览里画面停在哪一刻。预览面板自己报上来，
    /// 「把入点/出点设成当前画面」要用它 —— 拖到准的位置比敲数字靠谱。
    var brollPreviewTime = 0.0
    var brollAnalysisProgress: Double?
    var brollQuery = ""
    var brollMotionFilter: BrollMotion?
    /// 缩略图只缓存在内存里：不写进项目文件，重新打开时按需再生成。
    var brollThumbnails: [UUID: NSImage] = [:]
    var brollAnalysisTask: Task<Void, Never>?
    /// 产品档案：本地视觉模型判断“这条素材有没有拍到产品”的依据。
    var productProfile = ProductProfile()
    /// 产品镜头挑选：进度、任务句柄和界面提示。
    var brollProductProgress: Double?
    var brollProductNotice: String = ""
    var brollProductTask: Task<Void, Never>?
    /// 本地视觉模型的准备状态。
    var localModelState: LocalModelState = .unknown
    var localModelNotice: String = ""
    var localModelTask: Task<Void, Never>?
    /// 产品筛选：全部 / 含产品 / 产品主体。
    var brollProductFilter: BrollProductPresence?
    /// 只看还有“待确认物品”的素材：模型不认识、你还没说它是竞品还是无关的东西。
    var brollOnlyPendingUnknown = false
    /// 认物品时抽几帧（用户可选；帧数就是调用次数，直接决定一条素材要多久）。
    var brollScanMode: BrollScanMode = BrollScanMode(rawValue: UserDefaults.standard.integer(forKey: "brollScanMode")) ?? .standard
    /// 实测：本地模型平均每次调用要几秒（跑过一批之后就有值了，用来给用户估时间）。
    var brollSecondsPerCall: Double?
    /// 列表排序：按推荐分排 or 按文件名排。
    var brollSortByPick = true
    /// 参考图缩略图，同样只放内存。
    var productReferenceThumbnails: [UUID: NSImage] = [:]
    /// 自己写的分镜稿：口播稿的镜头说明，随项目保存。
    var storyboardScript: String = ""
    /// 分镜稿表格：导入 CSV 后可以改内容、调列宽行高，随项目保存。
    var scriptTable = ScriptTable()
    /// 上一次对齐时间用的口播指纹，只放内存：口播或剪辑变了才重新对一次。
    @ObservationIgnored private var scriptTimeFingerprint = ""

    @ObservationIgnored private var timeObserver: Any?
    private struct Snapshot { var words: [TranscriptWord]; var suggestions: [EditSuggestion]; var breaths: [BreathCandidate]; var subtitleBreaks: Set<UUID>; var subtitleJoins: Set<UUID>; var trimStart: Double; var trimEnd: Double; var manuscript: String; var storyboards: [StoryboardItem]; var brollPlacements: [BrollPlacement] }
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
        var ranges = TimelineEngine.deletedRanges(words: words, breaths: breaths, pause: pausePlan)
        if edgeTrim.isTrimming, let first = words.first(where: { !$0.isDeleted }), let last = words.last(where: { !$0.isDeleted }) {
            // 片头/片尾没有台词的部分同样按“删除区间”处理：删除区间仍是唯一真相源，
            // keptRanges / 播放跳过 / 字幕 / EDL / FCPXML / MP4 会自动一致。
            // 只留 pausePlan 的句末留白，比如标准档就是 0.3 秒前导和收尾。
            let lead = max(0, first.start - pausePlan.sentenceKeep)
            if lead > 0 { ranges.append(.init(start: 0, end: lead)) }
            let tail = last.end + pausePlan.sentenceKeep
            if tail < duration { ranges.append(.init(start: tail, end: duration)) }
        }
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
        let startedWithoutProject = projectURL == nil
        burnSubtitles = true; subtitleFontSize = 48
        if startedWithoutProject { projectName = url.deletingPathExtension().lastPathComponent }
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
        if startedWithoutProject { projectListRevision &+= 1 }
    }

    // MARK: - AI 后端（本机 Qwen3-VL，DeepSeek 云端接口已关闭）

    /// 所有 AI 动作的统一入口：取出当前后端，调用前确保本机服务在跑，再交给调用方。
    private func aiClient() async throws -> AIClient {
        let settings = AISettings.current
        try await settings.prepare()
        return AIClient(settings: settings)
    }

    private func aiEditClient() async throws -> AIEditClient {
        let settings = AISettings.current
        try await settings.prepare()
        return AIEditClient(settings: settings)
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
        let local = applyLocalSegmentation()
        refreshBreaths()
        let source = local.manuscriptAligned ? "已对照文稿标点" : "没有可用文稿，仅按停顿和自然语言规则"
        taskState = .done("断句完成（\(source)）：\(subtitleCues.count) 条字幕")
        messages.append(.init(role: .status, text: "已使用现有逐字时间戳重新断句（\(source)），未重新运行 WhisperKit。"))
        markChanged()
    }

    @discardableResult
    private func applyLocalSegmentation() -> (segments: Int, manuscriptAligned: Bool) {
        let activeWords = words.filter { !$0.isDeleted }
        guard activeWords.count > 1 else {
            subtitleBreaks = []
            subtitleJoins = []
            return (0, false)
        }
        let local = TimelineEngine.localSentenceBreaks(words: activeWords, manuscript: manuscript)
        subtitleBreaks = local.breaks
        subtitleJoins = []
        return (subtitleCues.count, local.manuscriptAligned)
    }

    func resegmentWithAI() async {
        resegment()
        guard !words.isEmpty else { return }
        // 云端接口已关闭：断句走本机规则（文稿标点 + 真实停顿），不再向模型发请求。
        guard !AISettings.current.isLocal else { return }
        let service = AISettings.current.serviceName
        taskState = .working("\(service) 正在选择自然断句位置…")
        let activeWords = words.filter { !$0.isDeleted }
        do {
            let outcome = try await aiClient().segmentWordBoundaries(activeWords, reference: manuscript)
            let modelBreaks = outcome.breaks
            checkpoint()
            let manuscriptBreaks = TimelineEngine.manuscriptBreaks(manuscript: manuscript, in: activeWords).breaks
            let proposed = modelBreaks.union(manuscriptBreaks).union(TimelineEngine.mandatorySentenceBreaks(in: activeWords))
            let refined = TimelineEngine.refinedSentenceBreaks(proposed, in: activeWords)
            let semanticFallbacks = Set(TimelineEngine.subtitleCues(words: activeWords).dropFirst().compactMap(\.wordIDs.first))
            let breaks = TimelineEngine.balancedSentenceBreaks(refined, candidates: refined.union(semanticFallbacks), in: activeWords)
            subtitleBreaks = breaks
            // Model line breaks are semantic hints, not a command to suppress local
            // pause, punctuation and word-boundary detection everywhere else.
            subtitleJoins = []
            pendingReviewCorrections = [:]
            refreshBreaths()
            taskState = .done("\(service) 断句完成：\(subtitleCues.count) 条字幕，原文和时间戳未改变")
            let scope = outcome.windowCount > 1 ? "按章节分 \(outcome.windowCount) 段处理，" : ""
            let fallback = outcome.failedWindows > 0 ? "其中 \(outcome.failedWindows) 段改用本地规则，其余" : "均"
            messages.append(.init(role: .status, text: "\(service) \(scope)只对纯文本插入换行，\(fallback)映射回逐字稿后原始文字、标点、UUID 和时间戳均未改变。"))
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
        taskState = .working("\(AISettings.current.serviceName) 正在分析口误…")
        do {
            let remote = try await aiEditClient().analyze(words: words)
            let repeatedIDs = Set(repetitions.flatMap(\.wordIDs))
            suggestions = repetitions + remote.filter { $0.type != .repetition || repeatedIDs.isDisjoint(with: $0.wordIDs) }
            taskState = .done("发现 \(suggestions.count) 条建议")
            messages.append(.init(role: .status, text: "发现 \(suggestions.count) 条建议，请逐项确认。"))
            markChanged()
        } catch {
            if repetitions.isEmpty { taskState = .failed(error.localizedDescription) }
            else {
                taskState = .done("已标记 \(repetitions.count) 条重复句；其他分析暂时失败")
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
        var replacement = AIASRClient.estimatedWords(text: cleaned, start: cue.start, duration: cue.end - cue.start)
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
        var replacement = AIASRClient.estimatedWords(text: characters.joined(), start: cue.start, duration: cue.end - cue.start)
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

    /// Resolve only the visible subtitle row that the user acted on. A repetition
    /// suggestion may span several cues, so row actions must never apply the
    /// suggestion's complete word-ID set.
    func decideRepetitionSegment(_ id: UUID, wordIDs: [UUID], delete: Bool) {
        guard let index = suggestions.firstIndex(where: { $0.id == id && $0.type == .repetition && $0.state == .pending }) else { return }
        let visibleIDs = Set(wordIDs)
        let decidedIDs = suggestions[index].wordIDs.filter(visibleIDs.contains)
        guard !decidedIDs.isEmpty else { return }
        checkpoint()
        if delete {
            let targets = Set(decidedIDs)
            for wordIndex in words.indices where targets.contains(words[wordIndex].id) { words[wordIndex].isDeleted = true }
            reconcileStoryboardsAfterEdit()
        }
        suggestions[index].wordIDs.removeAll { visibleIDs.contains($0) }
        if suggestions[index].wordIDs.isEmpty {
            suggestions[index].state = delete ? .deleted : .kept
        } else {
            let remaining = words.filter { suggestions[index].wordIDs.contains($0.id) }
            if let first = remaining.first, let last = remaining.last {
                suggestions[index].start = first.start
                suggestions[index].end = last.end
            }
        }
        let start = suggestions[index].start
        let resolved = suggestions[index].state != .pending
        markChanged()
        if resolved { focusNextPendingRepetition(after: start) }
    }

    private func focusNextPendingRepetition(after start: Double) {
        let pending = suggestions.filter { $0.type == .repetition && $0.state == .pending }.sorted { $0.start < $1.start }
        guard let next = pending.first(where: { $0.start > start }) ?? pending.first else {
            taskState = .done("全部重复字幕已处理完成")
            return
        }
        focusSuggestion(next)
    }

    /// 鱼骨图上真正要人来定的一步：同一个节点有两版完整口播，选一个留下。
    /// keepEarlier 为真表示留较早那一版、剪掉后面重录的；否则反过来。
    func chooseAlternateTake(_ id: UUID, keepEarlier: Bool) {
        guard let index = suggestions.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return }
        let earlierIDs = Set(suggestions[index].wordIDs)
        let laterIDs = Set(suggestions[index].retainedWordIDs ?? [])
        guard !earlierIDs.isEmpty, !laterIDs.isEmpty, earlierIDs != laterIDs else { return }
        checkpoint()
        let losing = keepEarlier ? laterIDs : earlierIDs
        for wordIndex in words.indices where losing.contains(words[wordIndex].id) { words[wordIndex].isDeleted = true }
        suggestions[index].state = .deleted
        reconcileStoryboardsAfterEdit()
        let start = suggestions[index].start
        messages.append(.init(role: .status, text: keepEarlier ? "已留下较早那一版语气，剪掉后面重录的那一遍。" : "已留下后面那一版语气，剪掉较早的那一遍。"))
        markChanged()
        focusNextPendingRepetition(after: start)
    }

    /// 卡片上给用户看的短预览：一段文字稿截到 limit 个字。
    func previewText(for wordIDs: [UUID], limit: Int = 42) -> String {
        let ids = Set(wordIDs)
        let text = words.filter { ids.contains($0.id) }.map(\.text).joined()
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// 一组字在时间线上占的区间，用来试听“较早那版 / 后面那版”。
    func timeRange(for wordIDs: [UUID]) -> TimeRange {
        let ids = Set(wordIDs)
        let matched = words.filter { ids.contains($0.id) }
        guard let first = matched.first, let last = matched.last else { return .init(start: 0, end: 0) }
        return .init(start: first.start, end: last.end)
    }

    /// 批量“全部保留”照做；“全部删除”不碰需要选语气的整段重录——那种必须逐条选。
    func decideAll(delete: Bool) {
        var skipped = 0
        for item in suggestions where item.state == .pending {
            if delete, item.repetitionKind == .alternateTake { skipped += 1; continue }
            decide(item.id, delete: delete)
        }
        if skipped > 0 { messages.append(.init(role: .status, text: "跳过了 \(skipped) 处整段重录：它们要在两版语气里选一个，请逐条处理。")) }
    }
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
        let service = AISettings.current.serviceName
        isChatWorking = true; reviewProgress = 0.08; taskState = .working("\(service) 正在设计分镜 8%…")
        do {
            let generated = try await aiClient().generateStoryboards(cues: cues) { [weak self] value in
                Task { @MainActor in self?.reviewProgress = value; self?.taskState = .working("\(service) 正在设计分镜 \(Int(value * 100))%…") }
            }
            guard !generated.isEmpty else { throw AIError.invalidResponse("没有生成可用的分镜") }
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
            let generated = try await aiClient().generateStoryboards(cues: cues)
            guard !generated.isEmpty else { throw AIError.invalidResponse("没有生成可用的分镜") }
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
        // 鱼骨图分工：分支只有一句/半句的是读错，自动去重可以直接剪；
        // 分支是成段好几句的，可能是在试语气，只能摆出来让人选，绝不自动删。
        let misreads = repetitions.filter { $0.repetitionKind != .alternateTake }
        let toneChoices = repetitions.filter { $0.repetitionKind == .alternateTake }
        switch dedupeMode {
        case .automatic:
            let ids = Set(misreads.flatMap(\.wordIDs))
            if !ids.isEmpty {
                for index in words.indices where ids.contains(words[index].id) { words[index].isDeleted = true }
                reconcileStoryboardsAfterEdit()
            }
            suggestions += misreads.map { item in var item = item; item.state = .deleted; return item }
            suggestions += toneChoices
            var summary = misreads.isEmpty ? "没有可以直接剪掉的读错重录。" : "已从后往前自动去重 \(misreads.count) 处读错重录：每组保留时间线上最后一遍，可用 ⌘Z 撤销。"
            if !toneChoices.isEmpty { summary += "另有 \(toneChoices.count) 处是整段重录（可能换了语气），我没有动它们——请在右侧逐条试听，选你要留的那一版。" }
            messages.append(.init(role: .assistant, text: summary))
            taskState = .done(toneChoices.isEmpty ? "已自动去重 \(misreads.count) 处" : (misreads.isEmpty ? "\(toneChoices.count) 处整段重录等你选语气" : "已去重 \(misreads.count) 处；\(toneChoices.count) 处等你选语气"))
        case .confirm:
            suggestions += repetitions
            let summary = toneChoices.isEmpty
                ? "已从后往前找到 \(repetitions.count) 处重复句。我保留每组最后一遍，并把较早的版本放在这里逐条确认。"
                : "已从后往前找到 \(repetitions.count) 处重复句：其中 \(toneChoices.count) 处是整段重录，可能换了语气，需要你选留哪一版；其余按“保留最后一遍”给你逐条确认。"
            messages.append(.init(role: .assistant, text: summary))
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
        let service = AISettings.current.serviceName
        isChatWorking = true
        reviewProgress = 0.1
        taskState = .working("\(service) 审阅中 10%：正在准备去重后的文字稿和字幕…")
        let status = ChatMessage(role: .status, text: "\(service) 正在分块审阅去重后的字幕…")
        messages.append(status)
        do {
            reviewProgress = 0.35
            taskState = .working("\(service) 审阅中 35%：正在并发对照 Word 稿查找明显错误…")
            let corrections = try await aiClient().correct(reference: reference, cues: subtitleCues, words: activeWords)
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
        let status = ChatMessage(role: .status, text: "\(AISettings.current.serviceName) 正在处理指令…")
        messages.append(status)
        do {
            if !words.isEmpty && (text.count > 200 || text.contains("以字幕稿为准") || text.contains("修正字幕")) {
                let corrections = try await aiClient().correct(reference: text, words: words)
                checkpoint()
                for index in words.indices where !words[index].isDeleted {
                    if let corrected = corrections[words[index].id] { words[index].text = corrected }
                }
                markChanged()
                messages.append(.init(role: .assistant, text: corrections.isEmpty ? "已对照参考稿检查，没有发现需要确定修正的识别错误。" : "已按现有字幕时间轴完成校对，修正了 \(corrections.count) 处文字；没有新增、删除或重排字幕。"))
            } else {
                let reply = try await aiClient().chat(instruction: text, transcript: timestampedTranscript)
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
        words = []; manuscript = ""; storyboardScript = ""; scriptTable = ScriptTable(); pendingReviewCorrections = [:]; suggestions = []; breaths = []; subtitleBreaks = []; subtitleJoins = []; waveform = []; thumbnails = []; storyboards = []; selectedStoryboardID = nil; storyboardSelectedWordIDs = []; storyboardSelectionAnchorID = nil; brollAssets = []; brollPlacements = []; selectedBrollID = nil; brollThumbnails = [:]; brollQuery = ""; brollMotionFilter = nil; brollAnalysisTask?.cancel(); brollAnalysisProgress = nil; productProfile = ProductProfile(); brollProductTask?.cancel(); brollProductProgress = nil; brollProductNotice = ""; brollProductFilter = nil; brollSortByPick = true; productReferenceThumbnails = [:]; messages = [.init(role: .assistant, text: "这是“\(projectName)”项目。导入素材后，我会生成逐词文字稿并提出可撤销的剪辑建议。")]; undoStack = []; redoStack = []; hasUnsavedChanges = false
    }

    /// 项目主导的工作流：先有项目文件，再往里加素材。
    @discardableResult
    func createProject(named rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { throw ProjectStore.Error.invalidName }
        let destination = ProjectStore.defaultURL(for: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProjectStore.Error.projectExists }
        newProject()
        projectName = name
        try save(to: destination)
        projectListRevision &+= 1
        taskState = .done("已创建项目“\(name)”，接着选择要剪辑的素材")
        return destination
    }

    func promptNewProject() {
        var suggested = "未命名项目"
        var message = "项目保存在 CodeCut 的项目目录里，随时可以回到侧栏继续剪辑；创建完再选素材。"
        while true {
            let alert = NSAlert()
            alert.messageText = "新建项目"
            alert.informativeText = message
            alert.addButton(withTitle: "创建")
            alert.addButton(withTitle: "取消")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "项目名称"
            field.stringValue = suggested
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            suggested = field.stringValue
            do {
                try createProject(named: suggested)
                promptImportVideo()
                return
            } catch {
                message = "\(error.localizedDescription) 换一个名字再试。"
            }
        }
    }

    func promptOpenProject() {
        let panel = NSOpenPanel()
        panel.title = "打开项目"
        panel.prompt = "打开"
        panel.message = "选择 CodeCut 项目（.codecut）"
        panel.allowedContentTypes = [ProjectStore.contentType]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await openProject(url) } catch { taskState = .failed(error.localizedDescription) } }
    }

    func promptImportVideo() {
        let panel = NSOpenPanel()
        panel.title = "导入素材"
        panel.prompt = "导入"
        panel.message = "选择要剪辑的视频"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importVideo(url) }
    }

    func promptRelinkSource() {
        let panel = NSOpenPanel()
        panel.title = "重新定位素材"
        panel.prompt = "重新定位"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await relinkSource(url) }
    }

    // MARK: - B-roll 媒体库

    var isAnalyzingBroll: Bool { brollAnalysisTask != nil }

    /// 搜索框 + 运动方向筛选之后的结果。搜索同时匹配文件名、内容标签和运动描述。
    var visibleBrollAssets: [BrollAsset] {
        let query = brollQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = brollAssets.filter { asset in
            if brollOnlyPendingUnknown, pendingUnknowns(in: asset).isEmpty { return false }
            if let filter = brollMotionFilter, asset.analysis?.motion != filter { return false }
            if let product = brollProductFilter {
                let presence = asset.productPick?.presence ?? .none
                if product == .none { return !asset.hasProduct }
                if presence.rank < product.rank { return false }
            }
            guard !query.isEmpty else { return true }
            if asset.name.lowercased().contains(query) { return true }
            // 认出来的物品也参与搜索：认出“黑色 UL1”之后，搜“黑色”就该找得到这条素材。
            if let inventory = asset.inventory, inventory.items.contains(where: { matches($0, query) }) { return true }
            guard let analysis = asset.analysis else { return false }
            if analysis.motion.rawValue.contains(query) || analysis.energy.rawValue.contains(query) { return true }
            if analysis.zoom.rawValue.contains(query) { return true }
            if analysis.tags.contains(where: { $0.label.lowercased().contains(query) || $0.identifier.lowercased().contains(query) }) { return true }
            if let pick = asset.productPick {
                if pick.summary.lowercased().contains(query) { return true }
                if pick.presence.rawValue.contains(query) { return true }
            }
            return false
        }
        // 挑过产品镜头的按分数从高到低排，选素材时最有用的排最前面；其余保持导入顺序。
        guard brollSortByPick, filtered.contains(where: { $0.productPick != nil }) else { return filtered }
        return filtered.sorted { left, right in
            let l = left.productPick, r = right.productPick
            if (l == nil) != (r == nil) { return l != nil }
            if let l, let r, l.score != r.score { return l.score > r.score }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    var analyzedBrollCount: Int { brollAssets.filter(\.isAnalyzed).count }

    // MARK: - 按产品分组

    /// 按产品把素材分好组。一个分组 = 一款产品（含颜色），只收实拍里认出来的；
    /// 同一素材里出现了两个产品，它就同时进两个分组。
    var brollGroups: [BrollGroup] {
        let catalog = productProfile.products
        var groups: [UUID: BrollGroup] = [:]
        var order: [UUID] = []

        func ensure(_ id: UUID, label: String, sku: String, isManual: Bool) {
            guard groups[id] == nil else { return }
            groups[id] = BrollGroup(id: id, label: label, sku: sku, isManual: isManual)
            order.append(id)
        }
        func add(_ asset: BrollAsset, to id: UUID) {
            guard groups[id]?.assets.contains(where: { $0.id == asset.id }) == false else { return }
            groups[id]?.assets.append(asset)
        }

        for asset in visibleBrollAssets {
            let excluded = Set(asset.excludedFolderIDs)
            // 1) 识别出来的：只算“确实拍到”的产品（一帧主角都没当过的匹配不进文件夹）。
            for item in asset.inventory?.appearances ?? [] {
                guard let productID = item.productID, !excluded.contains(productID) else { continue }
                let known = catalog.first { $0.id == productID }
                ensure(
                    productID,
                    label: item.label.isEmpty ? (known?.shortLabel ?? "未命名产品") : item.label,
                    sku: item.sku.isEmpty ? (known?.sku ?? "") : item.sku,
                    isManual: false
                )
                add(asset, to: productID)
            }
            // 2) 手动拖进去的：模型认不出来的（局部特写、不在 brief 里的对比产品）靠这一步归类。
            for folderID in asset.manualFolderIDs where !excluded.contains(folderID) {
                if let known = catalog.first(where: { $0.id == folderID }) {
                    ensure(folderID, label: known.shortLabel, sku: known.sku, isManual: false)
                } else if let folder = productProfile.customFolders.first(where: { $0.id == folderID }) {
                    ensure(folderID, label: folder.name, sku: "", isManual: true)
                } else {
                    continue
                }
                add(asset, to: folderID)
            }
        }

        // 3) 刚建好、还没有素材的手动文件夹也要显示出来，否则用户不知道建成功了。
        for folder in productProfile.customFolders where groups[folder.id] == nil {
            ensure(folder.id, label: folder.name, sku: "", isManual: true)
        }

        // 顺序：产品分组跟着产品清单走，手动文件夹排在后面、按建立时间。
        let catalogIndex = Dictionary(
            productProfile.products.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let manualIndex = Dictionary(
            productProfile.customFolders.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return order.compactMap { groups[$0] }.sorted { left, right in
            if left.isManual != right.isManual { return !left.isManual }
            if left.isManual {
                return (manualIndex[left.id] ?? 0) < (manualIndex[right.id] ?? 0)
            }
            let leftIndex = catalogIndex[left.id] ?? Int.max
            let rightIndex = catalogIndex[right.id] ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return left.label.localizedStandardCompare(right.label) == .orderedAscending
        }
    }

    // MARK: - 手动归类

    /// 把素材放进文件夹：产品分组（清单里的产品）和手动文件夹都走这一条。
    func assignBrollAssets(_ ids: [UUID], to folderID: UUID) {
        guard !ids.isEmpty else { return }
        for index in brollAssets.indices where ids.contains(brollAssets[index].id) {
            var folders = brollAssets[index].manualFolderIDs
            if !folders.contains(folderID) { folders.append(folderID) }
            brollAssets[index].manualFolders = folders
            // 之前手动从这个文件夹剔除过的话，这次放进来就撤销剔除。
            brollAssets[index].excludedFolders = brollAssets[index].excludedFolderIDs.filter { $0 != folderID }
        }
        markChanged()
        taskState = .done("已把 \(ids.count) 条素材放进「\(brollGroupLabel(folderID))」。")
    }

    /// 从文件夹里拿出来。识别本来就认到的素材会被记成“剔除”，不会下次又冒出来。
    func removeBrollAssets(_ ids: [UUID], from folderID: UUID) {
        guard !ids.isEmpty else { return }
        for index in brollAssets.indices where ids.contains(brollAssets[index].id) {
            brollAssets[index].manualFolders = brollAssets[index].manualFolderIDs.filter { $0 != folderID }
            var excluded = brollAssets[index].excludedFolderIDs
            let recognized = brollAssets[index].inventory?.appearances.contains { $0.productID == folderID } ?? false
            if recognized, !excluded.contains(folderID) { excluded.append(folderID) }
            brollAssets[index].excludedFolders = excluded
        }
        markChanged()
        taskState = .done("已把 \(ids.count) 条素材移出「\(brollGroupLabel(folderID))」。")
    }

    /// 新建手动文件夹（比如"对比产品"）。
    @discardableResult
    func createBrollFolder(named name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            taskState = .failed("文件夹得有个名字。")
            return nil
        }
        if productProfile.customFolders.contains(where: { $0.name == trimmed }) {
            taskState = .failed("已经有叫「\(trimmed)」的文件夹了。")
            return nil
        }
        let folder = BrollFolder(name: trimmed)
        productProfile.folders = productProfile.customFolders + [folder]
        markChanged()
        taskState = .done("已新建文件夹「\(trimmed)」，把素材拖进去就行。")
        return folder.id
    }

    func renameBrollFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var folders = productProfile.customFolders
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        productProfile.folders = folders
        markChanged()
    }

    /// 删掉手动文件夹：只删文件夹，素材本身不动（它们还在左栏的全素材池里）。
    func deleteBrollFolder(_ id: UUID) {
        let folders = productProfile.customFolders
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        productProfile.folders = folders.filter { $0.id != id }
        for index in brollAssets.indices {
            brollAssets[index].manualFolders = brollAssets[index].manualFolderIDs.filter { $0 != id }
            brollAssets[index].excludedFolders = brollAssets[index].excludedFolderIDs.filter { $0 != id }
        }
        markChanged()
        taskState = .done("已删掉文件夹「\(folder.name)」，素材还在左栏。")
    }

    /// 一个分组/文件夹的显示名（提示文案用）。
    func brollGroupLabel(_ id: UUID) -> String {
        if let known = productProfile.products.first(where: { $0.id == id }) { return known.shortLabel }
        if let folder = productProfile.customFolders.first(where: { $0.id == id }) { return folder.name }
        return "文件夹"
    }

    /// 一条产品都没认到的素材条数：这些只出现在左边的全素材池里。
    var brollUngroupedCount: Int {
        // 直接按“有没有落在任何一个文件夹里”算：识别出来又被用户从文件夹里剔除的，
        // 也该算没归入 —— 否则界面上会显示 0 条未归入，实际有一条哪儿都不在。
        let grouped = Set(brollGroups.flatMap { $0.assets.map(\.id) })
        return visibleBrollAssets.filter { !grouped.contains($0.id) }.count
    }

    /// 认过物品的素材条数。
    var scannedBrollCount: Int { brollAssets.filter { $0.inventory != nil }.count }

    /// 模型不认识、你还没确认过的物品：这些才是需要你花时间看的。
    func pendingUnknowns(in asset: BrollAsset) -> [BrollInventoryItem] {
        (asset.inventory?.pending ?? []).filter {
            !productProfile.knownCompetitors.contains($0.label) && !productProfile.knownIgnored.contains($0.label)
        }
    }

    /// 整个库里还有多少件待确认。
    var pendingUnknownBrollCount: Int { brollAssets.reduce(0) { $0 + pendingUnknowns(in: $1).count } }

    /// 一件物品能不能被这个关键词搜到：名字、颜色、SKU、角色都算。
    private func matches(_ item: BrollInventoryItem, _ query: String) -> Bool {
        item.label.lowercased().contains(query)
            || item.color.lowercased().contains(query)
            || item.sku.lowercased().contains(query)
            || item.role.rawValue.contains(query)
            || item.note.lowercased().contains(query)
    }

    /// 登记 B-roll 素材：只记录路径和元数据，不复制、不转码原文件。
    func importBrollAssets(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var added = 0
        var alreadyInLibrary = 0
        var unreadable = 0
        var addedIDs: [UUID] = []
        for url in urls {
            if brollAssets.contains(where: { $0.path == url.path }) { alreadyInLibrary += 1; continue }
            guard let probe = await BrollAnalyzer.probe(url: url) else { unreadable += 1; continue }
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let asset = BrollAsset(
                path: url.path,
                bookmark: bookmark,
                name: url.lastPathComponent,
                duration: probe.duration,
                width: probe.width,
                height: probe.height
            )
            brollAssets.append(asset)
            addedIDs.append(asset.id)
            added += 1
        }
        selectedBrollID = brollAssets.last?.id
        markChanged()
        let skipped = alreadyInLibrary + unreadable
        if added == 0, skipped > 0 {
            // 分开说：已在库里、和读不出来的，是两回事。
            taskState = .failed(unreadable > 0
                ? "这 \(unreadable) 个文件读不出画面（可能不是视频，或者已经损坏）。"
                : "这些文件已经在 B-roll 库里了。")
        } else {
            var note = "已加入 \(added) 条 B-roll 素材"
            if alreadyInLibrary > 0 { note += "，\(alreadyInLibrary) 个已在库里" }
            if unreadable > 0 { note += "，\(unreadable) 个读不出画面" }
            taskState = .done(note + "。")
            if projectURL == nil { messages.append(.init(role: .status, text: "B-roll 素材会随项目一起保存。先在左侧新建项目，这些素材就不会丢。")) }
        }
        // 新素材先只跑本机那一遍（画面内容 + 运动曲线，一条几秒），
        // **认物品那一步不在这里自动跑** —— 它每条要问本地模型 5 次、一条几十秒，
        // 跟"导入"绑在一起会让批量加素材变得很难受。
        // 认物品是单独的一步：左栏会显示"N 条还没认过物品 · 开始批量认"，一次跑完所有没认过的。
        guard !addedIDs.isEmpty else { return }
        await analyzeBroll(ids: addedIDs)
        let pending = brollAssets.filter { $0.inventory == nil }.count
        taskState = .done("已加入 \(added) 条并算好运动曲线。还有 \(pending) 条等着认物品 —— 左栏点“开始批量认”一次跑完。")
    }

    func promptImportBroll() {
        let panel = NSOpenPanel()
        panel.title = "添加 B-roll 素材"
        panel.prompt = "添加"
        panel.message = "可以多选视频，也可以直接选一整个 B-roll 文件夹"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        var urls: [URL] = []
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                urls.append(contentsOf: Self.videoFiles(in: url))
            } else {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { taskState = .failed("这个文件夹里没有找到可用的视频文件。"); return }
        Task { await importBrollAssets(urls) }
    }

    /// 拖进来的一批文件 / 文件夹。
    /// 和“添加素材”对话框同一个规则：文件夹递归扫视频，只收能播的扩展名。
    func addBrollAssetsFromDrop(_ urls: [URL]) async {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                files.append(contentsOf: Self.videoFiles(in: url))
            } else if BrollAnalyzer.supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        guard !files.isEmpty else {
            taskState = .failed("拖进来的东西里没有可用的视频文件。")
            return
        }
        await importBrollAssets(files)
    }

    /// 允许整目录导入时递归扫描；相机卡里 B-roll 常常分层存放。
    private static func videoFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where BrollAnalyzer.supportedExtensions.contains(url.pathExtension.lowercased()) {
            found.append(url)
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 本地 Vision 识别：一次跑一批，逐条写回结果，可以随时取消。
    func analyzeBroll(ids: [UUID]) async {
        guard brollAnalysisTask == nil else { return }
        let targets = brollAssets.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        brollAnalysisProgress = 0
        taskState = .working("本机正在算 \(targets.count) 条素材的运动曲线…")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var done = 0
            for asset in targets {
                if Task.isCancelled { break }
                if let analysis = try? await BrollAnalyzer.analyze(url: URL(fileURLWithPath: asset.path)),
                   let index = brollAssets.firstIndex(where: { $0.id == asset.id }) {
                    // 只补内容识别这一层，不能把已经认出来的物品清单冲掉 ——
                    // 两条管线是分开跑的，谁后跑都不该抹掉另一条的结果。
                    var merged = analysis
                    merged.product = brollAssets[index].analysis?.product
                    brollAssets[index].analysis = merged
                    // 曲线重算了，可用片段也跟着重新切：对不上新片段的旧调整丢掉，
                    // 别在项目文件里越攒越多。
                    pruneBrollSegmentEdits(at: index)
                }
                done += 1
                brollAnalysisProgress = Double(done) / Double(targets.count)
                taskState = .working("正在算运动曲线 \(done)/\(targets.count)…")
            }
            brollAnalysisProgress = nil
            brollAnalysisTask = nil
            markChanged()
            taskState = Task.isCancelled
                ? .done("已取消，保留了前 \(done) 条的运动曲线。")
                : .done("算完 \(done) 条素材的运动曲线。")
        }
        brollAnalysisTask = task
        await task.value
    }

    func cancelBrollAnalysis() { brollAnalysisTask?.cancel() }

    private func pruneBrollSegmentEdits(at index: Int) {
        guard let edits = brollAssets[index].segmentEdits, !edits.isEmpty else { return }
        let live = Set(brollAssets[index].usableSegments.map(\.id))
        let kept = edits.filter { live.contains($0.key) }
        brollAssets[index].segmentEdits = kept.isEmpty ? nil : kept
    }

    /// 从识别结果跳到某一刻：预览面板会跟着 seek，方便核对“认出来的东西”是不是真在那一帧。
    func previewBrollMoment(_ time: Double) {
        guard let id = selectedBrollID else { return }
        brollPreviewRequest = BrollPreviewRequest(assetID: id, time: max(0, time))
    }

    /// 预览一整段可用片段：从入点播到出点，到了自动停。
    /// 剪辑时一段一段看比拖着进度条找稳不稳快得多。
    func playBrollSegment(_ assetID: UUID, _ segment: BrollUsableSegment) {
        brollPreviewRequest = BrollPreviewRequest(
            assetID: assetID,
            time: max(0, segment.start),
            stopAt: max(segment.start, segment.end)
        )
    }

    // MARK: - 可用片段的手动标记

    /// 把这一段的入点或出点设成某个时刻（一般是预览里画面停住的那一刻）。
    /// 传 nil 就是还原成识别切出来的位置。
    func setBrollSegmentBoundary(_ assetID: UUID, segmentID: String, isStart: Bool, time: Double?) {
        updateBrollSegmentEdit(assetID, segmentID: segmentID) { edit in
            let value = time.map { max(0, $0) }
            if isStart { edit.start = value } else { edit.end = value }
        }
    }

    /// 勾选“这段可以用”。后面接分镜表时先看勾过的段。
    func setBrollSegmentApproved(_ assetID: UUID, segmentID: String, approved: Bool) {
        updateBrollSegmentEdit(assetID, segmentID: segmentID) { $0.approved = approved }
    }

    /// 还原这一段：出入点回到识别切出来的位置，勾选也一起清掉。
    func clearBrollSegmentEdit(_ assetID: UUID, segmentID: String) {
        guard let index = brollAssets.firstIndex(where: { $0.id == assetID }),
              brollAssets[index].segmentEdits?[segmentID] != nil else { return }
        brollAssets[index].segmentEdits?[segmentID] = nil
        if brollAssets[index].segmentEdits?.isEmpty == true { brollAssets[index].segmentEdits = nil }
        markChanged()
    }

    private func updateBrollSegmentEdit(_ assetID: UUID, segmentID: String, _ change: (inout BrollSegmentEdit) -> Void) {
        guard let index = brollAssets.firstIndex(where: { $0.id == assetID }) else { return }
        var edits = brollAssets[index].segmentEdits ?? [:]
        var edit = edits[segmentID] ?? BrollSegmentEdit()
        change(&edit)
        edits[segmentID] = edit.isEmpty ? nil : edit
        brollAssets[index].segmentEdits = edits.isEmpty ? nil : edits
        markChanged()
    }

    // MARK: - 选择

    /// 点选 / ⌘ 点选 / ⇧ 范围选。选中的一批就是拖进文件夹的那一批。
    func selectBroll(_ id: UUID, extend: Bool, range: Bool = false) {
        selectedBrollID = id
        let visible = visibleBrollAssets.map(\.id)
        // ⇧ 点选：从锚点拉一段（列表里看到的顺序，也就是筛选和排序之后的结果）。
        if range, let anchor = brollSelectionAnchor,
           let anchorIndex = visible.firstIndex(of: anchor),
           let targetIndex = visible.firstIndex(of: id) {
            let bounds = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            brollSelection = Set(visible[bounds])
            return
        }
        brollSelectionAnchor = id
        guard extend else {
            brollSelection = [id]
            return
        }
        if brollSelection.contains(id) { brollSelection.remove(id) } else { brollSelection.insert(id) }
        // ⌘ 点到自己取消后，别让那一批空着。
        if !brollSelection.contains(id), let first = brollSelection.first { selectedBrollID = first }
    }

    /// 这条素材归属的文件夹（识别到的 + 手动放进去的），按分组顺序。
    func brollFolders(of asset: BrollAsset) -> [(name: String, manual: Bool)] {
        brollGroups.filter { group in group.assets.contains { $0.id == asset.id } }
            .map { (name: $0.label, manual: $0.isManual) }
    }

    /// 选中那一批素材（保持素材列表本身的顺序）。
    var brollSelectedAssets: [BrollAsset] {
        brollAssets.filter { brollSelection.contains($0.id) }
    }

    /// 缩略图按需生成并缓存在内存里，列表滚到哪生成到哪。
    func ensureBrollThumbnail(_ id: UUID) async {
        guard brollThumbnails[id] == nil,
              let asset = brollAssets.first(where: { $0.id == id }) else { return }
        guard let image = await BrollAnalyzer.thumbnail(url: URL(fileURLWithPath: asset.path)) else { return }
        brollThumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func removeBrollAssets(_ ids: [UUID]) {
        brollAssets.removeAll { ids.contains($0.id) }
        for id in ids { brollThumbnails[id] = nil }
        if let selected = selectedBrollID, ids.contains(selected) { selectedBrollID = brollAssets.first?.id }
        markChanged()
    }

    /// 只把素材移出库，不碰硬盘上的原文件。
    func revealBrollInFinder(_ id: UUID) {
        guard let asset = brollAssets.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)])
    }

    // MARK: - 产品档案（本地视觉模型的判断依据）

    var isPreparingLocalModel: Bool { localModelTask != nil }
    var isAnalyzingBrollProduct: Bool { brollProductTask != nil }

    /// 当前选用的本机视觉模型。
    var localModelChoice: LocalVLM.Model { LocalVLM.selectedModel }

    /// 切换本机视觉模型。换完要重新检查状态：另一个模型可能还没下载，服务也要重起。
    func selectLocalModel(_ choice: LocalVLM.Model) {
        guard choice != LocalVLM.selectedModel else { return }
        LocalVLM.selectedModel = choice
        localModelState = .unknown
        localModelNotice = "已切到 \(choice.displayName)：\(choice.note)"
        Task { await refreshLocalModel() }
    }
    /// 已经挑过产品镜头的素材条数。
    var pickedBrollCount: Int { brollAssets.filter { $0.productPick != nil }.count }
    /// 其中真的拍到产品的条数。
    var productBrollCount: Int { brollAssets.filter(\.hasProduct).count }

    func refreshLocalModel() async {
        localModelState = await LocalVLM.currentState()
    }

    /// 下载运行时和模型权重，然后把本地服务拉起来。只做一次。
    func prepareLocalModel() async {
        guard localModelTask == nil else { return }
        localModelNotice = "正在准备本地模型…"
        localModelState = .checking
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await LocalVLM.prepare { fraction, text in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.localModelNotice = text
                        if case .runtimeMissing = self.localModelState { self.localModelState = .checking }
                        else if fraction < 0.95 { self.localModelState = .modelFilesMissing(fraction) }
                    }
                }
                localModelState = state
                localModelNotice = "本地模型已就绪，可以开始挑产品镜头了。"
            } catch is CancellationError {
                localModelNotice = "已取消本地模型的准备。"
                localModelState = await LocalVLM.currentState()
            } catch {
                localModelState = .failed(error.localizedDescription)
                localModelNotice = error.localizedDescription
            }
            localModelTask = nil
        }
        localModelTask = task
        await task.value
    }

    func cancelLocalModelPreparation() { localModelTask?.cancel() }

    /// 读品牌 brief，生成本项目的产品档案：产品是什么、长什么样、哪几张图能当参考图。
    /// brief 是 PDF、Word、PPT、图片还是纯文本都行。
    func promptProductBrief() {
        let panel = NSOpenPanel()
        panel.title = "选择产品 brief"
        panel.prompt = "读取"
        panel.message = "选品牌方给的 brief。PDF、Word、PPT、图片、纯文本都行，本地模型会读完它，弄清楚这次要展示的是什么产品。"
        panel.allowedContentTypes = BriefFormat.pickableTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await buildProductProfile(from: url) }
    }

    func buildProductProfile(from url: URL) async {
        // 状态可能只是“还没查过”，也可能只是本地服务没起来 —— 读 brief 前先自己确认一次，
        // 别让用户在文稿页读到一半被赶去别的页面点“准备本地模型”。
        if !localModelState.isReady {
            localModelState = .checking
            await refreshLocalModel()
            if case .serverDown = localModelState { await prepareLocalModel() }
        }
        guard localModelState.isReady else {
            taskState = .failed("本地模型还没就绪（\(localModelState.label)）。先点“准备本地模型”，装好之后才能读 brief。")
            return
        }
        guard brollProductTask == nil else { return }
        brollProductNotice = "正在读 \(BriefFormat(url: url).label) 文件…"
        brollProductProgress = 0
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 先把原文件读成「文字 + 提出来的图 + 一份能看的 PDF」：
                // 左栏那半边马上就有东西看，不用等模型读完。
                let source = try BriefSourceReader.read(url)
                let preview = storeBriefPreview(source, from: url)
                var staged = productProfile
                staged.briefPath = url.path
                staged.previewPath = preview?.path
                productProfile = staged
                markChanged()

                let result = try await ProductBriefReader.buildProfile(from: source) { fraction, text in
                    Task { @MainActor [weak self] in
                        self?.brollProductProgress = fraction
                        self?.brollProductNotice = text
                    }
                }
                var profile = result.profile
                profile.previewPath = preview?.path
                productProfile = profile
                productReferenceThumbnails = [:]
                markChanged()
                taskState = .done("产品档案已生成：\(result.profile.name)。接下来点“AI 挑产品镜头”，本机会逐条判断哪一段最适合展示它。")
            } catch {
                taskState = .failed("读 brief 失败：\(error.localizedDescription)")
            }
            brollProductProgress = nil
            brollProductNotice = ""
            brollProductTask = nil
        }
        brollProductTask = task
        await task.value
    }

    /// 文稿页左栏要显示的原文件预览。
    var briefPreviewURL: URL? {
        let candidates = [productProfile.previewPath, productProfile.briefPath]
        for path in candidates.compactMap({ $0 }) where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 把 brief 的预览 PDF 存到本机缓存：同一个文件重复读覆盖同一份，不会越攒越多。
    private func storeBriefPreview(_ source: BriefSource, from url: URL) -> URL? {
        // PDF 的原文件本身就是可预览的 PDF，直接指回去，不用白拷一份几十兆的副本。
        if source.previewPDF.path == url.path { return url }
        let folder = LocalVLM.supportDirectory.appending(path: "BriefPreviews", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destination = folder.appending(path: "\(String(base.prefix(40)))-\(fingerprint(url.path)).pdf")
        if source.previewPDF.path != destination.path {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source.previewPDF, to: destination)
        }
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    /// 路径的稳定指纹（FNV-1a）：同一条 brief 每次都落到同一个文件名。
    private func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// 手动补参考图：brief 里没有合适的产品图，或者想加自己拍的产品照时用。
    func promptProductReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "添加产品参考图"
        panel.prompt = "添加"
        panel.message = "选几张能看清产品本体的照片或截图。参考图越清楚，识别越准。"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added: [ProductReferenceImage] = []
        for url in panel.urls {
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            added.append(ProductReferenceImage(path: url.path, caption: url.deletingPathExtension().lastPathComponent, bookmark: bookmark))
        }
        productProfile.referenceImages.append(contentsOf: added)
        markChanged()
        taskState = .done("已加入 \(added.count) 张产品参考图。")
    }

    func removeProductReference(_ id: UUID) {
        productProfile.referenceImages.removeAll { $0.id == id }
        productReferenceThumbnails[id] = nil
        markChanged()
    }

    /// 参考图缩略图按需生成。
    func ensureReferenceThumbnail(_ id: UUID) async {
        guard productReferenceThumbnails[id] == nil,
              let reference = productProfile.referenceImages.first(where: { $0.id == id }) else { return }
        guard let image = NSImage(contentsOfFile: reference.path) else { return }
        productReferenceThumbnails[id] = image
    }

    /// 让本地视觉模型逐条认：这条素材里有哪些东西、哪一件是清单里的产品、哪一段最适合展示它。
    /// 没有产品档案时也能跑 —— 那就只列画面里的物品，认不出是哪一款产品。
    func analyzeBrollProducts(ids: [UUID]) async {
        guard brollProductTask == nil else { return }
        guard localModelState.isReady else {
            taskState = .failed("本地模型还没就绪，先点“准备本地模型”。")
            return
        }
        let targets = brollAssets.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }

        // 候选清单和参考图只读一次，整个批次复用。没有产品档案时是空的，这次就只列物品。
        let candidates = ProductPicker.candidates(for: productProfile)
        brollProductProgress = 0
        taskState = .working("本地模型正在认画面物品 0/\(targets.count)…")

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var done = 0
            var hit = 0
            var failed = 0
            var calls = 0
            var callSeconds = 0.0
            for asset in targets {
                if Task.isCancelled { break }
                brollProductNotice = "正在看 \(asset.name)…"
                let started = Date()
                if var pick = try? await ProductPicker.analyze(
                    path: asset.path,
                    duration: asset.duration,
                    profile: productProfile,
                    candidates: candidates,
                    sampleCount: brollScanMode.rawValue,
                    // 帧数就是调用次数，一条素材可能要跑一会儿：把进度显示出来，
                    // 不然界面看起来像是卡住了。
                    progress: { fraction in
                        Task { @MainActor [weak self] in
                            self?.brollProductNotice = "正在看 \(asset.name)… \(Int(min(max(fraction, 0), 1) * 100))%"
                        }
                    }
                ), let index = brollAssets.firstIndex(where: { $0.id == asset.id }) {
                    // 记下实测速度：下次用户能看到"这一批大概要多久"。
                    if pick.sampledCount > 0 {
                        calls += pick.sampledCount
                        callSeconds += Date().timeIntervalSince(started)
                        brollSecondsPerCall = callSeconds / Double(calls)
                    }
                    pick.hasTarget = !candidates.isEmpty
                    brollAssets[index].analysis?.product = pick
                    if brollAssets[index].productPick == nil {
                        // 素材还没跑过 Vision 识别：单独补一个空壳，只放产品结论。
                        brollAssets[index].analysis = BrollAnalysis(product: pick)
                    }
                    if pick.containsProduct { hit += 1 }
                } else {
                    // 单条失败不能让整批看起来像是成功了。
                    failed += 1
                }
                done += 1
                brollProductProgress = Double(done) / Double(targets.count)
                taskState = .working("本地模型正在认画面物品 \(done)/\(targets.count)…")
            }
            brollProductNotice = ""
            brollProductProgress = nil
            brollProductTask = nil
            markChanged()
            let succeeded = done - failed
            let summary = candidates.isEmpty
                ? "认完了：\(succeeded) 条素材的物品清单已生成。读了 brief 之后还能认出是哪一款产品。"
                : "认完了：\(succeeded) 条里 \(hit) 条拍到了产品。"
            taskState = Task.isCancelled
                ? .done("已取消，保留前 \(done) 条的识别结果。")
                : .done(failed == 0
                        ? summary
                        : "\(summary)有 \(failed) 条没认成功——本地模型没给出结果，检查一下模型是否还在运行，再挑这几条重跑。")
        }
        brollProductTask = task
        await task.value
    }

    func cancelBrollProductAnalysis() { brollProductTask?.cancel() }

    /// 把挑中的片段写进分镜表，后面按分镜表剪就行。
    func addBrollPickToStoryboard(_ id: UUID) {
        guard let asset = brollAssets.first(where: { $0.id == id }), let pick = asset.productPick else { return }
        // 只有真的挑到“能用的片段”才写分镜：没拍到产品、或者片段太短的，写进去只会让人白剪一次。
        guard pick.isUsable else {
            taskState = .failed(pick.containsProduct ? "这条素材的产品片段太短，先换一条更稳的。" : "这条素材没拍到产品，没法当产品镜头用。")
            return
        }
        let tags = asset.analysis?.tags.prefix(3).map(\.label).joined(separator: "、") ?? ""
        let movement = asset.analysis?.motion.rawValue ?? ""
        let item = StoryboardItem(
            kind: .liveAction,
            wordIDs: [],
            fallbackStart: 0,
            fallbackEnd: pick.duration,
            description: pick.summary.isEmpty ? "产品镜头：\(asset.name)" : pick.summary,
            composition: tags,
            cameraMovement: movement,
            elements: "B-roll \(asset.name) \(pick.timecodeRange)",
            notes: pick.reasons.joined(separator: " "),
            brollPath: asset.path,
            brollStart: pick.start,
            brollEnd: pick.end
        )
        storyboards.append(item)
        selectedStoryboardID = item.id
        markChanged()
        taskState = .done("已把 \(asset.name) 的 \(pick.timecodeRange) 加进分镜表。")
    }

    func save(to url: URL? = nil) throws {
        let destination = url ?? projectURL ?? ProjectStore.defaultURL(for: projectName)
        let bookmark = try videoURL?.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let document = ProjectDocument(name: projectName, sourcePath: videoURL?.path ?? "", sourceBookmark: bookmark, transcript: words.isEmpty ? nil : .init(assetID: videoURL?.lastPathComponent ?? "", duration: duration, words: words), suggestions: suggestions, breaths: breaths, breathMode: breathMode, dedupeMode: dedupeMode, pausePlan: pausePlan, edgeTrim: edgeTrim, frameRate: frameRate, manuscript: manuscript, messages: messages, subtitleBreaks: Array(subtitleBreaks), subtitleJoins: Array(subtitleJoins), trimStart: trimStart, trimEnd: effectiveTrimEnd, sourceDuration: duration, burnSubtitles: burnSubtitles, subtitleFontSize: subtitleFontSize, playhead: currentTime, storyboards: storyboards, storyboardScript: storyboardScript.isEmpty ? nil : storyboardScript, scriptTable: scriptTable.isEmpty ? nil : scriptTable, brollAssets: brollAssets, brollPlacements: brollPlacements.isEmpty ? nil : brollPlacements, productProfile: productProfile.hasContent ? productProfile : nil)
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
        projectURL = url; projectName = document.name; frameRate = document.frameRate; suggestions = document.suggestions; breaths = document.breaths; breathMode = document.breathMode; dedupeMode = document.dedupeMode ?? .confirm; pausePlan = document.pausePlan ?? .standard; edgeTrim = document.edgeTrim ?? .trim
        words = document.transcript?.words ?? []; duration = document.sourceDuration ?? document.transcript?.duration ?? 0
        trimStart = document.trimStart ?? 0; trimEnd = document.trimEnd ?? duration
        burnSubtitles = document.burnSubtitles ?? true; subtitleFontSize = document.subtitleFontSize ?? 48
        currentTime = min(duration, max(0, document.playhead ?? trimStart))
        subtitleBreaks = Set(document.subtitleBreaks ?? [])
        subtitleJoins = Set(document.subtitleJoins ?? [])
        manuscript = document.manuscript ?? ""
        storyboardScript = document.storyboardScript ?? ""
        scriptTable = document.scriptTable ?? ScriptTable()
        // 老项目：分镜稿还贴在文本框里，第一次打开时搬进表格，内容不丢。
        if scriptTable.isEmpty {
            let legacy = (document.storyboardScript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty { scriptTable = ScriptTableCSV.table(fromPlainText: legacy) }
        }
        scriptTable.normalize()
        // 换了项目，时间列要按这个项目的口播重新对一次。
        scriptTimeFingerprint = ""
        messages = document.messages ?? [.init(role: .assistant, text: "已打开项目“\(document.name)”。")]
        storyboards = document.storyboards ?? []
        selectedStoryboardID = nil; storyboardSelectedWordIDs = []; storyboardSelectionAnchorID = nil
        brollAssets = document.brollAssets ?? []
        brollPlacements = document.brollPlacements ?? []
        selectedBrollID = brollAssets.first?.id; brollThumbnails = [:]
        productProfile = document.productProfile ?? ProductProfile()
        productReferenceThumbnails = [:]; brollProductProgress = nil; brollProductNotice = ""
        brollProductFilter = nil; brollSortByPick = true
        undoStack = []; redoStack = []; hasUnsavedChanges = false
        guard !document.sourcePath.isEmpty else {
            // 只建了项目、还没导入素材：停在空状态，不要提示重新定位。
            taskState = .idle
            return
        }
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

    func autosave() {
        // 项目主导的工作流里“只建了项目、还没导入素材”也是合法状态，所以只要有项目就落盘。
        guard !isRestoringProject, hasUnsavedChanges, videoURL != nil || projectURL != nil else { return }
        try? save()
    }

    func updateManuscript(_ text: String) { manuscript = text; hasUnsavedChanges = true; autosave() }
    func updateStoryboardScript(_ text: String) { storyboardScript = text; hasUnsavedChanges = true; autosave() }
    // MARK: - 分镜稿表格

    /// 选一个 CSV 导进来当分镜稿。
    func promptImportScriptTable() {
        let panel = NSOpenPanel()
        panel.title = "导入分镜稿"
        panel.prompt = "导入"
        panel.message = "选分镜稿的 CSV（第一行当表头）。导入后可以直接在表格里改内容、调列宽和行高。"
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try loadScriptTable(from: url)
            let count = scriptTable.rowCount
            taskState = .done("已导入分镜稿 \(url.lastPathComponent)：\(count) 行 × \(scriptTable.columnCount) 列。")
        } catch {
            taskState = .failed("分镜稿导入失败：\(error.localizedDescription)")
        }
    }

    func loadScriptTable(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table = ScriptTableCSV.table(fromCSV: text)
        // UTF-8 读出来是空的（有些 Excel 导的是 GB18030 一类），换一种编码再试一次。
        if table.isEmpty, let fallback = try? String(contentsOf: url, encoding: .isoLatin1) {
            table = ScriptTableCSV.table(fromCSV: fallback)
        }
        table.sourcePath = url.path
        applyScriptTable(table)
    }

    func applyScriptTable(_ table: ScriptTable) {
        scriptTable = table
        scriptTable.normalize()
        // 换了一份分镜稿就重新对一次时间。
        scriptTimeFingerprint = ""
        // 老项目里贴在文本框里的分镜稿已经搬进表格了，清掉免得两处内容不一致。
        storyboardScript = ""
        markChanged()
    }

    func exportScriptTable() {
        guard !scriptTable.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出分镜稿"
        panel.nameFieldStringValue = "\(projectName)-分镜稿.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScriptTableCSV.csv(from: scriptTable).write(to: url, atomically: true, encoding: .utf8)
            taskState = .done("已导出 \(url.lastPathComponent)。")
        } catch {
            taskState = .failed("分镜稿导出失败：\(error.localizedDescription)")
        }
    }

    /// 单元格改字：和文字稿一样逐字落盘，改到一半也不会丢。
    func updateScriptCell(row: Int, column: Int, text: String) {
        guard row >= 0, row < scriptTable.rows.count, column >= 0, column < scriptTable.columnCount else { return }
        scriptTable.normalize()
        scriptTable.rows[row][column] = text
        // 手改「时间」列就当成用户自己的时间：以后不自动刷新它，避免把人工核准过的值冲掉。
        if column == scriptTimeColumn { scriptTable.timeColumnSignature = nil }
        markChanged()
    }

    func setScriptColumnWidth(_ width: Double, at column: Int) {
        guard column >= 0, column < scriptTable.columnCount else { return }
        scriptTable.normalize()
        scriptTable.columnWidths[column] = min(ScriptTable.maximumColumnWidth, max(ScriptTable.minimumColumnWidth, width))
        hasUnsavedChanges = true
    }

    func setScriptRowHeight(_ height: Double, at row: Int) {
        guard row >= 0, row < scriptTable.rows.count else { return }
        scriptTable.normalize()
        scriptTable.rowHeights[row] = min(ScriptTable.maximumRowHeight, max(ScriptTable.minimumRowHeight, height))
        hasUnsavedChanges = true
    }

    /// 拖完列宽／行高再落盘：拖动过程中每一帧都写文件没有意义。
    func commitScriptTable() { markChanged() }

    func addScriptRow(after row: Int? = nil) {
        scriptTable.normalize()
        let blank = Array(repeating: "", count: max(1, scriptTable.columnCount))
        let index = (row.map { min(scriptTable.rows.count, $0 + 1) }) ?? scriptTable.rows.count
        scriptTable.rows.insert(blank, at: index)
        scriptTable.rowHeights.insert(ScriptTable.defaultRowHeight, at: min(index, scriptTable.rowHeights.count))
        markChanged()
    }

    func removeScriptRow(_ row: Int) {
        guard row >= 0, row < scriptTable.rows.count else { return }
        scriptTable.rows.remove(at: row)
        if row < scriptTable.rowHeights.count { scriptTable.rowHeights.remove(at: row) }
        markChanged()
    }

    func addScriptColumn() {
        scriptTable.normalize()
        scriptTable.headers.append("第 \(scriptTable.columnCount + 1) 列")
        for index in scriptTable.rows.indices { scriptTable.rows[index].append("") }
        scriptTable.columnWidths.append(ScriptTable.defaultColumnWidth)
        markChanged()
    }

    func insertScriptColumn(after column: Int) {
        scriptTable.normalize()
        let index = min(scriptTable.columnCount, max(0, column + 1))
        scriptTable.headers.insert("第 \(scriptTable.columnCount + 1) 列", at: index)
        for row in scriptTable.rows.indices { scriptTable.rows[row].insert("", at: index) }
        scriptTable.columnWidths.insert(ScriptTable.defaultColumnWidth, at: min(index, scriptTable.columnWidths.count))
        markChanged()
    }

    func updateScriptHeader(column: Int, text: String) {
        guard column >= 0, column < scriptTable.columnCount else { return }
        scriptTable.normalize()
        scriptTable.headers[column] = text
        markChanged()
    }

    func removeScriptColumn(_ column: Int) {
        scriptTable.normalize()
        guard scriptTable.columnCount > 1, column >= 0, column < scriptTable.columnCount else { return }
        scriptTable.headers.remove(at: column)
        for index in scriptTable.rows.indices { scriptTable.rows[index].remove(at: column) }
        if column < scriptTable.columnWidths.count { scriptTable.columnWidths.remove(at: column) }
        markChanged()
    }

    // MARK: - 分镜稿 × 口播时间

    /// 「时间」列的表头。分镜稿里它永远紧跟「文稿」那一列。
    static let scriptTimeColumnHeader = "时间"

    /// 表格里已有的「时间」列。手写的、导入的也算，位置不对会在对齐时挪到「文稿」后面。
    var scriptTimeColumn: Int? {
        scriptTable.headers.firstIndex { $0.trimmingCharacters(in: .whitespaces).contains(Self.scriptTimeColumnHeader) }
    }

    /// 口播指纹：文字稿和剪辑（删词、删气口、掐头尾）一变指纹就变，用来判断时间列要不要重新对一次。
    /// 这里刻意不碰 `deletedRanges`（它要排序），视图每次重画都会取这个值。
    var scriptVoiceFingerprint: String {
        let deletedWords = words.reduce(0) { $0 + ($1.isDeleted ? 1 : 0) }
        let deletedBreaths = breaths.reduce(0) { $0 + ($1.state == .deleted ? 1 : 0) }
        // 头尾时间也进指纹：重新转写后词数可能一样，但时间是新的。
        let head = Int((words.first?.start ?? 0) * 10), tail = Int((words.last?.end ?? 0) * 10)
        return "\(words.count)-\(deletedWords)-\(head)-\(tail)-\(breaths.count)-\(deletedBreaths)-\(pausePlan.rawValue)-\(edgeTrim.rawValue)-\(Int(trimStart * 10))-\(Int(effectiveTrimEnd * 10))"
    }

    /// 自动对齐只写「我们自己生成的时间列」：还没这一列、这一列还空着、或者上一次就是我们对的。
    /// 用户导入或手写、并且已经有内容的时间列没有签名，自动对齐不碰它；想重算点工具栏按钮即可。
    private var canAutoFillScriptTimeColumn: Bool {
        guard let column = scriptTimeColumn else { return true }
        let hasValue = scriptTable.rows.indices.contains { !scriptTable.cell($0, column).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasValue else { return true }
        return scriptTable.timeColumnSignature != nil
    }

    /// 已经有「时间」列时，口播或剪辑变了就自动重对一次，省得时间停在旧稿上。
    /// 没有这一列时不动手（列由按钮生成）；用户自己写的这一列也不动。
    func autoMatchScriptTimesIfNeeded() async {
        guard !scriptTable.isEmpty, !words.isEmpty, !isWorking else { return }
        // 「时间」列只由按钮生成：没有这一列时不动手，免得往分镜稿里塞用户没要的列。
        guard scriptTimeColumn != nil else { return }
        guard scriptTimeFingerprint != scriptVoiceFingerprint else { return }
        guard canAutoFillScriptTimeColumn else { return }
        await matchScriptTableTimes()
    }

    /// 按分镜稿的「文稿」列把口播时间对进「时间」列：口播里没有的行留空。
    @discardableResult
    func matchScriptTableTimes() async -> Int {
        guard !scriptTable.isEmpty else { taskState = .failed("还没有分镜稿可以对时间。"); return 0 }
        let spoken = words.filter { !$0.isDeleted }
        guard !spoken.isEmpty else { taskState = .failed("还没有口播文字稿，先转写素材再对时间。"); return 0 }

        // 先把「时间」列挪到「文稿」后面，再取文稿列的下标：挪列会让下标变化，顺序反了会读错列。
        let timeColumn = ensureScriptTimeColumn(after: scriptTable.scriptColumn)
        let scriptColumn = scriptTable.scriptColumn
        let scripts = scriptTable.rows.indices.map { scriptTable.cell($0, scriptColumn) }
        // 时间是成片时间：删掉的段落已经扣掉，和分镜时间轴、字幕轨道是同一套时间。
        let deleted = deletedRanges
        let input = ScriptTimeMatcher.Input(words: spoken.map {
            .init(
                text: $0.text,
                start: TimelineEngine.outputTime(for: $0.start, deleted: deleted),
                end: TimelineEngine.outputTime(for: $0.end, deleted: deleted)
            )
        })
        taskState = .working("正在按口播对齐分镜时间…")
        let matches = await Task.detached(priority: .userInitiated) {
            ScriptTimeMatcher.matchAll(scripts: scripts, input: input)
        }.value

        scriptTable.normalize()
        var matched = 0
        for row in scriptTable.rows.indices where row < matches.count {
            let text = matches[row].map(ScriptTimeMatcher.timeText) ?? ""
            scriptTable.rows[row][timeColumn] = text
            if !text.isEmpty { matched += 1 }
        }
        scriptTimeFingerprint = scriptVoiceFingerprint
        scriptTable.timeColumnSignature = scriptVoiceFingerprint
        markChanged()
        let total = scriptTable.rowCount
        taskState = .done(matched == total
            ? "已按口播对齐 \(total) 行时间"
            : "已对齐 \(matched)/\(total) 行时间，其余 \(total - matched) 行口播里没有对应内容（留空）")
        return matched
    }

    /// 「时间」列永远紧跟「文稿」列：没有就插一个，位置不对就搬过来，列宽跟着一起搬。
    private func ensureScriptTimeColumn(after scriptColumn: Int) -> Int {
        scriptTable.normalize()
        if let existing = scriptTimeColumn {
            guard existing != scriptColumn + 1 else { return existing }
            let width = existing < scriptTable.columnWidths.count ? scriptTable.columnWidths[existing] : ScriptTimeMatcher.defaultColumnWidth
            scriptTable.headers.remove(at: existing)
            for index in scriptTable.rows.indices { scriptTable.rows[index].remove(at: existing) }
            if existing < scriptTable.columnWidths.count { scriptTable.columnWidths.remove(at: existing) }
            // 挪列会把文稿列的下标顶走一格，插之前重新认一次。
            let index = min(scriptTable.columnCount, max(0, scriptTable.scriptColumn + 1))
            scriptTable.headers.insert(Self.scriptTimeColumnHeader, at: index)
            for row in scriptTable.rows.indices { scriptTable.rows[row].insert("", at: index) }
            scriptTable.columnWidths.insert(width, at: min(index, scriptTable.columnWidths.count))
            return index
        }
        let index = min(scriptTable.columnCount, max(0, scriptColumn + 1))
        scriptTable.headers.insert(Self.scriptTimeColumnHeader, at: index)
        for row in scriptTable.rows.indices { scriptTable.rows[row].insert("", at: index) }
        scriptTable.columnWidths.insert(ScriptTimeMatcher.defaultColumnWidth, at: min(index, scriptTable.columnWidths.count))
        return index
    }

    // MARK: - 分镜稿 × B-roll 排片

    /// 排片用的一行分镜：台词、镜头类型、分镜备注，以及这句台词在成片里的起止时间。
    struct BrollStoryboardRow: Sendable, Equatable {
        var row: Int
        var script: String
        var shot: String
        var note: String
        var start: Double
        var end: Double
        /// 这一镜标注了要用库外素材（未拍摄 / 网络素材）：不由本地 B-roll 库补。
        var external = false
    }

    /// 能排片的分镜行：台词不空、时间列读得回来（也就是口播里确实说了这一句）。
    var brollStoryboardRows: [BrollStoryboardRow] {
        guard !scriptTable.isEmpty, let timeColumn = scriptTimeColumn else { return [] }
        let scriptColumn = scriptTable.scriptColumn
        let shotColumn = scriptTable.column(matching: ["镜头类型", "景别", "镜头"])
        let noteColumn = scriptTable.column(matching: ["分镜", "画面", "备注"])
        let shotColumn2 = scriptTable.column(matching: ["是否拍摄", "拍摄"])
        return scriptTable.rows.indices.compactMap { row -> BrollStoryboardRow? in
            let script = scriptCell(row, scriptColumn)
            guard !script.isEmpty, let range = ScriptTimeMatcher.timeRange(scriptTable.cell(row, timeColumn)) else { return nil }
            let shot = scriptCell(row, shotColumn), note = scriptCell(row, noteColumn)
            let marks = scriptCell(row, shotColumn2) + shot + note
            let external = ["未拍摄", "网络素材", "网图", "素材网站", "版权素材"].contains { marks.contains($0) }
            return BrollStoryboardRow(row: row, script: script, shot: shot, note: note, start: range.start, end: range.end, external: external)
        }
    }

    /// 表格里某一格的内容（列不存在时算空）。
    private func scriptCell(_ row: Int, _ column: Int?) -> String {
        guard let column else { return "" }
        return scriptTable.cell(row, column).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 已排好的片段按轨道分组：时间轴上一条轨道一段，用来画多轨。
    var brollPlacementTracks: [[BrollPlacement]] {
        guard !brollPlacements.isEmpty else { return [] }
        let count = brollPlacements.map(\.track).max() ?? 1
        return (1...max(1, count)).map { track in
            brollPlacements.filter { $0.track == track }.sorted { $0.start < $1.start }
        }
    }

    /// 按分镜稿的「镜头类型」和「分镜」描述，从 B-roll 库里挑素材排到时间线上。
    ///
    /// 挑素材分两步：先在本地按画面标签／画面结论筛出几条候选（51 条里直接让 4B 模型选，它只会全填 0），
    /// 再由本机模型在候选里定夺——模型说都不合适的行就空着。排的位置只有一条规则：
    /// 片段的入点就是这句台词开始的时间；同一时刻放不下才多开一条轨道。
    @discardableResult
    func autoPlaceBroll() async -> Int {
        guard !scriptTable.isEmpty else { taskState = .failed("还没有分镜稿，先导入或写上分镜稿。"); return 0 }
        guard !brollAssets.isEmpty else { taskState = .failed("B-roll 库里还没有素材，先去 B-roll 页导入并识别。"); return 0 }
        // 时间列还没有（或者没对上口播）就先对一次：排片的入点是从这里来的。
        if brollStoryboardRows.isEmpty, !words.isEmpty { await matchScriptTableTimes() }
        let rows = brollStoryboardRows
        guard !rows.isEmpty else {
            taskState = .failed("这些分镜行还没有口播时间，先在分镜页点「匹配口播时间」。")
            return 0
        }

        let settings = AISettings.current
        isChatWorking = true
        reviewProgress = 0.05
        taskState = .working("\(settings.serviceName) 正在按镜头类型和分镜描述挑 B-roll…")
        do {
            let chooser = brollChooser
            if chooser == nil { try await settings.prepare() }
            let chooseBroll: @Sendable ([AIClient.BrollChoiceRequest]) async throws -> [Int: Int] = chooser ?? { requests in
                try await AIClient(settings: settings).chooseBroll(for: requests)
            }
            let batchSize = 8
            var placements: [BrollPlacement] = []
            var empty = 0
            var skipped = 0
            var used = Set<String>()
            let batches = stride(from: 0, to: rows.count, by: batchSize).map { Array(rows[$0..<min(rows.count, $0 + batchSize)]) }

            for (index, batch) in batches.enumerated() {
                var candidates: [Int: [BrollAsset]] = [:]
                var requests: [AIClient.BrollChoiceRequest] = []
                for row in batch {
                    // 标了「未拍摄 / 网络素材」的镜头本来就要去外面找素材，库里的片子补上去只会碍事。
                    guard !row.external else { skipped += 1; continue }
                    let shortlist = Self.brollCandidates(for: row, in: brollAssets, used: used)
                    candidates[row.row] = shortlist
                    guard !shortlist.isEmpty else { continue }
                    requests.append(.init(row: row.row, script: row.script, shot: row.shot, note: row.note, candidates: shortlist.map(\.matchLine)))
                }
                var picks: [Int: Int] = [:]
                if !requests.isEmpty {
                    picks = (try? await chooseBroll(requests)) ?? [:]
                }
                for row in batch {
                    guard !row.external else { continue }
                    let shortlist = candidates[row.row] ?? []
                    guard !shortlist.isEmpty else { empty += 1; continue }
                    let pick = picks[row.row]
                    var chosen: BrollAsset?
                    var reason = ""
                    if let pick {
                        // 模型明确说“都不合适”（0）的行留空；越界序号当成没答。
                        guard pick >= 1, pick <= shortlist.count else { empty += 1; continue }
                        chosen = shortlist[pick - 1]
                        reason = "本机模型按镜头类型和分镜描述选中"
                        // 同一批里两行挑到同一条素材时，顺着候选顺序让给还没用过的下一条。
                        if let asset = chosen, used.contains(asset.path),
                           let alternative = shortlist.first(where: { !used.contains($0.path) }) {
                            chosen = alternative
                            reason = "本机模型选中第 \(pick) 条，前面已用过，顺延到第 \((shortlist.firstIndex(of: alternative) ?? 0) + 1) 条候选"
                        }
                    } else {
                        // 模型没给结论（没跑起来、解析失败）时按本地最接近的一条兜底。
                        chosen = shortlist.first(where: { !used.contains($0.path) }) ?? shortlist.first
                        reason = "模型没给结论，按画面标签最接近的一条兜底"
                    }
                    guard let asset = chosen, let placement = Self.makeBrollPlacement(asset: asset, row: row, reason: reason) else { empty += 1; continue }
                    used.insert(asset.path)
                    placements.append(placement)
                }
                reviewProgress = Double(index + 1) / Double(max(1, batches.count))
            }

            let packed = Self.packBrollTracks(placements)
            checkpoint()
            brollPlacements = packed
            reviewProgress = nil
            isChatWorking = false
            markChanged()
            let tracks = packed.map(\.track).max() ?? 0
            var summary = "已按镜头类型和分镜描述排好 \(packed.count) 条 B-roll（占用 \(tracks) 条轨道）"
            if skipped > 0 { summary += "；跳过 \(skipped) 行标注未拍摄／网络素材的镜头" }
            if empty > 0 { summary += "；另有 \(empty) 行库里没有合适素材，留空" }
            taskState = .done(summary)
            return packed.count
        } catch {
            reviewProgress = nil
            isChatWorking = false
            taskState = .failed("排 B-roll 失败：\(error.localizedDescription)")
            return 0
        }
    }

    func clearBrollPlacements() {
        guard !brollPlacements.isEmpty else { return }
        checkpoint()
        brollPlacements = []
        markChanged()
    }

    /// 本地先筛候选：台词、镜头类型、分镜备注里的两字组合，和素材的画面标签／画面结论／物品清单对一下。
    /// 字面上一条都对不上时退一步只按拍法挑（景别／运动先对上，再按画面识别推荐分），
    /// 让模型仍然有机会判断“这条能凑合吗”，模型说都不合适就留空。
    /// `used` 里的素材让开，避免同一段素材铺满全片；只有库里真的挑不出别的了才允许复用。
    nonisolated static func brollCandidates(for row: BrollStoryboardRow, in assets: [BrollAsset], limit: Int = 4, used: Set<String> = []) -> [BrollAsset] {
        // 标注了要用库外素材（未拍摄 / 网络素材）的镜头不从本地库里补。
        guard !row.external else { return [] }
        var scored: [(asset: BrollAsset, score: Int)] = []
        var byShot: [BrollAsset] = []
        for asset in assets {
            let score = brollScore(asset, row: row)
            if score > 0 { scored.append((asset, score)) }
            if shotHintScore(asset, row: row) > 0 { byShot.append(asset) }
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.asset.pickScore > right.asset.pickScore
        }
        let ranked: [BrollAsset] = scored.map(\.asset)
        let fresh: [BrollAsset] = ranked.filter { !used.contains($0.path) }
        if !fresh.isEmpty { return Array(fresh.prefix(limit)) }
        let shotOnly = byShot.filter { !used.contains($0.path) }.sorted { $0.pickScore > $1.pickScore }
        if !shotOnly.isEmpty { return Array(shotOnly.prefix(limit)) }
        // 库里连拍法能对上的都没有：把画面最清楚的几条端上来，让模型自己判断要不要用。
        let anyFresh = assets.filter { !used.contains($0.path) }.sorted { $0.pickScore > $1.pickScore }
        return Array((anyFresh.isEmpty ? ranked : anyFresh).prefix(limit))
    }

    nonisolated static func brollScore(_ asset: BrollAsset, row: BrollStoryboardRow) -> Int {
        let haystack = asset.matchHaystack
        let matches = bigrams(row.script + row.shot + row.note).filter { haystack.contains($0) }.count
        let score = matches * 6 + shotHintScore(asset, row: row)
        // 内容和拍法一点都没对上的不参与：宁可这一行留空，也不拿“这条拍得清楚”硬凑一条。
        guard score > 0 else { return 0 }
        // 画面内容识别给过推荐分的素材优先：它至少是拍清楚了的。
        return score + min(5, asset.pickScore / 20)
    }

    /// 拍法对得上多少分：景别（特写／细节）和运动（固定／环绕／推进）这两列里都可能写着。
    nonisolated static func shotHintScore(_ asset: BrollAsset, row: BrollStoryboardRow) -> Int {
        let hint = row.shot + " " + row.note
        let haystack = asset.matchHaystack
        let summary = asset.productPick?.summary ?? ""
        var score = 0
        if hint.contains("特写") || hint.contains("细节") || hint.contains("微距") {
            if summary.contains("特写") || summary.contains("细节") || haystack.contains("材质") { score += 5 }
        }
        if hint.contains("固定") {
            if asset.analysis?.motion == .staticShot { score += 5 }
        } else if ["环绕", "移动", "推近", "推进", "拉远", "摇", "跟随", "后退"].contains(where: { hint.contains($0) }) {
            if let motion = asset.analysis?.motion, motion != .staticShot { score += 4 }
        }
        return score
    }

    /// 片段的入点就是这句台词开始的时间 —— 只有这一条是硬规则。
    /// 长度不强行去盖住台词：从本机模型挑出的那个入点开始，一直用到这条素材结束。
    /// 素材比台词长就会压到后面几条上，由轨道分配去摆（塞不下才新开一条轨道）。
    nonisolated static func makeBrollPlacement(asset: BrollAsset, row: BrollStoryboardRow, reason: String) -> BrollPlacement? {
        guard asset.duration > 0.4 else { return nil }
        // 素材内部的入点优先用本机模型认定的“最清楚那一段”的开头。
        let sourceIn = min(max(0, asset.productPick?.start ?? 0), max(0, asset.duration - 0.4))
        let length = asset.duration - sourceIn
        guard length > 0.2 else { return nil }
        return BrollPlacement(
            row: row.row,
            path: asset.path,
            name: asset.name,
            track: 1,
            start: row.start,
            end: row.start + length,
            sourceIn: sourceIn,
            sourceOut: sourceIn + length,
            reason: reason
        )
    }

    /// 轨道分配：按时间顺序，能塞进已有轨道就塞，塞不下才新开一条。轨道越少越好。
    nonisolated static func packBrollTracks(_ placements: [BrollPlacement]) -> [BrollPlacement] {
        var result: [BrollPlacement] = []
        var trackEnds: [Double] = []
        for var placement in placements.sorted(by: { ($0.start, $0.row) < ($1.start, $1.row) }) {
            if let index = trackEnds.firstIndex(where: { $0 <= placement.start + 0.001 }) {
                placement.track = index + 1
                trackEnds[index] = placement.end
            } else {
                trackEnds.append(placement.end)
                placement.track = trackEnds.count
            }
            result.append(placement)
        }
        return result
    }

    /// 两字组合：中文按相邻两字切，英文按字符切。用来做一次便宜的本地粗筛。
    nonisolated static func bigrams(_ text: String) -> Set<String> {
        let characters = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        guard characters.count >= 2 else { return [] }
        var grams = Set<String>()
        var previous: Character?
        for character in characters {
            if let previous { grams.insert(String([previous, character])) }
            previous = character
        }
        return grams
    }

    /// 产品补充说明：brief 没写全的地方由人补，直接进本地模型的识别提示词。
    func updateProductNotes(_ text: String) { productProfile.notes = text; markChanged() }

    /// 用户确认“这是竞品”。确认过的名字进产品档案，下次识别时直接告诉模型，不用再问一遍。
    func confirmBrollCompetitor(_ label: String) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !productProfile.knownCompetitors.contains(name) else { return }
        productProfile.competitors = productProfile.knownCompetitors + [name]
        taskState = .done("已记下「\(name)」是竞品，之后的识别会直接按竞品判断。")
        markChanged()
    }

    /// 用户确认“这个东西不是产品，忽略掉”。同样记进档案，避免每次都被问。
    func ignoreBrollObject(_ label: String) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !productProfile.knownIgnored.contains(name) else { return }
        productProfile.ignoredObjects = productProfile.knownIgnored + [name]
        taskState = .done("已记下「\(name)」不是产品。")
        markChanged()
    }
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
    private var snapshot: Snapshot { .init(words: words, suggestions: suggestions, breaths: breaths, subtitleBreaks: subtitleBreaks, subtitleJoins: subtitleJoins, trimStart: trimStart, trimEnd: trimEnd, manuscript: manuscript, storyboards: storyboards, brollPlacements: brollPlacements) }
    private func restore(_ value: Snapshot) { words = value.words; suggestions = value.suggestions; breaths = value.breaths; subtitleBreaks = value.subtitleBreaks; subtitleJoins = value.subtitleJoins; trimStart = value.trimStart; trimEnd = value.trimEnd; manuscript = value.manuscript; storyboards = value.storyboards; brollPlacements = value.brollPlacements }
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
