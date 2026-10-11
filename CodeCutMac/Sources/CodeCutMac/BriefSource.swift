import AppKit
import Compression
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - 格式

/// 品牌方给的 brief 可能是任何东西：PDF、Word、PPT，甚至是几张图。
/// 这里只负责认出格式，具体怎么读交给下面的解析器。
enum BriefFormat: String, Sendable, CaseIterable {
    case pdf, docx, doc, pptx, ppt, rtf, html, text, image, unknown

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "docx", "docm": self = .docx
        case "doc": self = .doc
        case "pptx", "pptm": self = .pptx
        case "ppt": self = .ppt
        case "rtf": self = .rtf
        case "html", "htm": self = .html
        case "txt", "md", "markdown", "csv", "text": self = .text
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp": self = .image
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .docx, .doc: "Word"
        case .pptx, .ppt: "PPT"
        case .rtf: "RTF"
        case .html: "网页"
        case .text: "文本"
        case .image: "图片"
        case .unknown: "文件"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .docx, .doc: "doc.text"
        case .pptx, .ppt: "rectangle.on.rectangle"
        case .image: "photo"
        default: "doc"
        }
    }

    /// 选 brief 时放开的类型。brief 什么格式都可能来，宁可多给几个扩展名。
    static var pickableTypes: [UTType] {
        var types: [UTType] = [.pdf, .rtf, .plainText, .html, .image]
        for ext in ["docx", "doc", "pptx", "ppt", "odt", "key", "pages", "md"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

// MARK: - 中间产物

/// brief 在左栏里的样子：按原文件的顺序排的文字和图片。
enum BriefBlock: Sendable, Equatable {
    case heading(String)
    case text(String)
    case image(path: String, caption: String)
    /// 一张新的“页”（PPT 的每一页、或者人为分页）。
    case pageBreak
}

/// 可以送给本地模型看的候选图：PDF 渲染出来的页，或者 Word / PPT 里内嵌的图片。
struct BriefCandidate: Sendable, Equatable {
    var label: String
    var path: String
    var pageIndex: Int?
    /// 这张图所在那一页的文字。挑参考图时要靠它判断「这页是不是产品参数页」——
    /// 品牌页、理念页、达人页上的照片是氛围图，产品参数页上的才是这一版产品的外观。
    var pageText: String = ""
}

/// 读进来的 brief。
struct BriefSource: Sendable {
    var url: URL
    var format: BriefFormat
    /// 全部文字，送给模型判断产品是什么。
    var text: String
    var blocks: [BriefBlock]
    var candidates: [BriefCandidate]
    /// 左栏显示的 PDF：原文件就是 PDF 时是它自己，其它格式是本地渲染出来的。
    var previewPDF: URL
}

enum BriefSourceError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let text): text
        }
    }
}

// MARK: - 读取

/// 把任意格式的 brief 读成「文字 + 图 + 一个能看的 PDF」。
///
/// 全部在本机完成：PDF 用 PDFKit，Word / PPT 是 zip 包，自己解包读 XML，
/// 图片直接从包里取出来。不需要装 Office，也不联网。
enum BriefSourceReader {
    static func read(_ url: URL) throws -> BriefSource {
        let format = BriefFormat(url: url)
        let work = FileManager.default.temporaryDirectory
            .appending(path: "codecut-brief-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        switch format {
        case .pdf:
            return try pdfSource(url)
        case .docx:
            return try wordSource(url, work: work)
        case .pptx:
            return try slideSource(url, work: work)
        case .image:
            return try imageSource(url, work: work)
        case .rtf, .html, .text:
            return try richTextSource(url, work: work, format: format)
        case .doc, .ppt, .unknown:
            // 老版二进制格式（.doc/.ppt）自己解不了，让系统帮忙转一次文本。
            return try convertedSource(url, work: work, format: format)
        }
    }

    // MARK: PDF

