import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Word（.docx）

/// 读 `word/document.xml`：一段一段地取文字、图，还有它是不是标题。
///
/// Word 的正文是 `w:p`（段落），文字在 `w:t` 里，图片只留一个 rId 在
/// `a:blip r:embed` 上，真正的文件名要去关系表里查。
struct WordDocumentParser {
    struct Paragraph: Sendable {
        var text: String = ""
        /// 0 = 正文；1…9 = 标题级别。
        var headingLevel: Int = 0
        /// 段落里的图片 rId。
        var images: [String] = []
    }

    struct Document: Sendable {
        var paragraphs: [Paragraph] = []
    }

    static func parse(_ xml: String) throws -> Document {
        var document = Document()
        var stack: [String] = []
        var current: Paragraph?

        try StreamingXML.walk(xml) { event in
            switch event.kind {
            case .start:
                let name = event.name
                stack.append(name)
                switch name {
                case "p":
                    current = Paragraph()
                case "pStyle":
                    if let value = attribute(event, "w:val"), let level = headingLevel(value), current?.headingLevel == 0 {
                        current?.headingLevel = level
                    }
                case "outlineLvl":
                    if let value = attribute(event, "w:val"), let level = Int(value), current?.headingLevel == 0 {
                        current?.headingLevel = level + 1
                    }
                case "blip":
                    if let id = attribute(event, "r:embed") { current?.images.append(id) }
                case "imagedata":
                    if let id = attribute(event, "r:id") { current?.images.append(id) }
                default:
                    break
                }
            case .end:
                let name = event.name
                if !stack.isEmpty { stack.removeLast() }
                if name == "p", let paragraph = current {
                    document.paragraphs.append(paragraph)
                    current = nil
                }
            case .text:
                // 只看 `w:t` 里的字：`w:instrText` 是域代码，`w:delText` 是删掉的旧稿。
                guard stack.last == "t" else { return }
                current?.text += event.text
            }
        }
        return document
    }

    /// `Heading1` / `标题 2` / `a3` 之外的纯数字样式 id。
    private static func headingLevel(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let isHeadingWord = lower.contains("heading") || trimmed.contains("标题")
        let digits = trimmed.filter(\.isNumber)
        if isHeadingWord {
            return Int(digits.prefix(1)) ?? 1
        }
        if let number = Int(trimmed), (1...6).contains(number) { return number }
        return nil
    }

    private static func attribute(_ event: StreamingXML.Event, _ name: String) -> String? {
        event.attributes[name] ?? event.attributes[name.components(separatedBy: ":").last ?? name]
    }
}

// MARK: - PowerPoint（.pptx）

/// 读 `ppt/slides/slideN.xml`：这一页的标题、正文、图片。
struct SlideParser {
    struct Slide: Sendable {
        var title: String = ""
        var lines: [String] = []
        /// 这一页里的图片 rId。
        var images: [String] = []
    }

    static func parse(_ xml: String) throws -> Slide {
        struct Shape {
            var text: String = ""
            var isTitle: Bool = false
        }

        var slide = Slide()
        var stack: [String] = []
        var shapes: [Shape] = []

        try StreamingXML.walk(xml) { event in
            switch event.kind {
            case .start:
                let name = event.name
                stack.append(name)
                switch name {
                case "sp":
                    shapes.append(Shape())
                case "ph":
                    // 版式里 type 缺省或 body/subTitle 都是正文，只有 title/ctrTitle 是标题。
                    let type = attribute(event, "type")
                    if type == "title" || type == "ctrTitle" {
                        if !shapes.isEmpty { shapes[shapes.count - 1].isTitle = true }
                    }
                case "br":
                    if !shapes.isEmpty { shapes[shapes.count - 1].text += "\n" }
                case "blip":
                    if let id = attribute(event, "r:embed") { slide.images.append(id) }
                default:
                    break
                }
            case .end:
                let name = event.name
                if !stack.isEmpty { stack.removeLast() }
                // `a:p` 是一段：换行断一下，免得两段粘成一句。
                if name == "p", !shapes.isEmpty {
                    shapes[shapes.count - 1].text += "\n"
                }
                if name == "sp", let shape = shapes.popLast() {
                    let text = shape.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if shape.isTitle, slide.title.isEmpty {
                        slide.title = text.replacingOccurrences(of: "\n", with: " ")
                    } else {
                        slide.lines.append(contentsOf: text
                            .components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
                    }
                }
            case .text:
                guard stack.last == "t", !shapes.isEmpty else { return }
                shapes[shapes.count - 1].text += event.text
            }
        }
        return slide
    }

    private static func attribute(_ event: StreamingXML.Event, _ name: String) -> String? {
        event.attributes[name]
    }
}

// MARK: - 自己画一份 PDF

/// 把 brief 的段落和图片排成一份 PDF，给左栏滚动、放大看。
///
/// Word / PPT / 图片 / 纯文本这类不是 PDF 的 brief 都走这里。
/// 用的是系统自带的排版和绘图，不需要装 Office，也不联网。
enum BriefPDFRenderer {
    private static let headingSize: CGFloat = 17
    private static let bodySize: CGFloat = 12
    private static let captionSize: CGFloat = 10

