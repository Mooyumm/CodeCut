import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import CodeCutMac

// MARK: - 真实模型跑一遍
//
// 这一组测试用的是**本机真实的 Qwen3-VL**，所以默认不跑：
// 它需要已经“准备本地模型”，而且要花几分钟。
//
//     CODECUT_REAL_MODEL_TEST=1 swift test --filter realModel
//
// 合成的画面是已知内容（红盒子=要推的产品，绿盒子=竞品），所以模型答对了没有是能判的。
// 这一步补的是单测补不了的东西：提示词丢给真模型，它到底吐不吐我们要的那套 JSON。

private let realModelEnabled = ProcessInfo.processInfo.environment["CODECUT_REAL_MODEL_TEST"] == "1"

/// 画一帧场景：浅色桌面 + 红色方块（带白点，主角，缓慢右移）+ 绿色方块（竞品，静止在左侧）。
private func drawScene(_ context: CGContext, width: Int, height: Int, frame: Int, total: Int) {
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    context.setFillColor(CGColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1))
    context.fill(canvas)
    // 桌面
    context.setFillColor(CGColor(red: 0.62, green: 0.58, blue: 0.54, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * 0.34))

    // 红色方块：主推产品，带一个白色圆点（brief 里写的就是这两个特征）。
    let progress = total > 1 ? Double(frame) / Double(total - 1) : 0
    let boxSide = CGFloat(height) * 0.42
    let boxX = CGFloat(width) * 0.30 + CGFloat(progress) * CGFloat(width) * 0.32
    let boxY = CGFloat(height) * 0.28
    context.setFillColor(CGColor(red: 0.85, green: 0.13, blue: 0.12, alpha: 1))
    context.fill(CGRect(x: boxX, y: boxY, width: boxSide, height: boxSide))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: boxX + boxSide * 0.38, y: boxY + boxSide * 0.38, width: boxSide * 0.24, height: boxSide * 0.24))

    // 绿色方块：不是这次的产品，应该在识别结果里被标出来问一句。
    let small = CGFloat(height) * 0.22
    context.setFillColor(CGColor(red: 0.16, green: 0.62, blue: 0.28, alpha: 1))
    context.fill(CGRect(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.36, width: small, height: small))
}

/// 写一段合成视频出来。用 AVAssetWriter 直接编码，不需要任何素材。
private func writeSyntheticClip(
    to url: URL,
    seconds: Double = 3,
    fps: Int = 30,
    draw: (CGContext, Int, Int, Int, Int) -> Void = { context, width, height, frame, total in
        drawScene(context, width: width, height: height, frame: frame, total: total)
    }
) async throws -> (width: Int, height: Int, duration: Double) {
    let width = 960, height = 540
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    guard writer.canAdd(input) else { throw AIError.invalidResponse("合成视频：加不进输入轨。") }
    writer.add(input)
    guard writer.startWriting() else { throw AIError.invalidResponse("合成视频：writer 起不来。") }
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * Double(fps))
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pixelBuffer = buffer else { throw AIError.invalidResponse("合成视频：像素缓冲建不出来。") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            draw(context, width, height, frame, frames)
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
            throw AIError.invalidResponse("合成视频：第 \(frame) 帧写不进去。")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw AIError.invalidResponse("合成视频：写入失败 \(writer.error?.localizedDescription ?? "未知原因")。")
    }
    return (width, height, seconds)
}

