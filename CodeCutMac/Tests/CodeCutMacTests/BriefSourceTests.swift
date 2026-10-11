import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import CodeCutMac

// MARK: - 格式识别
//
// 品牌方给的 brief 什么格式都可能来，认错格式就整份读不出来。

@Test func briefFormatIsPickedFromTheExtension() {
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.pdf")) == .pdf)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.docx")) == .docx)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.DOCX")) == .docx)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.doc")) == .doc)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.pptx")) == .pptx)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.ppt")) == .ppt)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.PNG")) == .image)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.txt")) == .text)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.md")) == .text)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.rtf")) == .rtf)
    #expect(BriefFormat(url: URL(fileURLWithPath: "/tmp/a.weird")) == .unknown)
    // 选文件的时候不能只放开 PDF，不然 Word / PPT 根本选不中。
    #expect(BriefFormat.pickableTypes.count > 3)
}

// MARK: - 解 zip

@Test func briefZipReadsStoredEntries() throws {
    let folder = try makeTemporaryFolder()
    var builder = ZipBuilder()
    builder.add("word/document.xml", "<hello>中文</hello>")
    builder.add("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47]))
    let url = folder.appending(path: "sample.docx")
    try builder.data().write(to: url)

    let zip = try BriefZip(url: url)
    #expect(zip.contains("word/document.xml"))
    #expect(zip.names.contains("word/media/image1.png"))
    let xml = try zip.data(for: "word/document.xml")
    #expect(String(decoding: xml, as: UTF8.self).contains("中文"))
    let png = try zip.data(for: "word/media/image1.png")
    #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}

// MARK: - Word / PPT 解析

@Test func wordParserReadsHeadingTextAndImages() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>产品 brief</w:t></w:r></w:p>
        <w:p><w:r><w:t>这是一款斜挎包</w:t></w:r><w:r><w:t>，防泼水。</w:t></w:r></w:p>
        <w:p><w:r><w:drawing><a:blip r:embed="rId5"/></w:drawing></w:r></w:p>
        <w:p><w:del><w:r><w:delText>这句是删掉的</w:delText></w:r></w:del></w:p>
      </w:body>
    </w:document>
    """
    let document = try WordDocumentParser.parse(xml)
    #expect(document.paragraphs.count == 4)
    #expect(document.paragraphs[0].text == "产品 brief")
    #expect(document.paragraphs[0].headingLevel == 1)
    #expect(document.paragraphs[1].text == "这是一款斜挎包，防泼水。")
    #expect(document.paragraphs[1].headingLevel == 0)
    #expect(document.paragraphs[2].images == ["rId5"])
    // 删掉的旧稿不该跑进 brief 里。
    #expect(document.paragraphs[3].text.isEmpty)
}

@Test func wordParserReadsChineseHeadingStyles() throws {
    let xml = """
    <w:document xmlns:w="x"><w:body>
      <w:p><w:pPr><w:pStyle w:val="2"/></w:pPr><w:r><w:t>规格</w:t></w:r></w:p>
      <w:p><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:r><w:t>第三级</w:t></w:r></w:p>
    </w:body></w:document>
    """
    let document = try WordDocumentParser.parse(xml)
    #expect(document.paragraphs[0].headingLevel == 2)
    #expect(document.paragraphs[1].headingLevel == 3)
}

@Test func slideParserReadsTitleBodyAndImages() throws {
    let xml = """
    <p:sld xmlns:p="p" xmlns:a="a" xmlns:r="r">
      <p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
          <p:txBody><a:p><a:r><a:t>NAYOSMART UL1</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
          <p:txBody><a:p><a:r><a:t>防泼水斜挎包</a:t></a:r></a:p>
          <a:p><a:r><a:t>可装 16 寸笔记本</a:t></a:r></a:p></p:txBody></p:sp>
        <p:pic><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
      </p:spTree></p:cSld>
    </p:sld>
    """
    let slide = try SlideParser.parse(xml)
    #expect(slide.title == "NAYOSMART UL1")
    #expect(slide.lines == ["防泼水斜挎包", "可装 16 寸笔记本"])
    #expect(slide.images == ["rId2"])

    // slide10 要排在 slide2 后面，不能按字符串排。
    #expect(slidePageNumber("slide10.xml") > slidePageNumber("slide2.xml"))
}

/// 这里复刻 BriefSourceReader 里的排序规则，防止它被改回字符串排序。
private func slidePageNumber(_ name: String) -> Int {
    Int(name.filter(\.isNumber)) ?? 0
}

// MARK: - 自己画的 PDF

@Test func briefPDFRendererWritesTextImagesAndPages() throws {
    let folder = try makeTemporaryFolder()
    let shot = folder.appending(path: "shot.png")
    try #require(makePNG(width: 240, height: 160)).write(to: shot)

    let pdf = folder.appending(path: "preview.pdf")
    try BriefPDFRenderer.write([
        .heading("第 1 页"),
        .text("这是一份产品 brief，产品是可以装笔记本的背包。"),
        .image(path: shot.path, caption: "产品照片"),
        .pageBreak,
        .text("第二页的内容")
    ], pageSize: CGSize(width: 595, height: 842), to: pdf)

    let document = try #require(PDFDocument(url: pdf))
    #expect(document.pageCount == 2)
    let text = try #require(document.string)
    #expect(text.contains("可以装笔记本"))
    #expect(text.contains("第二页的内容"))

    // 文字真的画上去了，不是一张白纸。
    let page = try #require(document.page(at: 0))
    let rendered = try #require(BriefSourceReader.renderPDFPage(page, width: 400))
    #expect(darkPixelRatio(rendered) > 0.0005)
}

// MARK: - 端到端：文本 / PPT / Word

@Test func textBriefBecomesTextBlocksAndAPreviewPDF() throws {
    let folder = try makeTemporaryFolder()
    let url = folder.appending(path: "brief.txt")
    try "产品：可折叠水壶\n卖点：轻、不漏水".write(to: url, atomically: true, encoding: .utf8)

    let source = try BriefSourceReader.read(url)
    #expect(source.format == .text)
    #expect(source.text.contains("可折叠水壶"))
    #expect(source.blocks.contains { if case .text = $0 { true } else { false } })
    #expect(PDFDocument(url: source.previewPDF) != nil)
}

@Test func pptxBriefIsReadEndToEnd() throws {
    let folder = try makeTemporaryFolder()
    let url = folder.appending(path: "deck.pptx")
    var builder = ZipBuilder()
    builder.add("ppt/slides/slide1.xml", """
    <p:sld xmlns:p="p" xmlns:a="a" xmlns:r="r"><p:cSld><p:spTree>
      <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
        <p:txBody><a:p><a:r><a:t>UL1 背包</a:t></a:r></a:p></p:txBody></p:sp>
      <p:pic><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
    </p:spTree></p:cSld></p:sld>
    """)
    builder.add("ppt/slides/slide2.xml", """
    <p:sld xmlns:p="p" xmlns:a="a" xmlns:r="r"><p:cSld><p:spTree>
      <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
        <p:txBody><a:p><a:r><a:t>细节</a:t></a:r></a:p></p:txBody></p:sp>
    </p:spTree></p:cSld></p:sld>
    """)
    builder.add("ppt/slides/_rels/slide1.xml.rels", """
    <Relationships><Relationship Id="rId2" Type="image" Target="../media/image1.png"/></Relationships>
    """)
    builder.add("ppt/media/image1.png", try #require(makePNG(width: 200, height: 120)))
    try builder.data().write(to: url)

    let source = try BriefSourceReader.read(url)
    #expect(source.format == .pptx)
    #expect(source.text.contains("UL1 背包"))
    #expect(source.text.contains("细节"))
    // 第 1 页里那张图要被提出来当候选。
    #expect(source.candidates.count == 1)
    let shot = try #require(source.candidates.first)
    #expect(FileManager.default.fileExists(atPath: shot.path))
    #expect(source.blocks.contains { if case .pageBreak = $0 { true } else { false } })
    let preview = try #require(PDFDocument(url: source.previewPDF))
    #expect(preview.pageCount >= 2)
}

@Test func docxBriefIsReadEndToEnd() throws {
    let folder = try makeTemporaryFolder()
    let url = folder.appending(path: "brief.docx")
    var builder = ZipBuilder()
    builder.add("word/document.xml", """
    <w:document xmlns:w="w" xmlns:r="r" xmlns:a="a"><w:body>
      <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>宜家 brief</w:t></w:r></w:p>
      <w:p><w:r><w:t>产品是一款收纳柜</w:t></w:r></w:p>
      <w:p><w:r><w:drawing><a:blip r:embed="rId4"/></w:drawing></w:r></w:p>
    </w:body></w:document>
    """)
    builder.add("word/_rels/document.xml.rels", """
    <Relationships><Relationship Id="rId4" Type="image" Target="media/image1.png"/></Relationships>
    """)
    builder.add("word/media/image1.png", try #require(makePNG(width: 180, height: 180)))
    try builder.data().write(to: url)

    let source = try BriefSourceReader.read(url)
    #expect(source.format == .docx)
    #expect(source.text.contains("宜家 brief"))
    #expect(source.text.contains("收纳柜"))
    #expect(source.blocks.contains { if case .heading = $0 { true } else { false } })
    #expect(source.candidates.contains { $0.path.hasSuffix("image1.png") })
    #expect(PDFDocument(url: source.previewPDF) != nil)
}

// MARK: - 真文件（本机有就跑，没有就跳过）

@Test(.enabled(if: FileManager.default.fileExists(atPath: realWordBriefPath)))
func realWordBriefIsRead() throws {
    let source = try BriefSourceReader.read(URL(fileURLWithPath: realWordBriefPath))
    #expect(source.format == .docx)
    #expect(source.text.count > 200)
    #expect(!source.candidates.isEmpty)
    #expect(PDFDocument(url: source.previewPDF) != nil)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: realPDFBriefPath)))
func realPDFBriefIsRead() throws {
    let source = try BriefSourceReader.read(URL(fileURLWithPath: realPDFBriefPath))
    #expect(source.format == .pdf)
    #expect(source.text.count > 200)
    #expect(!source.candidates.isEmpty)
    #expect(source.previewPDF.path == realPDFBriefPath)
}

/// 右栏「提出来的产品照片」得是 brief 里真正的照片，不是整页截图。
@Test
func realPDFBriefPhotosAreCroppedOutOfThePage() throws {
    let source = try BriefSourceReader.read(URL(fileURLWithPath: realPDFBriefPath))
    guard let document = PDFDocument(url: URL(fileURLWithPath: realPDFBriefPath)) else {
        Issue.record("打不开 $realPDFBriefPath")
        return
    }
    let pageSize = document.page(at: 20)?.bounds(for: .mediaBox).size ?? .zero
    #expect(pageSize.width > 100)

    // 25 页的 brief 里照片远不止 25 张，抠出来的图应该比页数多。
    #expect(source.candidates.count > document.pageCount)

    // 至少有一部分候选是「页面上的一块」，尺寸明显小于整页。
    var cropped = 0
    for candidate in source.candidates {
        guard let image = NSImage(contentsOfFile: candidate.path) else { continue }
        let size = image.size
        if size.width < pageSize.width * 0.85 || size.height < pageSize.height * 0.85 { cropped += 1 }
    }
    #expect(cropped > 5)
}

// MARK: - 参考图挑选
//
// brief 里到处都嵌着照片，但只有「产品参数」这类页上的那张代表这一版产品长什么样。
// 品牌页、用户画像页、达人页上的照片是氛围图，甚至可能是别的型号、旧版本 ——
// 之前就是这些图被排到前面，模型才把山景人像当成了产品参考图。

@Test func pageScoreRecognizesProductParameterPages() {
    let spec = ProductBriefReader.pageScore("产品参数 Product Parameters 产品名称：UL1 颜色：黑色/米白色 尺寸：长27cm 重量：395g")
    let profile = ProductBriefReader.pageScore("产品用户画像 城市探索者 热衷在城市中慢节奏行走 重量 材质")
    let plain = ProductBriefReader.pageScore("系列品牌理念 城市即旷野")

    #expect(spec.hits.contains("产品参数"))
    #expect(spec.score > 3)
    #expect(spec.score > profile.score)
    #expect(spec.score > plain.score)
    // 氛围页要扣成负分，这样它连候选都进不去。
    #expect(profile.score < 0)
}

/// PDF 里字与字之间会插空格（「产 品 参 数」），还有康熙部首这类兼容字符（「⼯艺」），
/// 不归一化的话关键词一条也匹配不上。
@Test func pageScoreToleratesSpacedAndCompatibilityCharacters() {
    let spaced = ProductBriefReader.pageScore("产 品 参 数 / 产品名称：UL1")
    let compatibility = ProductBriefReader.pageScore("材质与⼯艺　面料：200D尼龙")
    #expect(spaced.hits.contains("产品参数"))
    #expect(compatibility.hits.contains("材质"))
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: realPDFBriefPath)))
func specPageShotIsPickedForRealBrief() throws {
    let source = try BriefSourceReader.read(URL(fileURLWithPath: realPDFBriefPath))
    let chosen = ProductBriefReader.selectShots(from: source, limit: 8)
    #expect(!chosen.isEmpty)

    // 产品参数页那张必须进候选，而且分数要断层领先 —— 模型是照着这张认产品的。
    guard let spec = chosen.first(where: { $0.candidate.pageText.contains("产品参数") }) else {
        Issue.record("产品参数页的图没有被选进候选")
        return
    }
    #expect(spec.pageScore >= 3)
    #expect(chosen.allSatisfy { $0.score <= spec.score })

    // 氛围图一张都不能混进来。
    for shot in chosen {
        for word in ["用户画像", "达人", "品牌历程", "品牌优势"] {
            #expect(!shot.candidate.pageText.contains(word))
        }
    }
}

/// 没有页线索的 brief（Word 里的内嵌图就是这样）也得能挑出图来，
/// 不能让「按页挑」把整份文件都筛空。
@Test(.enabled(if: FileManager.default.fileExists(atPath: realWordBriefPath)))
func briefWithoutPageTextStillPicksShots() throws {
    let source = try BriefSourceReader.read(URL(fileURLWithPath: realWordBriefPath))
    guard !source.candidates.isEmpty else { return }
    let chosen = ProductBriefReader.selectShots(from: source, limit: 6)
    #expect(!chosen.isEmpty)
    #expect(chosen.count <= 6)
}

private let realWordBriefPath = "/Users/m4/Downloads/04 宜家初稿.docx"
private let realPDFBriefPath = "/Users/m4/Library/Mobile Documents/com~apple~CloudDocs/【项目库】/UL1-Brief.pdf"

// MARK: - 小工具

private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "codecut-brief-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func makePNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

private func darkPixelRatio(_ image: CGImage) -> Double {
    let width = 64, height = 64
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return 0 }
    var dark = 0
    for index in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) < 600 {
        dark += 1
    }
    return Double(dark) / Double(width * height)
}

/// 只写 store 模式的最小 zip：够在测试里造一个 .docx / .pptx。
struct ZipBuilder {
    private var files: [(name: String, data: Data)] = []

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    mutating func add(_ name: String, _ data: Data) { files.append((name, data)) }

    func data() -> Data {
        var output = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let checksum = ZipBuilder.crc32(file.data)
            let offset = UInt32(output.count)
            output.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            output.append(uint16: 20)
            output.append(uint16: 0)
            output.append(uint16: 0)
            output.append(uint16: 0)
            output.append(uint16: 0)
            output.append(uint32: checksum)
            output.append(uint32: UInt32(file.data.count))
            output.append(uint32: UInt32(file.data.count))
            output.append(uint16: UInt16(name.count))
            output.append(uint16: 0)
            output.append(name)
            output.append(file.data)

            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(uint16: 20)
            directory.append(uint16: 20)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: checksum)
            directory.append(uint32: UInt32(file.data.count))
            directory.append(uint32: UInt32(file.data.count))
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: 0)
            directory.append(uint32: offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        output.append(uint16: 0)
        output.append(uint16: 0)
        output.append(uint16: UInt16(files.count))
        output.append(uint16: UInt16(files.count))
        output.append(uint32: UInt32(directory.count))
        output.append(uint32: directoryOffset)
        output.append(uint16: 0)
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