    private static func pdfSource(_ url: URL) throws -> BriefSource {
        guard let document = PDFDocument(url: url) else {
            throw BriefSourceError.unreadable("打不开这个 PDF。")
        }
        let work = FileManager.default.temporaryDirectory
            .appending(path: "codecut-brief-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var text = ""
        var blocks: [BriefBlock] = []
        var candidates: [BriefCandidate] = []
        for index in 0..<min(document.pageCount, 60) {
            let page = document.page(at: index)
            let pageText = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text += pageText + "\n"
            if !pageText.isEmpty {
                blocks.append(.heading("第 \(index + 1) 页"))
                blocks.append(.text(pageText))
            }
            // 每一页都渲染一张图：文字少、图多的页最容易是产品图页，模型自己挑。
            guard index < 60, let page else { continue }
            // 优先抠这一页里真正的照片；整页渲染只是兜底。
            let photos = pdfPhotos(from: page)
            if !photos.isEmpty {
                for (shot, photo) in photos.enumerated() {
                    let file = work.appending(path: "p\(index + 1)-shot\(shot + 1).jpg")
                    try? photo.write(to: file)
                    candidates.append(BriefCandidate(label: "第 \(index + 1) 页 第 \(shot + 1) 张图", path: file.path, pageIndex: index + 1, pageText: pageText))
                }
            } else {
                guard index < 40, let image = renderPDFPage(page, width: 900),
                      let data = LocalVLM.jpegData(from: image, maxWidth: 900) else { continue }
                let file = work.appending(path: "page-\(index + 1).jpg")
                try? data.write(to: file)
                candidates.append(BriefCandidate(label: "第 \(index + 1) 页", path: file.path, pageIndex: index + 1, pageText: pageText))
            }
        }
        return BriefSource(url: url, format: .pdf, text: text, blocks: blocks, candidates: candidates, previewPDF: url)
    }

    /// 把 PDF 的一页画成位图。给模型看、当参考图都用它。
    static func renderPDFPage(_ page: PDFPage, width: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = width / bounds.width
        let size = CGSize(width: width, height: bounds.height * scale)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// 把这一页里真正的照片抠出来。
    ///
    /// 整页渲染当候选图，模型看到的是一整页排版（标题、正文、页脚全在），
    /// 「产品照片」就变成了页面截图。这里顺着内容流找到真正的图片对象，
    /// 记下它在页面上的位置，再从高分辨率页面里把那一块裁出来。
    static func pdfPhotos(from page: PDFPage, targetWidth: CGFloat = 900) -> [Data] {
        let placements = PDFImageScanner.placements(in: page)
        guard !placements.isEmpty else { return [] }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return [] }

        // PDF 里本来就是 JPEG 的图，直接拿原始照片字节 —— 清晰、也不会把压在
        // 图上的标题和说明文字一起抠进来。
        var photos: [Data] = []
        var needsCrop: [PDFImageScanner.Placement] = []
        for placement in placements {
            if let data = placement.photoData {
                photos.append(data)
            } else {
                needsCrop.append(placement)
            }
        }
        guard !needsCrop.isEmpty else { return photos }

        // 剩下的（压缩位图、矢量蒙版等）从页面渲染里裁。
        // 每一张图至少要有 targetWidth 那么宽，太小的话模型看不清产品细节。
        let needed = needsCrop.map { targetWidth / max($0.rect.width, 1) }.max() ?? 1
        let scale = min(max(needed, 1.5), 4)
        guard let rendered = renderPDFPage(page, width: box.width * scale) else { return [] }
        let renderedScale = CGFloat(rendered.width) / box.width
        let canvas = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)

        for placement in needsCrop {
            let rect = placement.rect
            let crop = CGRect(
                x: (rect.minX - box.minX) * renderedScale,
                // 渲染出来的位图是上下颠倒的，纵向要翻过来。
                y: (box.maxY - rect.maxY) * renderedScale,
                width: rect.width * renderedScale,
                height: rect.height * renderedScale
            ).intersection(canvas)
            guard crop.width >= 100, crop.height >= 100,
                  let piece = rendered.cropping(to: crop.integral),
                  let data = LocalVLM.jpegData(from: piece, maxWidth: 1600) else { continue }
            photos.append(data)
        }
        return photos
    }

    // MARK: Word