@Test(.enabled(if: realModelEnabled)) func realModelFindsTheProductAndTheOtherBrandBox() async throws {
    // 像 app 一样自己把本地服务拉起来（模型已下载时只是加载，等一会儿就好）。
    _ = try await LocalVLM.ensureServer()

    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-real-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 一份文字 brief：要认的产品长什么样、以及容易混淆的是什么。
    let brief = folder.appending(path: "brief.txt")
    try """
    产品 brief
    产品名称：红盒一号
    外观：一个正红色的正方形盒子，正面中央有一个白色圆点。
    关键特征：正红色、正方形、正面有一个白色圆点
    不要误判成：绿色的盒子、蓝色盒子
    """.write(to: brief, atomically: true, encoding: .utf8)

    let profile = try await ProductBriefReader.buildProfile(from: BriefSourceReader.read(brief), progress: { _, text in
        print("REAL brief: \(text)")
    }).profile
    print("REAL profile name=\(profile.name) products=\(profile.products.map(\.shortLabel))")
    #expect(!profile.products.isEmpty)

    let clip = folder.appending(path: "clip.mov")
    let info = try await writeSyntheticClip(to: clip)
    let duration = (try? await AVURLAsset(url: clip).load(.duration).seconds) ?? info.duration
    print("REAL clip \(info.width)x\(info.height) \(String(format: "%.2f", duration))s")

    let candidates = ProductPicker.candidates(for: profile)
    let pick = try await ProductPicker.analyze(
        path: clip.path,
        duration: duration,
        profile: profile,
        candidates: candidates,
        progress: { _ in }
    )

    // 把真实模型给的东西打出来：这一段是给人工看的，出了问题一眼能看出是哪一环。
    for frame in pick.frames {
        let objects = frame.objects.map { object in
            "\(object.label)[idx=\(object.productID == nil ? 0 : 1) \(object.role.rawValue) \(object.spot?.rawValue ?? "—") 清晰\(object.sharpness)]"
        }.joined(separator: " + ")
        print("REAL frame \(String(format: "%.2f", frame.time))s presence=\(frame.presence.rawValue) \(objects)")
    }
    let inventory = BrollInventory.build(frames: pick.frames)
    print("REAL inventory products=\(inventory.products.map(\.label)) pending=\(inventory.pending.map(\.label)) background=\(inventory.background.map(\.label)) subject=\(inventory.subject?.label ?? "无") 焦点切换=\(inventory.focusSwitches)")

    // 至少要认出来画面里有东西，并且把主推产品认出来（合成画面里它又大又正）。
    #expect(!pick.frames.isEmpty)
    #expect(pick.frames.contains { !$0.objects.isEmpty })
    #expect(pick.containsProduct)
    #expect(!inventory.products.isEmpty)
    // 绿色盒子不是这次的产品：要么被标成别的产品/不认识，要么至少没被算成清单里的产品。
    #expect(inventory.products.count < 2)
}

/// 用户的疑问：是不是“画面里有白，就当成米白款出现了”。
///
/// 这一条就是专门验它：**画面里只有红盒子和白色桌面**，brief 里却写着同款有两个颜色
/// （正红色 / 米白色），而且不给任何参考图 —— 最容易被颜色词带跑的场景。
/// 期望：红盒子归红色那一条；米白那条不能变成“这条素材拍到了米白”。
@Test(.enabled(if: realModelEnabled)) func realModelDoesNotInventTheIvoryColorFromAWhiteBackground() async throws {
    _ = try await LocalVLM.ensureServer()

    let folder = FileManager.default.temporaryDirectory.appending(path: "codecut-ivory-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let brief = folder.appending(path: "brief.txt")
    try """
    产品 brief
    产品名称：红盒一号
    本季主推同款两个颜色：
    1. 正红色（红色款）
    2. 米白色（米白款）
    两个颜色的形状完全一样，只有颜色不同。
    """.write(to: brief, atomically: true, encoding: .utf8)

    let productName = "红盒两色 \(UUID().uuidString.prefix(6))"
    defer { try? FileManager.default.removeItem(at: LocalVLM.supportDirectory.appending(path: "ProductRefs/\(productName)")) }
    let profile = try await ProductBriefReader.buildProfile(from: BriefSourceReader.read(brief), progress: { _, _ in }).profile
    print("REAL ivory profile products=\(profile.products.map(\.shortLabel))")
    #expect(profile.products.count >= 1)

    // 白色桌面 + 红盒子，没有别的产品。
    let clip = folder.appending(path: "white-bg.mov")
    let info = try await writeSyntheticClip(to: clip, draw: { context, width, height, frame, total in
        context.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(CGColor(red: 0.72, green: 0.72, blue: 0.74, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.22))
        let progress = total > 1 ? Double(frame) / Double(total - 1) : 0
        let side = CGFloat(height) * 0.45
        context.setFillColor(CGColor(red: 0.86, green: 0.12, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: CGFloat(width) * 0.28 + CGFloat(progress) * CGFloat(width) * 0.3,
                            y: CGFloat(height) * 0.3, width: side, height: side))
    })
    let duration = (try? await AVURLAsset(url: clip).load(.duration).seconds) ?? info.duration

    let pick = try await ProductPicker.analyze(
        path: clip.path, duration: duration, profile: profile,
        candidates: ProductPicker.candidates(for: profile), progress: { _ in }
    )
    for frame in pick.frames {
        print("REAL ivory frame \(String(format: "%.2f", frame.time))s presence=\(frame.presence.rawValue) :: " +
              frame.objects.map { "\($0.label)[\($0.color) \($0.role.rawValue) 清晰\($0.sharpness)]" }.joined(separator: " + "))
    }
    let inventory = BrollInventory.build(frames: pick.frames)
    print("REAL ivory 拍到=\(inventory.appearances.map(\.label)) 疑似=\(inventory.suspected.map(\.label)) 待确认=\(inventory.pending.map(\.label))")

    // 画面里只有红盒子：米白那一款不能算“拍到”，也不能进分组。
    #expect(inventory.appearances.count == 1)
    #expect(inventory.suspected.isEmpty)
    #expect(inventory.pending.isEmpty)
}