    static func write(_ blocks: [BriefBlock], pageSize: CGSize, to url: URL) throws {
        guard pageSize.width > 80, pageSize.height > 80 else {
            throw BriefSourceError.unreadable("预览页尺寸不对。")
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw BriefSourceError.unreadable("写不出 PDF 预览文件。")
        }

        let margin: CGFloat = min(56, max(28, pageSize.width * 0.07))
        let contentWidth = pageSize.width - margin * 2
        let bottom = margin
        var cursor = pageSize.height - margin

        func beginPage() {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: pageSize))
            cursor = pageSize.height - margin
        }

        func nextPage() {
            context.endPDFPage()
            beginPage()
        }

        beginPage()

        for block in blocks {
            switch block {
            case .pageBreak:
                nextPage()

            case .heading(let text):
                let string = attributed(text, size: headingSize, bold: true, lineSpacing: 3)
                let height = measure(string, width: contentWidth)
                if cursor - height < bottom { nextPage() }
                drawFitted(string, at: cursor, width: contentWidth, height: height, in: context, margin: margin)
                cursor -= height + 12

            case .text(let text):
                var pending = text
                while !pending.isEmpty {
                    let available = cursor - bottom
                    if available < 24 { nextPage(); continue }
                    let string = attributed(pending, size: bodySize, bold: false, lineSpacing: 4)
                    let height = measure(string, width: contentWidth)
                    if height <= available {
                        drawFitted(string, at: cursor, width: contentWidth, height: height, in: context, margin: margin)
                        cursor -= height + 7
                        break
                    }
                    let framesetter = CTFramesetterCreateWithAttributedString(string)
                    let box = CGRect(x: margin, y: cursor - available, width: contentWidth, height: available)
                    let frame = CTFramesetterCreateFrame(
                        framesetter,
                        CFRange(location: 0, length: 0),
                        CGPath(rect: box, transform: nil),
                        nil
                    )
                    let visible = CTFrameGetVisibleStringRange(frame)
                    // 一个字都排不下，或者全排下了 —— 两种情况都不该再切，免得死循环。
                    guard visible.length > 0, visible.length < string.length else {
                        CTFrameDraw(frame, context)
                        cursor = bottom
                        break
                    }
                    CTFrameDraw(frame, context)
                    pending = (pending as NSString).substring(from: visible.length)
                    nextPage()
                }

            case .image(let path, let caption):
                guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      image.width > 0, image.height > 0 else {
                    let string = attributed("（这张图读不出来：\(URL(fileURLWithPath: path).lastPathComponent)）",
                                            size: captionSize, bold: false, lineSpacing: 2)
                    let height = measure(string, width: contentWidth)
                    if cursor - height < bottom { nextPage() }
                    drawFitted(string, at: cursor, width: contentWidth, height: height, in: context, margin: margin)
                    cursor -= height + 8
                    continue
                }
                let ratio = CGFloat(image.height) / CGFloat(image.width)
                var width = contentWidth
                var height = width * ratio
                let pageLimit = pageSize.height - margin * 2
                if height > pageLimit {
                    height = pageLimit
                    width = height / ratio
                }
                let captionString = attributed(caption, size: captionSize, bold: false, lineSpacing: 2)
                let captionHeight = caption.isEmpty ? 0 : measure(captionString, width: contentWidth) + 4
                if cursor - height - captionHeight < bottom { nextPage() }
                let rect = CGRect(x: margin, y: cursor - height, width: width, height: height)
                context.draw(image, in: rect)
                cursor -= height + 4
                if captionHeight > 0 {
                    drawFitted(captionString, at: cursor, width: contentWidth, height: captionHeight - 4, in: context, margin: margin)
                    cursor -= captionHeight
                }
                cursor -= 6
            }
        }

        context.endPDFPage()
        context.closePDF()
    }

    // MARK: 排版小工具

    private static func attributed(_ text: String, size: CGFloat, bold: Bool, lineSpacing: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
    }

    private static func measure(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: 1_000_000),
            nil
        )
        return ceil(size.height) + 2
    }

    private static func drawFitted(
        _ string: NSAttributedString,
        at cursor: CGFloat,
        width: CGFloat,
        height: CGFloat,
        in context: CGContext,
        margin: CGFloat
    ) {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let box = CGRect(x: margin, y: cursor - height, width: width, height: height)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: box, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }
}