    private static func wordSource(_ url: URL, work: URL) throws -> BriefSource {
        let extracted = work.appending(path: "unzipped", directoryHint: .isDirectory)
        try BriefZip(url: url).extract(to: extracted)
        let documentXML = extracted.appending(path: "word/document.xml")
        guard let xml = try? String(contentsOf: documentXML, encoding: .utf8) else {
            return try convertedSource(url, work: work, format: .docx)
        }
        let relationships = OfficeRelations.load(extracted.appending(path: "word/_rels/document.xml.rels"))
        let parsed = try WordDocumentParser.parse(xml)

        var blocks: [BriefBlock] = []
        var textParts: [String] = []
        for paragraph in parsed.paragraphs {
            let body = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                if paragraph.headingLevel > 0 { blocks.append(.heading(body)) } else { blocks.append(.text(body)) }
                textParts.append(body)
            }
            for relationship in paragraph.images {
                guard let path = relationships.filePath(for: relationship, base: "word", in: extracted) else { continue }
                guard FileManager.default.fileExists(atPath: path) else { continue }
                blocks.append(.image(path: path, caption: url.deletingPathExtension().lastPathComponent))
            }
        }
        let candidates = imageCandidates(in: extracted.appending(path: "word", directoryHint: .isDirectory), label: "文档里的图")
        let preview = work.appending(path: "preview.pdf")
        try BriefPDFRenderer.write(blocks.isEmpty ? [.text("（这份文档里没有可提取的文字，看图吧。）")] : blocks,
                                   pageSize: CGSize(width: 595, height: 842), to: preview)
        return BriefSource(url: url, format: .docx, text: textParts.joined(separator: "\n"),
                           blocks: blocks, candidates: candidates, previewPDF: preview)
    }

    // MARK: PPT

    private static func slideSource(_ url: URL, work: URL) throws -> BriefSource {
        let extracted = work.appending(path: "unzipped", directoryHint: .isDirectory)
        try BriefZip(url: url).extract(to: extracted)
        let slides = (try? FileManager.default.contentsOfDirectory(at: extracted.appending(path: "ppt/slides", directoryHint: .isDirectory),
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "xml" && $0.lastPathComponent.hasPrefix("slide") }
            .sorted { slideNumber($0.lastPathComponent) < slideNumber($1.lastPathComponent) } ?? []
        guard !slides.isEmpty else {
            return try convertedSource(url, work: work, format: .pptx)
        }

        var blocks: [BriefBlock] = []
        var textParts: [String] = []
        var candidates: [BriefCandidate] = []
        for (order, slide) in slides.enumerated() {
            let index = order + 1
            guard let xml = try? String(contentsOf: slide, encoding: .utf8) else { continue }
            let relationships = OfficeRelations.load(
                slide.deletingLastPathComponent().appending(path: "_rels/\(slide.lastPathComponent).rels")
            )
            let parsed = try SlideParser.parse(xml)
            if index > 1 { blocks.append(.pageBreak) }
            blocks.append(.heading("第 \(index) 页"))
            var slideText: [String] = []
            if !parsed.title.isEmpty {
                blocks.append(.heading(parsed.title))
                slideText.append(parsed.title)
            }
            for line in parsed.lines where !line.isEmpty {
                blocks.append(.text(line))
                slideText.append(line)
            }
            for (photo, relationship) in parsed.images.enumerated() {
                // 幻灯片的关系表是相对 ppt/slides/ 写的，图片一般落在 ppt/media/。
                guard let path = relationships.filePath(for: relationship, base: "ppt/slides", in: extracted),
                      FileManager.default.fileExists(atPath: path) else { continue }
                blocks.append(.image(path: path, caption: "第 \(index) 页的图"))
                candidates.append(BriefCandidate(label: "第 \(index) 页第 \(photo + 1) 张图", path: path, pageIndex: index, pageText: slideText.joined(separator: "\n")))
            }
            textParts.append("第 \(index) 页\n" + slideText.joined(separator: "\n"))
        }
        let preview = work.appending(path: "preview.pdf")
        try BriefPDFRenderer.write(blocks, pageSize: CGSize(width: 960, height: 540), to: preview)
        return BriefSource(url: url, format: .pptx, text: textParts.joined(separator: "\n\n"),
                           blocks: blocks, candidates: candidates, previewPDF: preview)
    }

    private static func slideNumber(_ name: String) -> Int {
        Int(name.filter(\.isNumber)) ?? 0
    }

    // MARK: 图片 / 富文本

    private static func imageSource(_ url: URL, work: URL) throws -> BriefSource {
        let preview = work.appending(path: "preview.pdf")
        try BriefPDFRenderer.write([.image(path: url.path, caption: url.deletingPathExtension().lastPathComponent)],
                                   pageSize: CGSize(width: 595, height: 842), to: preview)
        return BriefSource(url: url, format: .image, text: "",
                           blocks: [.image(path: url.path, caption: url.lastPathComponent)],
                           candidates: [BriefCandidate(label: "图片本身", path: url.path, pageIndex: 1)],
                           previewPDF: preview)
    }

    private static func richTextSource(_ url: URL, work: URL, format: BriefFormat) throws -> BriefSource {
        let attributed: NSAttributedString
        switch format {
        case .rtf:
            attributed = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil)) ?? NSAttributedString(string: "")
        case .html:
            attributed = (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil))
                ?? NSAttributedString(string: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        default:
            attributed = NSAttributedString(string: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
        let built = try blocks(from: attributed, work: work)
        let preview = work.appending(path: "preview.pdf")
        try BriefPDFRenderer.write(built.blocks.isEmpty ? [.text("（这份文件里没有可提取的文字。）")] : built.blocks,
                                   pageSize: CGSize(width: 595, height: 842), to: preview)
        return BriefSource(url: url, format: format, text: built.text, blocks: built.blocks,
                           candidates: built.candidates, previewPDF: preview)
    }

    /// 富文本（含 .doc 转出来的 RTF）按顺序拆成文字和图片，图片顺手落盘。
    private static func blocks(from attributed: NSAttributedString, work: URL) throws -> (blocks: [BriefBlock], text: String, candidates: [BriefCandidate]) {
        var blocks: [BriefBlock] = []
        var text = ""
        var candidates: [BriefCandidate] = []
        let string = attributed.string as NSString
        var paragraph = ""

        // 先把附件的位置记下来，剩下的才是正文 —— 这样不管上面那段有没有附件都读得对。
        var attachments: [(range: NSRange, attachment: NSTextAttachment)] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachments.append((range, attachment))
        }

        func flush() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.text(trimmed))
                text += trimmed + "\n"
            }
            paragraph = ""
        }

        var cursor = 0
        for item in attachments {
            if item.range.location > cursor {
                paragraph += string.substring(with: NSRange(location: cursor, length: item.range.location - cursor))
            }
            cursor = NSMaxRange(item.range)
            guard let image = item.attachment.image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = LocalVLM.jpegData(from: cg, maxWidth: 1200) else { continue }
            flush()
            let file = work.appending(path: "media-\(candidates.count + 1).jpg")
            try? data.write(to: file)
            let caption = "文件里的图 \(candidates.count + 1)"
            blocks.append(.image(path: file.path, caption: caption))
            candidates.append(BriefCandidate(label: caption, path: file.path, pageIndex: nil))
        }
        if cursor < string.length {
            paragraph += string.substring(from: cursor)
        }
        flush()
        return (blocks, text, candidates)
    }

    // MARK: 兜底（.doc / .ppt 这类老格式）

    /// 自己解不了的格式，交给系统的 textutil 转一次纯文本。
    /// 拿不到图，但至少能读文字，不至于整份 brief 白给。
    private static func convertedSource(_ url: URL, work: URL, format: BriefFormat) throws -> BriefSource {
        let output = work.appending(path: "converted.rtf")
        let converted = runTextutil(url: url, to: output)
        var attributed = converted ? (try? NSAttributedString(url: output, options: [:], documentAttributes: nil)) : nil
        if attributed == nil, let plain = runTextutil(url: url, to: work.appending(path: "converted.txt")) ? try? String(contentsOf: work.appending(path: "converted.txt"), encoding: .utf8) : nil {
            attributed = NSAttributedString(string: plain)
        }
        guard let attributed, attributed.length > 0 else {
            throw BriefSourceError.unreadable("这个格式（.\(url.pathExtension)）本机读不了。把它另存成 PDF、Word（.docx）或 PPT（.pptx）再给我。")
        }
        let built = try blocks(from: attributed, work: work)
        let preview = work.appending(path: "preview.pdf")
        try BriefPDFRenderer.write(built.blocks.isEmpty ? [.text("（这份文件里没有可提取的文字。）")] : built.blocks,
                                   pageSize: CGSize(width: 595, height: 842), to: preview)
        return BriefSource(url: url, format: format, text: built.text, blocks: built.blocks,
                           candidates: built.candidates, previewPDF: preview)
    }

    /// textutil 转出来的图片会留在原地，这里按体积挑出像产品照的那几张。
    private static func imageCandidates(in folder: URL, label: String) -> [BriefCandidate] {
        // Word 的图在 word/media/ 里，PPT 的在 ppt/media/ 里，得往里翻一层。
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?
            .allObjects as? [URL]) ?? []
        let images = files
            .filter { ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp"].contains($0.pathExtension.lowercased()) }
            .sorted { size(of: $0) > size(of: $1) }
        return images.enumerated().map { index, file in
            BriefCandidate(label: "\(label) \(index + 1)", path: file.path, pageIndex: nil)
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func runTextutil(url: URL, to output: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", output.pathExtension, "-output", output.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path)
        } catch {
            return false
        }
    }
}

