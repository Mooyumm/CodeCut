import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// B-roll 素材的本地 AI 识别：**画面内容** + **运动方向**。
///
/// 全部跑在 Apple 自带的 Vision 框架上：不联网、不下载模型、不依赖任何第三方。
/// - 画面内容：`VNClassifyImageRequest`（场景/物体分类，约 1300 个类别）
/// - 运动方向：`VNGenerateOpticalFlowRequest`（稠密光流）→ 主导位移 + 径向发散度
/// - 镜头切换：降采样亮度直方图的帧间距离
///
/// 所有阈值都以“占画面宽/高的百分比”为单位，是在真实素材上标定出来的，
/// 所以 4K 素材和 1080p 素材的判断结果一致。
enum BrollAnalyzer {
    struct Probe: Sendable {
        var duration: Double
        var width: Int
        var height: Int
    }

    /// 能被登记进 B-roll 媒体库的扩展名。
    static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "mts", "m2ts", "mpg", "mpeg", "webm"
    ]

    /// 采样帧数：太少会漏掉镜头运动，太多会拖慢上百条素材的批量识别。
    private static let sampleCount = 7
    /// 分析用的统一宽度，保证阈值与素材分辨率无关。
    private static let analysisWidth: CGFloat = 480
    /// 只对其中几张做内容分类，运动分析才需要全部采样帧。
    private static let contentSampleCount = 3

    // MARK: 判定阈值（单位：画面宽/高的百分比，已在真实素材上标定）

    /// 首尾累计位移低于它，视为固定镜头。
    private static let staticShift = 1.5
    /// 主轴位移要比次轴大这么多倍，才算单一方向；否则算斜向。
    private static let axisDominance = 1.45
    /// 累计发散度超过它才算推近/拉远。
    private static let zoomDivergence = 3.0
    /// 前后半段方向相反、且两段位移都超过它，判为往复移动。
    private static let reversalShift = 1.5
    /// 内容标签的最低置信度。分类器对近景的置信度普遍偏低，所以取值较松。
    private static let minimumTagConfidence = 0.06
    /// 能量分档：每秒位移低于它算稳定，低于下一档算轻缓，其余算明显。
    /// 每秒位移低于它算“稳定”。运动曲线的阶段判定也用这一条，所以不是私有的。
    static let steadyPerSecond = 0.35
    private static let gentlePerSecond = 1.2

    // MARK: - 读取素材元数据

    static func probe(url: URL) async -> Probe? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0.05 else { return nil }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = size.applying(transform)
        return Probe(duration: duration, width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()))
    }

    /// 缩略图：列表里用来快速认素材，不落盘、不写进项目文件。
    ///
    /// 素材库可能一次显示几十条 4K 素材，同时解码会把机器拖住，
    /// 所以这里用信号量把并发的解码数量压在一个小常数上。
    static func thumbnail(url: URL, at fraction: Double = 0.35, maxSize: CGFloat = 320) async -> CGImage? {
        await thumbnailLimiter.acquire()
        defer { Task { await thumbnailLimiter.release() } }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let time = CMTime(seconds: min(max(duration * fraction, 0), max(0, duration - 0.05)), preferredTimescale: 600)
        return (try? await generator.image(at: time))?.image
    }

    private static let thumbnailLimiter = Gate(limit: 4)

    // MARK: - 采样帧（给本地视觉模型用）

    /// 一帧采样画面。`time` 是它在**源素材**里的时间。
    struct SampleFrame: @unchecked Sendable {
        var index: Int
        var time: Double
        var cgImage: CGImage
    }

    /// 视觉模型每帧都要过一遍编码器，帧数直接决定耗时，所以默认只取 5 帧。
    static let visionSampleCount = 5

    /// 按等间隔采样一批画面，跳掉片头片尾（起机/停机的那一两帧没有判断价值）。
    static func sampleFrames(url: URL, count: Int = visionSampleCount, maxWidth: CGFloat = 768) async throws -> [SampleFrame] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0.05 else { throw AIError.invalidResponse("素材时长无效。") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        var frames: [SampleFrame] = []
        for index in 0..<count {
            let fraction = 0.12 + 0.76 * Double(index) / Double(max(1, count - 1))
            let time = duration * fraction
            if let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                frames.append(SampleFrame(index: index, time: time, cgImage: result.image))
            }
        }
        guard frames.count >= 2 else { throw AIError.invalidResponse("无法解码这条素材的画面。") }
        return frames
    }

    /// 相邻采样帧之间的位移速度，单位是画面宽/高的百分比/秒。
    /// 选片段时用它判断“这一段镜头稳不稳”，比整条素材的平均值精确得多。
    static func localSpeeds(_ frames: [SampleFrame]) -> [Double] {
        guard frames.count >= 2 else { return [] }
        var speeds: [Double] = []
        for index in 1..<frames.count {
            let shift = opticalFlow(from: frames[index - 1].cgImage, to: frames[index].cgImage) ?? .zero
            let seconds = max(0.05, frames[index].time - frames[index - 1].time)
            speeds.append(shift.magnitude / seconds)
        }
        return speeds
    }

    /// 简单并发闸门：同时最多放行 limit 个任务。
    private actor Gate {
        private let limit: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func acquire() async {
            if active < limit { active += 1; return }
            await withCheckedContinuation { waiters.append($0) }
            active += 1
        }

        func release() {
            active -= 1
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
    }

    // MARK: - 完整分析

    static func analyze(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> BrollAnalysis {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0.05 else { throw AIError.invalidResponse("素材时长无效，无法分析。") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: analysisWidth, height: analysisWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        // 跳过片头片尾：开头/结尾常常是刚起机或已经停机的那一两帧。
        var frames: [CGImage] = []
        for index in 0..<sampleCount {
            let fraction = 0.12 + 0.76 * Double(index) / Double(sampleCount - 1)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) { frames.append(result.image) }
        }
        guard frames.count >= 2 else { throw AIError.invalidResponse("无法解码这条素材的画面。") }
        progress?(0.4)

        let tags = classify(frames)
        progress?(0.7)

        let motion = measureMotion(frames, duration: duration)
        progress?(0.75)

        // 密集采样再跑一遍：标量摘要只说“向右移动”，这一步给出整条片子的轨迹、
        // 速度曲线和阶段划分 —— 剪辑要的是一个区间，不是一个平均值。
        let curve = await motionCurve(asset: asset, duration: duration) { fraction in
            progress?(0.75 + 0.25 * fraction)
        }
        progress?(1)

        return BrollAnalysis(
            tags: tags,
            motion: motion.direction,
            zoom: motion.zoom,
            energy: energy(for: motion.shiftPerSecond),
            horizontalShift: motion.horizontal,
            verticalShift: motion.vertical,
            divergence: motion.divergence,
            activity: motion.activity,
            shiftPerSecond: motion.shiftPerSecond,
            motionCurve: curve
        )
    }

    // MARK: - 运动曲线（密集采样）

    /// 采样多密：约每 0.3 秒一个点，下限 16、上限 40。
    ///
    /// 切「可用片段」要靠这些点看出转折点和停顿落在哪 —— 点太稀就只能给一条
    /// 平均值曲线，切出来的段边界也不准；上限是给"上百条素材批量跑"留的时间预算。
    static let curveSampleMinimum = 16
    static let curveSampleMaximum = 40

    static func curveSampleCount(for duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return curveSampleMinimum }
        return min(curveSampleMaximum, max(curveSampleMinimum, Int((duration / 0.3).rounded())))
    }

    /// 曲线用的统一宽度：比内容分析那一遍更小，因为点更多。
    private static let curveWidth: CGFloat = 320

    /// 逐点算光流、积分成轨迹，再切阶段。
    static func motionCurve(
        asset: AVURLAsset,
        duration: Double,
        samples: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> BrollMotionCurve {
        let count = samples ?? curveSampleCount(for: duration)
        guard count >= 3, duration > 0.05 else { return BrollMotionCurve(duration: duration) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: curveWidth, height: curveWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var decoded: [(time: Double, image: CGImage)] = []
        for index in 0..<count {
            // 几乎贴着片头片尾取样：跳过的那一点点只是给起机/停机的黑帧留个边，
            // 因为「固定镜头前后移动的部分」恰恰就在开头和结尾，跳过就看不见了。
            let fraction = 0.02 + 0.96 * Double(index) / Double(count - 1)
            let time = duration * fraction
            if let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                decoded.append((time, result.image))
            }
        }
        guard decoded.count >= 3 else { return BrollMotionCurve(duration: duration) }
        return motionCurve(frames: decoded, duration: duration, progress: progress)
    }

    /// 由已经解码好的采样帧算曲线。
    /// 单独拆出来是为了能拿“已知位移的画面”当基准测这一段 —— 光流到轨迹这一步最怕悄悄算错。
    static func motionCurve(
        frames decoded: [(time: Double, image: CGImage)],
        duration: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> BrollMotionCurve {
        guard decoded.count >= 3 else { return BrollMotionCurve(duration: duration) }
        var curve = BrollMotionCurve(duration: duration)
        var x = 0.0, y = 0.0
        curve.samples.append(BrollMotionSample(time: decoded[0].time, x: 0, y: 0, speed: 0, direction: 0))
        for index in 1..<decoded.count {
            let previous = decoded[index - 1], current = decoded[index]
            let shift = opticalFlow(from: previous.image, to: current.image) ?? .zero
            let seconds = max(0.05, current.time - previous.time)
            x += shift.x
            y += shift.y
            curve.samples.append(BrollMotionSample(
                time: current.time,
                x: x,
                y: y,
                speed: shift.magnitude / seconds,
                direction: atan2(shift.y, shift.x) * 180 / .pi,
                divergence: shift.divergence
            ))
            progress?(Double(index) / Double(decoded.count - 1))
        }
        curve.phases = BrollMotionCurve.phases(from: curve.samples)
        return curve
    }

    // MARK: - 画面内容（场景 / 物体分类）

    private static func classify(_ frames: [CGImage]) -> [BrollTag] {
        let step = max(1, frames.count / max(1, contentSampleCount))
        var scores: [String: Double] = [:]
        for index in Swift.stride(from: 0, to: frames.count, by: step).prefix(contentSampleCount) {
            let request = VNClassifyImageRequest()
            guard (try? VNImageRequestHandler(cgImage: frames[index], options: [:]).perform([request])) != nil else { continue }
            for observation in request.results ?? [] where Double(observation.confidence) >= minimumTagConfidence {
                // 取各采样帧里的最高置信度：一条素材里只要有一段出现“咖啡杯”就算命中。
                scores[observation.identifier] = max(scores[observation.identifier] ?? 0, Double(observation.confidence))
            }
        }
        var tags = scores
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { BrollTag(identifier: $0.key, label: BrollTag.label(for: $0.key), confidence: $0.value) }
        // 分类器对极端近景（全画面的产品特写）常常给不出高置信度标签，
        // 这时用画面本身的明暗/色调兜底，保证每条素材至少有一个可读的描述。
        if let tone = toneTag(frames) { tags.append(tone) }
        return tags
    }

    private static func toneTag(_ frames: [CGImage]) -> BrollTag? {
        guard let middle = frames.dropFirst(frames.count / 2).first ?? frames.first,
              let palette = averagePalette(middle) else { return nil }
        let brightness = (palette.r * 0.299 + palette.g * 0.587 + palette.b * 0.114) / 255
        let warmth = (palette.r - palette.b) / 255
        var parts: [String] = []
        parts.append(brightness < 0.32 ? "暗调" : (brightness > 0.72 ? "亮调" : "中间调"))
        if abs(warmth) > 0.06 { parts.append(warmth > 0 ? "暖色" : "冷色") }
        let identifier = "tone_\(brightness < 0.32 ? "dark" : (brightness > 0.72 ? "bright" : "mid"))_\(abs(warmth) > 0.06 ? (warmth > 0 ? "warm" : "cool") : "neutral")"
        return BrollTag(identifier: identifier, label: parts.joined(), confidence: 0.01)
    }

    private static func averagePalette(_ image: CGImage) -> (r: Double, g: Double, b: Double)? {
        let width = 16, height = 9
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[index]); g += Double(pixels[index + 1]); b += Double(pixels[index + 2])
        }
        let count = Double(width * height)
        return (r / count, g / count, b / count)
    }

    // MARK: - 运动方向（光流）

    /// 位移测量结果。单位统一是画面宽/高的百分比，x 向右为正，y 向下为正。
    private struct Shift {
        var x: Double
        var y: Double
        /// 径向发散度：大于 0 表示画面向外扩（推近），小于 0 表示向内收（拉远）。
        var divergence: Double

        var magnitude: Double { (x * x + y * y).squareRoot() }
        static let zero = Shift(x: 0, y: 0, divergence: 0)
    }

    private struct MotionSummary {
        var direction: BrollMotion
        var zoom: BrollZoom
        var horizontal: Double
        var vertical: Double
        var divergence: Double
        var activity: Double
        var shiftPerSecond: Double
    }

    /// 关键点：**先算首尾两帧之间的整体位移**，而不是把相邻帧的位移加起来。
    /// 相邻帧光流的噪声会累积，而首尾位移天然免疫中途的偶发干扰，
    /// 也能正确描述“先移动、后停住”这种很常见的运镜。
    private static func measureMotion(_ frames: [CGImage], duration: Double) -> MotionSummary {
        let first = frames[0]
        let last = frames[frames.count - 1]
        let net = opticalFlow(from: first, to: last) ?? .zero

        // 逐段位移累加：用来发现"来回移动 / 手持晃动"这类首尾会互相抵消的运镜。
        var activity = 0.0
        for index in 1..<frames.count {
            activity += (opticalFlow(from: frames[index - 1], to: frames[index]) ?? .zero).magnitude
        }

        // 前后半段方向相反 → 画面在往复移动，而不是单向运镜。
        var reversing = false
        if frames.count >= 4 {
            let middle = frames.count / 2
            let head = opticalFlow(from: first, to: frames[middle]) ?? .zero
            let tail = opticalFlow(from: frames[middle], to: last) ?? .zero
            reversing = head.magnitude >= reversalShift
                && tail.magnitude >= reversalShift
                && (head.x * tail.x + head.y * tail.y) < 0
        }

        let direction = motionDirection(horizontal: net.x, vertical: net.y, reversing: reversing)
        let zoom = zoomDirection(divergence: net.divergence)

        // 只用采样覆盖的那一段（0.12–0.88）算速度，避免被片头片尾稀释。
        let sampled = max(0.1, duration * 0.76)
        return MotionSummary(
            direction: direction,
            zoom: zoom,
            horizontal: net.x,
            vertical: net.y,
            divergence: net.divergence,
            activity: activity,
            shiftPerSecond: net.magnitude / sampled
        )
    }

    /// 由首尾累计位移判定画面主导运动方向。位移单位是画面宽/高的百分比。
    static func motionDirection(horizontal: Double, vertical: Double, reversing: Bool = false) -> BrollMotion {
        if reversing { return .mixed }
        let magnitude = (horizontal * horizontal + vertical * vertical).squareRoot()
        if magnitude < staticShift { return .staticShot }
        if abs(horizontal) >= abs(vertical) * axisDominance {
            return horizontal > 0 ? .panRight : .panLeft
        }
        if abs(vertical) >= abs(horizontal) * axisDominance {
            return vertical > 0 ? .tiltDown : .tiltUp
        }
        return .diagonal
    }

    /// 由累计径向发散度判定变焦方向。
    static func zoomDirection(divergence: Double) -> BrollZoom {
        if divergence > zoomDivergence { return .pushIn }
        if divergence < -zoomDivergence { return .pullOut }
        return .none
    }

    private static func energy(for shiftPerSecond: Double) -> BrollMotionEnergy {
        if shiftPerSecond < steadyPerSecond { return .steady }
        if shiftPerSecond < gentlePerSecond { return .gentle }
        return .strong
    }

    /// 两张同尺寸画面之间的稠密光流：返回平均位移和径向发散度。
    private static func opticalFlow(from previous: CGImage, to current: CGImage) -> Shift? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: current, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        guard (try? VNImageRequestHandler(cgImage: previous, options: [:]).perform([request])) != nil,
              let observation = request.results?.first as? VNPixelBufferObservation else { return nil }

        let buffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 16, height > 16,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let floats = base.assumingMemoryBound(to: Float.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let centreX = Double(width) / 2
        let centreY = Double(height) / 2

        var sumX = 0.0, sumY = 0.0, sumRadial = 0.0, count = 0.0
        var y = 4
        while y < height - 4 {
            var x = 4
            while x < width - 4 {
                let offset = y * stride + x * 2
                let u = Double(floats[offset])
                let v = Double(floats[offset + 1])
                if u.isFinite, v.isFinite {
                    let dx = Double(x) - centreX
                    let dy = Double(y) - centreY
                    let radius = (dx * dx + dy * dy).squareRoot()
                    // 画面正中有很多非刚体运动（人脸、主体），排除掉更稳。
                    if radius > 8 {
                        sumX += u
                        sumY += v
                        sumRadial += (u * dx + v * dy) / radius
                        count += 1
                    }
                }
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return nil }

        return Shift(
            x: sumX / count / Double(width) * 100,
            y: sumY / count / Double(height) * 100,
            divergence: sumRadial / count
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - Vision 分类结果的中文显示名

extension BrollTag {
    /// Vision 的分类标识是英文分类名（如 consumer_electronics），这里映射成中文标签。
    /// 表里没有的标识回退成可读的英文，界面会照原样显示，不会丢掉信息。
    static func label(for identifier: String) -> String {
        if let known = chineseLabels[identifier] { return known }
        let cleaned = identifier.replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    private static let chineseLabels: [String: String] = [
        // 人
        "person": "人物", "people": "人物", "man": "男士", "woman": "女士", "child": "儿童", "baby": "婴儿",
        "face": "面部", "portrait": "人像", "hand": "手部", "human_body": "人体", "group": "多人",
        // 场景 / 环境
        "outdoor": "户外", "indoor": "室内", "nature": "自然", "landscape": "风景", "scenery": "景色",
        "sky": "天空", "cloud": "云", "sunset": "日落", "sunrise": "日出", "night": "夜景", "daytime": "白天",
        "forest": "树林", "tree": "树", "plant": "植物", "flower": "花", "leaf": "叶子", "grass": "草地",
        "garden": "花园", "field": "田野", "farm": "农场", "mountain": "山", "hill": "丘陵", "valley": "山谷",
        "desert": "沙漠", "beach": "海滩", "coast": "海岸", "sea": "海", "ocean": "海洋", "lake": "湖",
        "river": "河流", "water": "水", "waterfall": "瀑布", "snow": "雪", "ice": "冰", "rain": "雨",
        "fog": "雾", "rock": "岩石", "stone": "石头", "sand": "沙", "soil": "土壤", "island": "岛屿",
        "wilderness": "野外", "jungle": "丛林", "park": "公园", "cave": "洞穴", "volcano": "火山",
        // 城市 / 建筑
        "city": "城市", "town": "城镇", "village": "乡村", "street": "街道", "road": "道路", "highway": "公路",
        "sidewalk": "人行道", "building": "建筑", "skyscraper": "高层建筑", "house": "房屋", "architecture": "建筑",
        "bridge": "桥梁", "tower": "塔", "fence": "栅栏", "wall": "墙", "floor": "地面", "ceiling": "天花板",
        "window": "窗户", "door": "门", "stairs": "楼梯", "roof": "屋顶", "construction": "施工",
        "crane": "起重机", "workshop": "车间", "factory": "工厂", "warehouse": "仓库", "parking_lot": "停车场",
        // 室内空间
        "room": "房间", "interior_design": "室内空间", "office": "办公室", "kitchen": "厨房", "bedroom": "卧室",
        "bathroom": "浴室", "living_room": "客厅", "restaurant": "餐厅", "cafe": "咖啡馆", "bar": "酒吧",
        "store": "商店", "shop": "商铺", "market": "市场", "supermarket": "超市", "mall": "商场",
        "hotel": "酒店", "library": "图书馆", "museum": "博物馆", "school": "学校", "classroom": "教室",
        "hospital": "医院", "gym": "健身房", "studio": "影棚", "stage": "舞台", "airport": "机场",
        "train_station": "车站", "subway": "地铁", "church": "教堂", "temple": "寺庙",
        // 家具 / 家居
        "furniture": "家具", "table": "桌子", "desk": "书桌", "chair": "椅子", "sofa": "沙发", "bed": "床",
        "shelf": "架子", "cabinet": "柜子", "lamp": "灯具", "mirror": "镜子", "carpet": "地毯",
        "curtain": "窗帘", "pillow": "靠垫", "clock": "时钟", "candle": "蜡烛", "vase": "花瓶",
        "picture_frame": "相框", "houseplant": "绿植", "kitchen_appliance": "厨房电器",
        // 电子 / 数码
        "computer": "电脑", "laptop": "笔记本电脑", "notebook_computer": "笔记本电脑", "desktop_computer": "台式机",
        "consumer_electronics": "消费电子", "electronic_equipment": "电子设备", "device": "设备",
        "machine": "机械", "smartphone": "手机", "phone": "电话", "mobile_phone": "手机", "tablet": "平板",
        "screen": "屏幕", "monitor": "显示器", "television": "电视", "keyboard": "键盘", "mouse": "鼠标",
        "headphones": "耳机", "camera": "相机", "lens": "镜头", "drone": "无人机", "robot": "机器人",
        "microphone": "麦克风", "speaker": "音响", "battery": "电池", "cable": "线缆", "circuit": "电路板",
        "technology": "科技", "software": "软件", "data": "数据",
        // 交通
        "vehicle": "车辆", "car": "汽车", "sports_car": "跑车", "truck": "卡车", "bus": "公交车",
        "motorcycle": "摩托车", "bicycle": "自行车", "bike": "自行车", "train": "火车", "airplane": "飞机",
        "boat": "船", "ship": "轮船", "helicopter": "直升机", "transportation": "交通", "traffic": "交通流",
        "wheel": "车轮", "tire": "轮胎", "engine": "发动机",
        // 物品
        "container": "容器", "box": "盒子", "bag": "包", "backpack": "背包", "luggage": "行李箱",
        "purse": "手提包", "bottle": "瓶子", "cup": "杯子", "coffee_mug": "咖啡杯", "glass": "玻璃杯",
        "bowl": "碗", "plate": "盘子", "fork": "餐具", "knife": "刀", "tool": "工具", "equipment": "器械",
        "stationery": "文具", "book": "书", "paper": "纸张", "pen": "笔", "toy": "玩具", "game": "游戏",
        "sports_equipment": "运动器材", "ball": "球", "instrumentality": "器具", "product": "产品",
        "package": "包装", "label": "标签", "sign": "标识", "flag": "旗帜", "money": "钱币",
        // 服饰
        "clothing": "服饰", "shirt": "衬衫", "dress": "连衣裙", "jacket": "外套", "shoe": "鞋",
        "hat": "帽子", "glasses": "眼镜", "watch": "手表", "jewelry": "珠宝", "fashion": "时尚",
        // 食物
        "food": "食物", "fruit": "水果", "vegetable": "蔬菜", "meal": "餐食", "dish": "菜品",
        "bread": "面包", "rice": "米饭", "noodle": "面食", "meat": "肉类", "seafood": "海鲜",
        "dessert": "甜点", "cake": "蛋糕", "coffee": "咖啡", "tea": "茶", "drink": "饮料",
        "wine": "葡萄酒", "beer": "啤酒", "cooking": "烹饪", "kitchen_utensil": "厨具",
        // 动物
        "animal": "动物", "dog": "狗", "cat": "猫", "bird": "鸟", "fish": "鱼", "horse": "马",
        "cow": "牛", "sheep": "羊", "insect": "昆虫", "wildlife": "野生动物", "pet": "宠物",
        // 抽象 / 工作场景
        "business": "商务", "document": "文档", "office_supplies": "办公用品", "meeting": "会议",
        "presentation": "演示", "shopping": "购物", "finance": "金融", "medicine": "医疗",
        "health_care": "健康", "sport": "运动", "exercise": "锻炼", "music": "音乐",
        "musical_instrument": "乐器", "guitar": "吉他", "piano": "钢琴", "art": "艺术",
        "speakers_music": "音乐播放", "music_speakers": "音响播放", "adult": "成年人",
        "computer_monitor": "电脑显示器", "monitor_screen": "显示器", "material": "材质", "textile": "织物",
        "necktie": "领带", "photography": "摄影", "light": "光线", "shadow": "阴影", "texture": "纹理", "pattern": "图案",
        "background": "背景", "abstract": "抽象", "color": "色彩"
    ]
}