// MARK: - Office 关系表（rId → 文件）

/// `.docx` / `.pptx` 里的图片不是直接写在正文里的，正文只放一个 rId，
/// 真正的文件名要去 `_rels/*.rels` 里查。这个类型就是做这件事。
struct OfficeRelations: Sendable {
    private var targets: [String: String] = [:]

    static func load(_ url: URL) -> OfficeRelations {
        var relations = OfficeRelations()
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return relations }
        try? StreamingXML.walk(xml) { event in
            guard event.kind == .start, event.name == "Relationship",
                  let id = event.attributes["Id"], let target = event.attributes["Target"] else { return }
            relations.targets[id] = target
        }
        return relations
    }

    /// 把 `../media/image1.png` 这种相对路径还原成解包目录里的绝对路径。
    /// `base` 是写这条关系的部件所在目录（Word 是 `word`，PPT 是 `ppt/slides`）。
    func filePath(for relationship: String, base: String, in root: URL) -> String? {
        guard let target = targets[relationship], !target.hasPrefix("http") else { return nil }
        let components = target.components(separatedBy: "/")
        var folder = base.components(separatedBy: "/")
        for component in components {
            if component == ".." { if !folder.isEmpty { folder.removeLast() } }
            else if component != "." { folder.append(component) }
        }
        return root.appending(path: folder.joined(separator: "/")).path
    }
}

// MARK: - 流式 XML

/// 极简 XML 事件流：只关心元素名、属性和文字，够解析 Office 的 document.xml / slideN.xml。
enum StreamingXML {
    struct Event {
        enum Kind { case start, end, text }
        var kind: Kind
        var name: String
        var attributes: [String: String]
        var text: String
    }

    static func walk(_ xml: String, _ handle: @escaping (Event) -> Void) throws {
        guard let data = xml.data(using: .utf8) else { throw BriefSourceError.unreadable("XML 不是 UTF-8。") }
        let parser = XMLParser(data: data)
        let delegate = Delegate(handle: handle)
        parser.delegate = delegate
        // 打开命名空间处理，元素名和属性名才会去掉 `w:` `a:` `r:` 这些前缀，
        // 解析时只认本地名，两种写法都能对上。
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let handle: (Event) -> Void
        init(handle: @escaping (Event) -> Void) { self.handle = handle }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            handle(Event(kind: .start, name: elementName, attributes: attributes, text: ""))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            handle(Event(kind: .end, name: elementName, attributes: [:], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            handle(Event(kind: .text, name: "", attributes: [:], text: string))
        }
    }
}

// MARK: - 读取 zip

/// 只读的 zip：Office 文件（.docx / .pptx）就是一个 zip 包。
/// 不解压也能列出目录，需要哪个文件取哪个 —— 一份 50MB 的 PPT 不用整包展开。
struct BriefZip {
    private struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [Entry]

    init(url: URL) throws {
        let raw: Data
        do {
            raw = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BriefSourceError.unreadable("读不了这个文件：\(error.localizedDescription)")
        }
        data = raw
        entries = try Self.centralDirectory(in: raw)
    }

    var names: [String] { entries.map(\.name) }

    func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }

    func data(for name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw BriefSourceError.unreadable("包里没有 \(name)。")
        }
        return try Self.payload(of: entry, in: data)
    }

    /// 整包解到磁盘。图片、XML 都落地，后面按路径取。
    func extract(to folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries where !entry.name.hasSuffix("/") {
            guard !entry.name.hasPrefix("__MACOSX") else { continue }
            let target = folder.appending(path: entry.name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.payload(of: entry, in: data).write(to: target)
        }
    }

    // MARK: 解析

    private static func centralDirectory(in data: Data) throws -> [Entry] {
        let signature: UInt32 = 0x0605_4B50
        let searchLimit = min(data.count, 66_000)
        var endOffset = -1
        var cursor = data.count - 22
        while cursor >= data.count - searchLimit, cursor >= 0 {
            if data.readUInt32(at: cursor) == signature { endOffset = cursor; break }
            cursor -= 1
        }
        guard endOffset >= 0 else { throw BriefSourceError.unreadable("这个文件不是 zip 包（Office 文件损坏或不是 .docx/.pptx）。") }
        let count = Int(data.readUInt16(at: endOffset + 10))
        let start = Int(data.readUInt32(at: endOffset + 16))
        var entries: [Entry] = []
        var offset = start
        for _ in 0..<count {
            guard offset >= 0, offset + 46 <= data.count, data.readUInt32(at: offset) == 0x0201_4B50 else { break }
            let method = data.readUInt16(at: offset + 10)
            let compressed = Int(data.readUInt32(at: offset + 20))
            let uncompressed = Int(data.readUInt32(at: offset + 24))
            let nameLength = Int(data.readUInt16(at: offset + 28))
            let extraLength = Int(data.readUInt16(at: offset + 30))
            let commentLength = Int(data.readUInt16(at: offset + 32))
            let localOffset = Int(data.readUInt32(at: offset + 42))
            let name = String(decoding: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)), as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func payload(of entry: Entry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.readUInt32(at: header) == 0x0403_4B50 else {
            throw BriefSourceError.unreadable("压缩包里的 \(entry.name) 读不出来。")
        }
        let nameLength = Int(data.readUInt16(at: header + 26))
        let extraLength = Int(data.readUInt16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else {
            throw BriefSourceError.unreadable("压缩包里的 \(entry.name) 超出文件范围。")
        }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expected: entry.uncompressedSize, name: entry.name)
        default:
            throw BriefSourceError.unreadable("\(entry.name) 用了不支持的压缩方式（\(entry.method)）。")
        }
    }

    private static func inflate(_ payload: Data, expected: Int, name: String) throws -> Data {
        if payload.isEmpty { return Data() }
        let capacity = max(expected, 1)
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, capacity, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else {
            throw BriefSourceError.unreadable("\(name) 解压失败。")
        }
        return output.prefix(written)
    }
}

/// 顺着 PDF 内容流找出页面上每一张被画出来的图片，以及它在页面里的位置。
///
/// PDF 没有「图片列表」这种现成的东西：图片是画在页面上的对象，
/// 位置由内容流里的矩阵决定。所以只能自己过一遍 `q / Q / cm / Do`。
/// 顺着 PDF 内容流找出页面上每一张被画出来的图片，以及它在页面里的位置。
///
/// PDF 没有「图片列表」这种现成的东西：图片是画在页面上的对象，
/// 位置由内容流里的矩阵决定。所以只能自己过一遍 `q / Q / cm / Do`。
/// 这里直接扫内容流字节，不用 CGPDFScanner —— 那套 C 回调在 Swift 6 下会把编译器搞崩。
enum PDFImageScanner {
    struct Placement {
        var name: String
        /// 这张图在页面坐标系（左下角为原点）里占的区域。
        var rect: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
        /// PDF 里本来就是 JPEG 的图：原始照片字节，可以直接存盘。
        var photoData: Data?
    }

    private final class Collector {
        let minPixels: Int
        let limit: Int
        var placements: [Placement] = []
        var seen = Set<String>()

        init(minPixels: Int, limit: Int) {
            self.minPixels = minPixels
            self.limit = limit
        }
    }

    private enum Operand {
        case number(CGFloat)
        case name(String)
    }

    private enum Token {
        case number(CGFloat)
        case name(String)
        case keyword(String)
        case skipped
    }

    static func placements(in page: PDFPage, minPixels: Int = 240, limit: Int = 24) -> [Placement] {
        guard let pageRef = page.pageRef, let dictionary = pageRef.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let collector = Collector(minPixels: minPixels, limit: limit)
        var ctm = CGAffineTransform.identity
        for stream in contentStreams(of: dictionary) {
            guard let bytes = bytes(of: stream) else { continue }
            run(bytes: bytes, resources: resources, base: .identity, ctm: &ctm, depth: 0, collector: collector)
        }
        return collector.placements
    }

    // MARK: 内容流

    private static func run(bytes data: [UInt8], resources: CGPDFDictionaryRef?, base: CGAffineTransform, ctm: inout CGAffineTransform, depth: Int, collector: Collector) {
        guard depth < 4, collector.placements.count < collector.limit else { return }
        var index = 0
        var stack: [CGAffineTransform] = []
        var operands: [Operand] = []
        while let token = nextToken(data, &index) {
            switch token {
            case .number(let value):
                operands.append(.number(value))
            case .name(let name):
                operands.append(.name(name))
            case .skipped:
                operands.removeAll()
            case .keyword(let keyword):
                switch keyword {
                case "q":
                    stack.append(ctm)
                case "Q":
                    if let last = stack.popLast() { ctm = last }
                case "cm":
                    if let matrix = matrix(from: operands) {
                        ctm = CGAffineTransformConcat(matrix, ctm)
                    }
                case "Do":
                    if case .name(let name) = operands.last {
                        handleDo(name, resources: resources, base: base, ctm: ctm, depth: depth, collector: collector)
                    }
                default:
                    break
                }
                operands.removeAll()
            }
        }
    }

    private static func handleDo(_ name: String, resources: CGPDFDictionaryRef?, base: CGAffineTransform, ctm: CGAffineTransform, depth: Int, collector: Collector) {
        guard let resources else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        var xobjectStream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(xobjects, name, &xobjectStream), let xobjectStream,
              let dictionary = CGPDFStreamGetDictionary(xobjectStream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }

        let effective = CGAffineTransformConcat(ctm, base)
        switch String(cString: subtype) {
        case "Image":
            var width = 0
            var height = 0
            CGPDFDictionaryGetInteger(dictionary, "Width", &width)
            CGPDFDictionaryGetInteger(dictionary, "Height", &height)
            guard width >= collector.minPixels, height >= collector.minPixels else { return }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(effective)
            guard rect.width >= 24, rect.height >= 24 else { return }
            let key = "\(name)@\(width)x\(height)"
            guard collector.seen.insert(key).inserted else { return }
            collector.placements.append(
                Placement(name: key, rect: rect, pixelWidth: width, pixelHeight: height, photoData: jpegData(of: xobjectStream))
            )

        case "Form":
            // 有些设计稿把图片套在表单对象里，要再钻一层。
            var formResources: CGPDFDictionaryRef?
            if !CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources) {
                formResources = resources
            }
            guard let formResources, let nested = bytes(of: xobjectStream) else { return }
            var nestedCTM = CGAffineTransform.identity
            run(
                bytes: nested,
                resources: formResources,
                base: CGAffineTransformConcat(formMatrix(dictionary), effective),
                ctm: &nestedCTM,
                depth: depth + 1,
                collector: collector
            )

        default:
            break
        }
    }

    private static func formMatrix(_ dictionary: CGPDFDictionaryRef) -> CGAffineTransform {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 else {
            return .identity
        }
        var values: [CGFloat] = []
        for index in 0..<6 {
            var number: CGPDFReal = 0
            if CGPDFArrayGetNumber(array, index, &number) { values.append(CGFloat(number)) }
        }
        guard values.count == 6 else { return .identity }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    private static func matrix(from operands: [Operand]) -> CGAffineTransform? {
        var numbers: [CGFloat] = []
        for operand in operands.reversed() {
            guard case .number(let value) = operand else { break }
            numbers.append(value)
            if numbers.count == 6 { break }
        }
        guard numbers.count == 6 else { return nil }
        // 栈顶是 f，往上依次是 e d c b a。
        return CGAffineTransform(
            a: numbers[5], b: numbers[4], c: numbers[3],
            d: numbers[2], tx: numbers[1], ty: numbers[0]
        )
    }

    private static func contentStreams(of dictionary: CGPDFDictionaryRef) -> [CGPDFStreamRef] {
        var single: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &single), let single { return [single] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return [] }
        var result: [CGPDFStreamRef] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var item: CGPDFStreamRef?
            if CGPDFArrayGetStream(array, index, &item), let item { result.append(item) }
        }
        return result
    }

    private static func bytes(of stream: CGPDFStreamRef) -> [UInt8]? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        return [UInt8](data as Data)
    }

    /// 只有「这个流本来就是一张 JPEG」时才交出字节 —— 否则交给页面渲染去裁。
    private static func jpegData(of stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format != .raw else { return nil }
        var bytes = data as Data
        guard bytes.count > 4096 else { return nil }
        // 认得出来的 JPEG 头才收，别的格式（比如 JP2）回去走裁剪那条路。
        guard bytes.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) else { return nil }
        bytes = Data(bytes)
        return bytes
    }

    // MARK: 词法

    private static func nextToken(_ data: [UInt8], _ index: inout Int) -> Token? {
        skipSpace(data, &index)
        guard index < data.count else { return nil }
        let byte = data[index]
        switch byte {
        case 0x2F: // /Name
            index += 1
            let start = index
            while index < data.count, !isDelimiter(data[index]) { index += 1 }
            return .name(String(decoding: data[start..<index], as: UTF8.self))
        case 0x28: // 字面字符串
            skipLiteralString(data, &index)
            return .skipped
        case 0x3C: // << 字典 / < 十六进制串
            if index + 1 < data.count, data[index + 1] == 0x3C {
                skipDictionary(data, &index)
            } else {
                skipHexString(data, &index)
            }
            return .skipped
        case 0x5B: // 数组
            skipArray(data, &index)
            return .skipped
        default:
            let start = index
            while index < data.count, !isDelimiter(data[index]) { index += 1 }
            let text = String(decoding: data[start..<index], as: UTF8.self)
            if text == "BI" {
                skipInlineImage(data, &index)
                return .skipped
            }
            if let value = Double(text) { return .number(CGFloat(value)) }
            return .keyword(text)
        }
    }

    private static func skipSpace(_ data: [UInt8], _ index: inout Int) {
        while index < data.count {
            let byte = data[index]
            if isWhitespace(byte) {
                index += 1
            } else if byte == 0x25 { // % 注释
                while index < data.count, data[index] != 0x0A, data[index] != 0x0D { index += 1 }
            } else {
                return
            }
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E
            || byte == 0x5B || byte == 0x5D || byte == 0x7B || byte == 0x7D || byte == 0x2F || byte == 0x25
    }

    private static func skipLiteralString(_ data: [UInt8], _ index: inout Int) {
        var depth = 0
        while index < data.count {
            let byte = data[index]
            if byte == 0x5C { // 反斜杠转义
                index += 2
                continue
            }
            if byte == 0x28 { depth += 1 }
            if byte == 0x29 {
                depth -= 1
                if depth <= 0 { index += 1; return }
            }
            index += 1
        }
    }

    private static func skipHexString(_ data: [UInt8], _ index: inout Int) {
        index += 1
        while index < data.count, data[index] != 0x3E { index += 1 }
        index += 1
    }

    private static func skipDictionary(_ data: [UInt8], _ index: inout Int) {
        var depth = 0
        while index < data.count {
            let byte = data[index]
            if byte == 0x3C, index + 1 < data.count, data[index + 1] == 0x3C {
                depth += 1
                index += 2
                continue
            }
            if byte == 0x3E, index + 1 < data.count, data[index + 1] == 0x3E {
                depth -= 1
                index += 2
                if depth <= 0 { return }
                continue
            }
            if byte == 0x28 { skipLiteralString(data, &index); continue }
            index += 1
        }
    }

    private static func skipArray(_ data: [UInt8], _ index: inout Int) {
        var depth = 0
        while index < data.count {
            let byte = data[index]
            if byte == 0x5B { depth += 1 }
            if byte == 0x5D {
                depth -= 1
                index += 1
                if depth <= 0 { return }
                continue
            }
            if byte == 0x28 { skipLiteralString(data, &index); continue }
            index += 1
        }
    }

    /// 内联图（BI … ID 二进制 EI）：二进制里什么字节都可能有，只能按分隔符找结尾。
    private static func skipInlineImage(_ data: [UInt8], _ index: inout Int) {
        var cursor = index
        while cursor + 1 < data.count {
            if data[cursor] == 0x49, data[cursor + 1] == 0x44,
               cursor == 0 || isWhitespace(data[cursor - 1]) {
                cursor += 2
                break
            }
            cursor += 1
        }
        cursor += 1
        while cursor + 1 < data.count {
            if data[cursor] == 0x45, data[cursor + 1] == 0x49, isWhitespace(data[cursor - 1]) {
                cursor += 2
                index = cursor
                return
            }
            cursor += 1
        }
        index = data.count
    }
}


private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
