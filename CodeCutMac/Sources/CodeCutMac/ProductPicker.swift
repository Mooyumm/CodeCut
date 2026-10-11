import AppKit
import CoreGraphics
import Foundation

/// 读品牌 brief，生成产品档案。
///
/// brief 什么格式都可能有：PDF、Word、PPT、图片、纯文本 —— 由 BriefSourceReader
/// 统一读成「文字 + 提取出来的图」。这里只做两件事：让本地视觉模型说清这次要推广的
/// 是什么产品，以及提出来的图里哪几张真的拍到了它，把它们存成参考图。
/// 参考图对识别准确率的影响比文字描述大得多，模型能直接看到“要长这样”。
enum ProductBriefReader {
    struct Result: Sendable {
        var profile: ProductProfile
        /// 从 brief 里提出来、可供挑选的图有几张。
        var candidateCount: Int
    }

    /// 一次最多送几张图给模型挑选参考图。
    private static let maxShotsForModel = 8

    /// 一张候选图的挑选依据。
    ///
    /// 只按「画面里非白像素多不多」排是不行的：一份 brief 里几乎每一页都嵌着照片，
    /// 满幅人像和满幅产品照得分一样高，最后就退化成按页码取前几张 —— 结果参考图
    /// 全是封面和理念页的氛围照，模型拿它去认实物自然认不准。
    /// 真正决定哪张能当参考图的是**它挂在哪一页**：产品参数页上的照片才是这一版
    /// 产品长什么样，品牌页、用户画像页、达人页上的照片是氛围图、甚至可能是别的型号。
    struct ShotRank: Sendable, Equatable {
        var candidate: BriefCandidate
        /// 画面本身像不像一张完整照片（非白像素比例）。
        var pictureWeight: Double
        /// 所在那一页像不像「产品参数 / 规格」页。
        var pageScore: Double
        /// 这一页命中的关键词，写在图注里给模型看，也方便自己回头看为什么选了它。
        var hits: [String]

        var score: Double { pictureWeight * 0.6 + pageScore }
    }

    /// 命中就能确认「这是产品参数页」的词。
    private static let specStrongWords = [
        "产品参数", "规格参数", "产品规格", "详细参数", "基本参数", "技术参数",
        "产品名称", "产品信息", "参数表", "规格表",
        "productparameters", "productspecification", "specifications", "specification", "productname"
    ]
    /// 参数页里常见的字段。单独出现说明不了什么（「材质与工艺」页也有），但和强词一起出现更确定。
    private static let specWeakWords = [
        "尺寸", "长宽高", "重量", "净重", "容量", "颜色", "材质", "面料", "型号", "sku",
        "口袋", "扣具", "dimensions", "weight", "material", "capacity", "color"
    ]
    /// 一眼就不是产品页的页：这些页上的照片是氛围图、模特图、达人图，
    /// 拿它们当参考图会把「别的型号」或「旧版本」认成这次要推的产品。
    private static let specNegativeWords = [
        "用户画像", "userprofile", "达人", "博主", "明星", "粉丝量", "合作规范", "拍摄规范",
        "品牌历程", "品牌优势", "品牌理念", "合作内容", "扫码观看", "bilibili", "市场战略"
    ]
    /// 同一页最多挑几张。参数页通常只有一张产品全貌图；不限页数的话，
    /// 一个图多的页会把名额全占了，候选图就全来自同一页。
    private static let shotsPerPage = 2

    /// `ask` 默认直接问本机模型；留这个口子是为了能用固定的模型回答测整条链路。
    static func buildProfile(
        from source: BriefSource,
        progress: @Sendable (Double, String) -> Void,
        ask: (LocalVLM.ChatOptions) async throws -> [String: Any] = { try await LocalVLM.chatJSON($0) }
    ) async throws -> Result {
        progress(0.05, "正在读 \(source.format.label) 里的文字…")

        // brief 里提出来的候选图，按「这一页是不是产品参数页 + 画面本身」排一遍，
        // 挑最该给模型看的几张，免得把整份 brief 都塞进上下文。
        let chosen = selectShots(from: source, limit: maxShotsForModel)
        let shown = chosen.map(\.candidate)

        // 图和文字要一起进 8k 上下文：图给多了就少放点文字，别把上下文顶爆。
        let excerpt = String(source.text.prefix(shown.count > 6 ? 4200 : 7000))

        progress(0.15, "正在让本地模型读 brief…")

        let schemaImages = shown.compactMap { LocalVLM.jpegData(from: URL(fileURLWithPath: $0.path), maxWidth: 640) }
        let listing = chosen.enumerated()
            .map { shot -> String in
                var text = "第 \(shot.offset + 1) 张（\(shot.element.candidate.label)"
                if !shot.element.hits.isEmpty {
                    text += "，这一页写着 \(shot.element.hits.prefix(4).joined(separator: "、"))"
                }
                return text + "）"
            }
            .joined(separator: "、")

        let shotNote = schemaImages.isEmpty
            ? ""
            : "后面附了从 brief 里提出来的 \(schemaImages.count) 张图：\(listing)。"
        let prompt = """
        这是品牌方给的产品 brief（\(source.format.label)）。先看文字，再看图。\(shotNote)

        【brief 文字】
        \(excerpt.isEmpty ? "（这份文件没有可提取的文字，请只看图片判断。）" : excerpt)

        【参考图怎么挑 —— 这段最重要】
        后面附的图来自 brief 的不同页，每张的括号里写了页码和这一页的文字线索。
        - 只有「产品参数 / 产品规格」这类页上的实物照片，才是这一版产品最终的样子，参考图必须优先从这里挑。
        - 品牌页、品牌理念页、用户画像页、达人合作页、场景图里的照片是氛围图：可能是旧版本、可能是别的型号，也可能只是模特在用，绝不能拿它们当产品外观参考。
        - 产品细节页（开合系统、内部结构、材质工艺…）上的照片可以当补充参考。
        - 每个颜色款只要有参数页的图，shots 里就必须至少给一张参数页的图。

        【任务】
        弄清楚这次要推广的是哪些产品，输出 JSON：
        {
          "name": "品牌 + 型号 + 品类，例如 NAYOSMART UL1 斜挎包",
          "summary": "外观描述，60-120 字，包含形状、颜色、材质、最显眼的识别特征",
          "features": ["必须能一眼认出的特征，3-6 条，每条不超过 20 字"],
          "avoid": ["容易和它混淆的其它物品，2-4 条，例如 普通单肩包、相机包"],
          "products": [
            {
              "name": "产品名（含品牌型号），例如 NAYOSMART UL1 斜挎包",
              "sku": "brief 里写的 SKU，没写就留空",
              "color": "颜色 / 款式，例如 黑色",
              "features": ["这一款的关键特征，2-4 条"],
              "shots": [拍到这一款本体的附图编号，只要数字，例如 [1, 3]]
            }
          ]
        }

        注意：brief 里给到的**每个颜色都要单独列一条**，哪怕只是同一款包的黑白两色；
        一个颜色一条才能认出实拍画面里是哪一个。没有单独照片的颜色就按你的判断填附图编号，
        完全没有任何照片的颜色让 shots 留空。
        """

        let fallbackName = source.url.deletingPathExtension().lastPathComponent
        var parsed: (profile: ProductProfile, picked: [BriefCandidate], itemShots: [[BriefCandidate]])
        if schemaImages.isEmpty {
            let object = try await ask(.init(system: Self.systemPrompt, prompt: prompt, maxTokens: 700))
            parsed = parse(object, fallbackName: fallbackName, shown: shown)
        } else {
            // 文字 + 图片一起判断：只有看到图，模型才能给出可靠的外观特征。
            var object = [String: Any]()
            do {
                object = try await ask(.init(
                    system: Self.systemPrompt,
                    prompt: "下面 \(schemaImages.count) 张图分别是 brief 里的 \(listing)。\n\n" + prompt,
                    images: schemaImages,
                    maxTokens: 700,
                    timeout: 900
                ))
            } catch {
                // 图片这条路失败时退回纯文字，至少拿到产品名。
                object = try await ask(.init(system: Self.systemPrompt, prompt: prompt, maxTokens: 700))
            }
            parsed = parse(object, fallbackName: fallbackName, shown: shown)
        }
        var profile = parsed.profile
        progress(0.75, "正在保存产品照片…")

        profile.briefPath = source.url.path
        profile.builtAt = Date()
        profile.engine = LocalVLM.modelDisplayName

        // 兜底图：模型一张都没点名时，用排在最前面的几张顶上（参数页优先）。
        let fallback = selectShots(from: source, limit: 3).map(\.candidate)

        let folder = LocalVLM.supportDirectory.appending(path: "ProductRefs/\(safeName(profile.name))", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        /// 把一张候选图存成参考图文件。命名带上产品序号，方便自己回头看是哪一款的图。
        func save(_ shot: BriefCandidate, product: Int, order: Int) -> ProductReferenceImage? {
            guard let data = LocalVLM.jpegData(from: URL(fileURLWithPath: shot.path), maxWidth: 1024) else { return nil }
            let url = folder.appending(path: "p\(product)-\(order).jpg")
            try? data.write(to: url)
            return ProductReferenceImage(path: url.path, caption: shot.label)
        }

        // 产品清单：每一款自己一组参考图，同款不同色不会串。
        // 这里先只决定「用哪几张候选图」，落盘统一放到最后 —— 中间还会纠偏换图，
        // 先写文件会在目录里留下一堆没人引用的图。
        var catalog = parsed.profile.catalog ?? []
        var shotsPerItem: [[BriefCandidate]] = catalog.indices.map { index in
            var shots = index < parsed.itemShots.count ? parsed.itemShots[index] : []
            if shots.isEmpty, catalog.count == 1 { shots = parsed.picked.isEmpty ? fallback : parsed.picked }
            return Array(shots.prefix(2))
        }

        // 参数页的图才是这一版产品的官方外观。模型偶尔还是会被封面大图、理念页带跑，
        // 这里做一次确定性纠偏。**但不能把同一张照片发给两个颜色**：
        // 参数页上的实物图只有一个颜色，挂到别的颜色上，模型就会拿黑包的官图去认米白 ——
        // 实拍里只有黑包，也会报出一堆"米白色"（真实素材上踩过这个坑）。
        // 所以官方图只补给「自己没有任何照片」的颜色款；已经有自己照片的以自己那张为准。
        let official = rankedShots(from: source)
            .filter { $0.pageScore >= 3 && $0.pictureWeight >= 0.25 }
            .map(\.candidate)
        if let officialShot = official.first {
            for index in shotsPerItem.indices where shotsPerItem[index].isEmpty {
                shotsPerItem[index] = [officialShot]
            }
        }
        // 一张来源图只能归一个颜色：模型也常把两个颜色指到同一页，这里按清单顺序先到先得，
        // 后一个颜色宁可没有图（提示词里会写明"没有参考图，只能按名字判断"）。
        var usedShotPaths = Set<String>()
        for index in shotsPerItem.indices {
            shotsPerItem[index] = shotsPerItem[index].filter { usedShotPaths.insert($0.path).inserted }
        }
        for index in catalog.indices {
            catalog[index].referenceImages = shotsPerItem[index].enumerated().compactMap { save($1, product: index + 1, order: $0 + 1) }
        }
        if !catalog.isEmpty { profile.catalog = catalog }

        // 档案级的参考图：清单里所有图按顺序取前几张。
        // 老逻辑（没有清单时）也靠它，所以两种情况下都要有。
        // 同一个颜色款常常被模型指到同一张图上，这里按来源去重：
        // 写几个「4 张」就得真有 4 张不一样的，别把同一张摆两遍。
        var seenCaptions = Set<String>()
        var references = catalog.flatMap(\.referenceImages).filter { seenCaptions.insert($0.caption).inserted }
        if references.isEmpty {
            let chosen = (parsed.picked.isEmpty ? fallback : parsed.picked).prefix(4)
            references = chosen.enumerated().compactMap { save($1, product: 0, order: $0 + 1) }
        }
        // 清单为空（老项目、或者 brief 没列颜色）时，参数页的图同样要顶到最前面。
        if let officialShot = official.first, !references.contains(where: { $0.caption == officialShot.label }),
           let saved = save(officialShot, product: 0, order: 0) {
            references.insert(saved, at: 0)
        }
        profile.referenceImages = Array(references.prefix(4))
        progress(1, "产品档案已生成")
        return Result(profile: profile, candidateCount: source.candidates.count)
    }

    private static let systemPrompt = "你在读品牌合作 brief。只输出 JSON，不要解释，不要复述 brief 原文。"

    private static func parse(
        _ object: [String: Any],
        fallbackName: String,
        shown: [BriefCandidate]
    ) -> (profile: ProductProfile, picked: [BriefCandidate], itemShots: [[BriefCandidate]]) {
        var profile = ProductProfile()
        profile.name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackName
        profile.summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profile.features = (object["features"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        profile.avoid = (object["avoid"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []

        /// 把模型给的附图编号翻成真实候选图：越界的一律丢掉。
        func shots(_ value: Any?) -> [BriefCandidate] {
            ((value as? [Any])?.compactMap(number) ?? [])
                .filter { (1...shown.count).contains($0) }
                .map { shown[$0 - 1] }
        }

        // 产品清单：一个颜色一条，各带自己的参考图。
        var catalog: [ProductCatalogItem] = []
        var itemShots: [[BriefCandidate]] = []
        for entry in (object["products"] as? [Any])?.compactMap({ $0 as? [String: Any] }) ?? [] {
            let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let color = ((entry["color"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !color.isEmpty else { continue }
            var item = ProductCatalogItem(name: name.isEmpty ? color : name)
            item.sku = ((entry["sku"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            item.color = color
            item.features = (entry["features"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
            catalog.append(item)
            itemShots.append(shots(entry["shots"]))
        }
        if !catalog.isEmpty {
            profile.catalog = catalog
            // 顶层描述缺的时候，用清单第一条顶上，界面和提示词都不会空着。
            if profile.name.isEmpty || profile.name == fallbackName { profile.name = catalog[0].name }
            if profile.features.isEmpty { profile.features = catalog[0].features }
        }
        if profile.name.isEmpty { profile.name = fallbackName }

        // 模型可能给“附图的编号”，也可能按老习惯给页码，两种都认。
        var picked: [BriefCandidate] = []
        picked.append(contentsOf: shots(object["product_shots"]))
        if picked.isEmpty {
            for page in (object["product_pages"] as? [Any])?.compactMap(number) ?? [] {
                if let match = shown.first(where: { $0.pageIndex == page }) { picked.append(match) }
            }
        }
        if picked.isEmpty { picked = itemShots.flatMap { $0 } }
        var seen = Set<String>()
        picked = picked.filter { seen.insert($0.path).inserted }
        return (profile, picked, itemShots)
    }

    private static func number(_ value: Any) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text.filter(\.isNumber)) }
        return nil
    }

    // MARK: 挑参考图

    /// 把 brief 里的候选图逐张评分。参数页的图会排到最前面。
    static func rankedShots(from source: BriefSource) -> [ShotRank] {
        source.candidates.compactMap { candidate in
            guard let image = image(at: candidate.path) else { return nil }
            let page = pageScore(candidate.pageText)
            return ShotRank(
                candidate: candidate,
                pictureWeight: photoWeight(image),
                pageScore: page.score,
                hits: page.hits
            )
        }
    }

    /// 送给模型的那几张图：按分数取前几名，再按 brief 原本的顺序排好
    /// —— 编号顺序和阅读顺序一致，模型不容易串号。
    static func selectShots(from source: BriefSource, limit: Int = maxShotsForModel) -> [ShotRank] {
        let ranked = rankedShots(from: source)
        // 先只在「看得出是产品页」的页里挑：封面、理念页、达人页的文字里
        // 没有产品字段，它们的照片是氛围图，送给模型只会带偏判断。
        let producty = pick(from: ranked.filter { $0.pageScore > 0 }, limit: limit)
        if !producty.isEmpty { return producty }
        // 一份 brief 完全没有参数页、也没有细节页（简版 brief 常见）时，
        // 退回按画面本身排几张，至少让模型有东西可看。
        return pick(from: ranked, limit: limit)
    }

    /// 按分数取前几名，同一页最多 `shotsPerPage` 张，最后按 brief 原本的顺序排好。
    private static func pick(from ranked: [ShotRank], limit: Int) -> [ShotRank] {
        let ordered = ranked.enumerated()
            .sorted { left, right in
                left.element.score == right.element.score
                    ? left.offset < right.offset
                    : left.element.score > right.element.score
            }
        var perPage: [String: Int] = [:]
        var picked: [(offset: Int, element: ShotRank)] = []
        for entry in ordered {
            guard picked.count < limit else { break }
            let key = entry.element.candidate.pageIndex.map(String.init) ?? entry.element.candidate.label
            let seen = perPage[key, default: 0]
            guard seen < shotsPerPage else { continue }
            perPage[key] = seen + 1
            picked.append(entry)
        }
        return picked.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// 这一页的文字像不像产品参数页。命中强词就基本可以确认。
    static func pageScore(_ pageText: String) -> (score: Double, hits: [String]) {
        guard !pageText.isEmpty else { return (0, []) }
        let flat = flattened(pageText)
        var hits: [String] = []
        var score = 0.0
        for word in specStrongWords where flat.contains(word) {
            hits.append(word)
            score += 3
        }
        var weakHits = 0
        for word in specWeakWords where flat.contains(word) {
            weakHits += 1
            if !hits.contains(word) { hits.append(word) }
        }
        // 弱词封顶 2 分：光靠「材质、颜色」这种词，说服力比不上真的写着「产品参数」。
        score += min(Double(weakHits) * 0.5, 2)
        // 氛围页/达人页直接扣下去，别让「重量」这种随处可见的词把它们抬上来。
        var negativeHits = 0
        for word in specNegativeWords where flat.contains(word) {
            negativeHits += 1
        }
        score -= min(Double(negativeHits) * 1.5, 4.5)
        return (score, hits)
    }

    /// PDF 里字与字之间常插进空格（「产 品 参 数」），还有康熙部首这种兼容字符
    /// （「⼯艺」），不归一化的话关键词一条也匹配不上。英文也顺手小写。
    private static func flattened(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .lowercased()
    }

    private static func image(at path: String) -> CGImage? {
        NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 一页里“非白像素”的比例。brief 里纯文字页接近 0，产品图页接近 1，用它排序足够准。
    private static func photoWeight(_ image: CGImage) -> Double {
        let width = 32, height = 18
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
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var nonWhite = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if r + g + b < 700 { nonWhite += 1 }
        }
        return Double(nonWhite) / Double(width * height)
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "product" : String(cleaned.prefix(40))
    }
}

/// 送进模型的候选产品：产品清单里的一条，或者老项目里的产品档案本身。
/// 图要和清单条一一对应 —— 模型是看着这几张图回答“这是清单里的第几号”。
struct BrollCandidate: Sendable {
    /// 模型回答 product_index 时用的编号，从 1 开始。
    var index: Int
    var productID: UUID
    var name: String
    var sku: String = ""
    var color: String = ""
    var features: [String] = []
    var images: [Data] = []

    /// 显示名：产品名 + 颜色。认出产品时，物品清单里就用它。
    var displayLabel: String {
        var label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = "未命名产品" }
        if !color.isEmpty, !label.contains(color) { label += " · \(color)" }
        return label
    }
}

/// 用本地视觉模型认物品、挑片段：
/// 每一帧先看清画面里有什么（是清单里的哪款产品 / 背景装饰 / 拍摄设备 / 看不出是什么的东西），
/// 再从这些结论里选出**能展示产品、而且镜头稳**的那一段。
enum ProductPicker {
    /// 每条候选最多给模型看几张参考图。图要在每一帧的请求里重新编码一遍，越多越慢。
    static let referenceLimit = 1
    /// 只有一条候选时多给一张：反正没有别的产品要跟它比。
    static let singleReferenceLimit = 2
    static let referenceWidth: CGFloat = 512
    /// 一次最多带几条候选进模型：清单再长也不能把上下文撑爆。
    static let candidateLimit = 6
    /// 一帧最多认几件东西。再多就变成在描述画面了，不是我们要的。
    static let objectLimit = 4

    /// 把产品档案变成候选清单。
    static func candidates(for profile: ProductProfile) -> [BrollCandidate] {
        let products = Array(profile.products.prefix(candidateLimit))
        let perProduct = products.count > 1 ? referenceLimit : singleReferenceLimit
        // 只有一条候选时，档案级的参考图（手工加的、或者 brief 只给了一组图）就是它的图。
        // 清单里有多条时不能互相借用：把黑色的图当成米白款的参考图，模型会认错颜色，
        // 宁可让那一条按名字判断，界面上也会写明它有几张参考图。
        let shared = products.count == 1 ? profile.referenceImages : []
        return products.enumerated().map { offset, product in
            let references = product.referenceImages.isEmpty ? shared : product.referenceImages
            return BrollCandidate(
                index: offset + 1,
                productID: product.id,
                name: product.name,
                sku: product.sku,
                color: product.color,
                features: product.features,
                images: references
                    .prefix(perProduct)
                    .compactMap { LocalVLM.jpegData(from: URL(fileURLWithPath: $0.path), maxWidth: referenceWidth) }
            )
        }
    }

    /// 送进模型的全部参考图：按清单顺序拼起来，编号和文字说明对得上。
    static func referenceImages(_ candidates: [BrollCandidate]) -> [Data] {
        candidates.flatMap(\.images)
    }

    /// 产品清单的文字说明。附图编号按顺序往下排，模型才能对应上。
    static func listing(_ candidates: [BrollCandidate]) -> String {
        var lines: [String] = []
        var shot = 0
        for candidate in candidates {
            var line = "\(candidate.index)) \(candidate.displayLabel)"
            if !candidate.sku.isEmpty { line += "（SKU \(candidate.sku)）" }
            let first = shot + 1
            shot += candidate.images.count
            if candidate.images.isEmpty {
                line += " —— 没有参考图，只能按名字判断"
            } else if candidate.images.count == 1 {
                line += " —— 附图 \(first)"
            } else {
                line += " —— 附图 \(first)-\(shot)"
            }
            if !candidate.features.isEmpty { line += "；特征：\(candidate.features.prefix(3).joined(separator: "、"))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func analyze(
        path: String,
        duration: Double,
        profile: ProductProfile,
        candidates: [BrollCandidate],
        sampleCount: Int = ProductPicker.standardFrameCount,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> BrollProductPick {
        // 解码总是取满 5 帧（本机解码很便宜，一条 4K 素材 0.8 秒），
        // "抽几帧"控制的是**问模型几次** —— 那才是慢的地方。
        let frames = try await BrollAnalyzer.sampleFrames(url: URL(fileURLWithPath: path))
        let speeds = BrollAnalyzer.localSpeeds(frames)
        progress(0.15)

        // 先问首 / 中 / 尾三帧；选“1 帧”档时只问中间那一帧。
        // 这三帧结论一致就说明这条素材里有什么很清楚，剩下两帧不用再问 ——
        // 每问一帧就是一次本地模型调用，实测每次 10–20 秒。
        var askedIndexes = firstPassIndexes(in: frames, wanted: min(max(1, sampleCount), frames.count))
        var verdicts = await perFrameVerdicts(
            frames: askedIndexes.map { frames[$0] },
            profile: profile,
            candidates: candidates
        ) { fraction in
            progress(0.15 + 0.5 * fraction)
        }
        // 三帧档却互相矛盾时，补问到全部采样帧；五帧档本来就问全，不用补。
        if sampleCount > fastFrameCount, askedIndexes.count < frames.count, needsMoreFrames(verdicts) {
            let asked = Set(askedIndexes)
            let rest = frames.indices.filter { !asked.contains($0) }.map { frames[$0] }
            verdicts += await perFrameVerdicts(frames: rest, profile: profile, candidates: candidates) { fraction in
                progress(0.65 + 0.25 * fraction)
            }
            askedIndexes = Array(frames.indices)
        }
        askedIndexes.sort()
        return finish(
            verdicts: verdicts,
            askedIndexes: askedIndexes,
            speeds: speedsForAskedFrames(allSpeeds: speeds, frames: frames, askedIndexes: askedIndexes),
            duration: duration,
            progress: progress
        )
    }

    /// 抽帧档位：只跑一帧最快，三帧是默认，五帧最全。
    static let fastFrameCount = 1
    static let standardFrameCount = 3
    static let thoroughFrameCount = 5

    /// 首 / 中 / 尾优先：这三个点最能代表一条素材。
    static func firstPassIndexes(in frames: [BrollAnalyzer.SampleFrame], wanted: Int) -> [Int] {
        guard frames.count > 1, wanted < frames.count else { return Array(frames.indices) }
        // 只问一帧时问中间那帧：首尾常常是刚起机/已经停机的那一两帧。
        if wanted <= 1 { return [frames.count / 2] }
        let middle = frames.count / 2
        var result: [Int] = []
        for index in [0, middle, frames.count - 1] where result.count < wanted && !result.contains(index) {
            result.append(index)
        }
        var next = 1
        while result.count < wanted {
            if !result.contains(next) { result.append(next) }
            next += 1
        }
        return result.sorted()
    }

    /// 只问了其中几帧时，稳定性要用的“相邻两帧之间有多快”。
    ///
    /// 中间没问到的步，用本机光流算出来的分段速度累加成位移，再除以首尾时间差。
    /// 全问（五帧档）时结果和原来的 `localSpeeds` 完全一致。
    static func speedsForAskedFrames(
        allSpeeds: [Double],
        frames: [BrollAnalyzer.SampleFrame],
        askedIndexes: [Int]
    ) -> [Double] {
        guard askedIndexes.count >= 2, !allSpeeds.isEmpty else { return [] }
        var result: [Double] = []
        for pair in zip(askedIndexes, askedIndexes.dropFirst()) {
            var magnitude = 0.0
            for step in pair.0..<pair.1 where step >= 0 && step < allSpeeds.count && step + 1 < frames.count {
                let seconds = max(0.05, frames[step + 1].time - frames[step].time)
                magnitude += allSpeeds[step] * seconds
            }
            let span = max(0.05, frames[pair.1].time - frames[pair.0].time)
            result.append(magnitude / span)
        }
        return result
    }

    /// 把帧结论收成最终结果。
    private static func finish(
        verdicts input: [BrollFrameVerdict],
        askedIndexes: [Int],
        speeds: [Double],
        duration: Double,
        progress: @Sendable (Double) -> Void
    ) -> BrollProductPick {
        let verdicts = input.sorted { $0.index < $1.index }
        guard !verdicts.isEmpty else { return BrollProductPick() }

        var pick = Self.pick(verdicts: verdicts, times: verdicts.map(\.time), speeds: speeds, duration: duration)
        // 一句话结论只写“推荐的那一帧”看到的情况。
        // 以前这里取的是第一个提到产品的帧，结果出现过“结论说模糊、其实推荐帧很清楚”的自相矛盾。
        if pick.summary.isEmpty {
            pick.summary = pick.containsProduct ? "" : "整条素材里没有出现产品"
        }
        // 只问了其中几帧时把这件事写清楚：结论覆盖的是这几个采样点，不是每一帧。
        pick.sampledCount = askedIndexes.count
        pick.engine = LocalVLM.modelDisplayName
        progress(1)
        return pick
    }

    /// 每一帧都会变的那句话：放在图片后面，前缀（说明 + 参考图）才能在逐帧之间保持一致，
    /// llama-server 的前缀缓存才命中得了。
    static func frameNote(_ time: Double) -> String {
        "【这一帧】素材在 \(BrollProductPick.timecode(time)) 的画面（最后一张图）。"
    }

    /// 三帧结论是不是已经足够一致，不用再补问另外两帧。纯函数，方便单测。
    ///
    /// 判据：认到的产品集合一样、产品档位不冲突、需要确认的东西也应该一致。
    /// 只要有一帧和别的不一样（比如中间那帧焦点换了产品），就老老实实把五帧问全。
    static func needsMoreFrames(_ verdicts: [BrollFrameVerdict]) -> Bool {
        guard verdicts.count >= 2 else { return true }
        let products = Set(verdicts.flatMap { $0.objects.compactMap(\.productID) })
        let presenceRanks = verdicts.map(\.presence.rank)
        // 档位差得太多（比如一帧是产品主体、另一帧完全没看到）说明还没看清。
        if let high = presenceRanks.max(), let low = presenceRanks.min(), high - low >= 2 { return true }
        for verdict in verdicts {
            let ids = Set(verdict.objects.compactMap(\.productID))
            if ids != products { return true }
        }
        return false
    }

    private static let systemPrompt = "你在为一条产品广告挑 B-roll 素材。只输出 JSON，不要解释。"

    // 说明：这里试过“一次请求看完 5 帧”的批量问法，速度只快 2 倍左右，
    // 但模型会把中间几帧误判成“没拍到产品”（真实素材上比对过，逐帧结论才是对的）。
    // 产品镜头的准确性比速度重要，所以保留逐帧，另用“限制参考图数量和分辨率”来提速。

    /// 逐帧问：每帧独立，一帧失败不影响其它帧。
    ///
    /// **并发发**：llama-server 本身带多个槽位，一次发几个请求它会把几段一起批处理，
    /// 墙钟时间比一条条排队短得多。上限压在 3 —— 这台机器内存本来就紧，不能再贪。
    private static func perFrameVerdicts(
        frames: [BrollAnalyzer.SampleFrame],
        profile: ProductProfile,
        candidates: [BrollCandidate],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [BrollFrameVerdict] {
        let references = referenceImages(candidates)
        let prompt = promptText(profile: profile, candidates: candidates, referenceCount: references.count)
        let counter = CallCounter(total: frames.count)
        var verdicts: [BrollFrameVerdict] = []
        for batch in frames.chunked(into: concurrentCalls) {
            if Task.isCancelled { break }
            await withTaskGroup(of: BrollFrameVerdict.self) { group in
                for frame in batch {
                    group.addTask {
                        let result = await askFrame(frame, prompt: prompt, references: references, candidates: candidates)
                        progress(await counter.tick())
                        return result
                    }
                }
                for await result in group { verdicts.append(result) }
            }
        }
        return verdicts.sorted { $0.index < $1.index }
    }

    /// 同时问几帧。llama-server 有多个槽位，几个请求一起发才会被批处理。
    static let concurrentCalls = 3

    /// 问一帧。单帧失败（超时、返回坏 JSON）只影响这一帧。
    private static func askFrame(
        _ frame: BrollAnalyzer.SampleFrame,
        prompt: String,
        references: [Data],
        candidates: [BrollCandidate]
    ) async -> BrollFrameVerdict {
        guard let jpeg = LocalVLM.jpegData(from: frame.cgImage) else {
            return BrollFrameVerdict(index: frame.index, time: frame.time, presence: .none, confidence: 0, sharpness: 0, note: "取不到画面")
        }
        do {
            let object = try await LocalVLM.chatJSON(.init(
                system: systemPrompt,
                prompt: prompt,
                images: references + [jpeg],
                // 会变的那句话放在图片**后面**：前缀（说明 + 参考图）在逐帧之间保持不变，
                // llama-server 的前缀缓存才命中得了。前缀一变，实测单次从 5 秒变 16 秒。
                trailingPrompt: frameNote(frame.time),
                maxTokens: 520,
                timeout: 300
            ))
            return verdict(index: frame.index, time: frame.time, object: object, candidates: candidates)
        } catch {
            return BrollFrameVerdict(index: frame.index, time: frame.time, presence: .none, confidence: 0, sharpness: 0, note: "识别失败")
        }
    }

    /// 并发进度计数。
    private actor CallCounter {
        private var done = 0
        private let total: Int
        init(total: Int) { self.total = max(1, total) }
        func tick() -> Double {
            done += 1
            return Double(done) / Double(total)
        }
    }

    static func promptText(profile: ProductProfile, candidates: [BrollCandidate], referenceCount: Int) -> String {
        var lines: [String] = []
        if candidates.isEmpty {
            // 没有产品清单时只认物品，不判产品档位 —— 免得模型硬把画面里的东西说成是那个产品。
            lines.append("【产品清单】这次没有给产品清单，只列画面里有什么，presence_code 一律填 0。")
        } else {
            lines.append("【产品清单】这次要认的产品（编号就是回答里的 product_index）：\n\(listing(candidates))")
        }
        if !profile.promptBlock.isEmpty { lines.append("【产品档案】\n\(profile.promptBlock)") }
        lines.append("""
        【画面】
        前面 \(referenceCount) 张是产品清单的参考图（按清单顺序排）。最后 1 张是素材的画面，
        它对应素材里的哪个时间点写在图片后面。

        【任务】
        只看最后这一帧，做两件事。

        一、列出画面里看得清的东西，最多 4 件。每件回答：
        - name：不超过 6 个字的名字，同一件东西每次都用同一个名字
        - color：**你在这一帧里真正看到的颜色**（例如 黑、深灰、米白、棕），看不清就留空
        - product_index：它在产品清单里是第几号；不在清单里就写 0
        - role：subject（这一帧最该被看到的主角物品）/ supporting（陪衬的东西）/ other_product（看得出是一件产品，但不是上面清单里的那一款 —— 别的品牌、别家的同类产品）/ background（背景装饰）/ gear（相机、手机、灯这类拍摄设备）/ unknown（看不出是什么的东西）
        - position：left / center / right / top_left / top / top_right / bottom_left / bottom / bottom_right
        - sharpness 0-100：这件东西在画面里清不清楚，对焦在它身上就是高分
        - confidence 0-100：你对“它是什么”的把握

        认产品时按这个顺序判断，不要跳步：
        1) 先看形状和特征：这件东西是不是清单里那款产品；
        2) 再看颜色：清单里同一款有多个颜色时，**颜色对不上的那一条就当没出现**，
           product_index 写 0，不要因为“也可能是另一色”就把它算成另一款；
        3) 看不清、被挡住、只是模糊影子、只是大面积高光或反光的东西，不要列进来，更不要当成产品；
        4) 一帧里同一款产品只报一次。清单里有两三个颜色，不代表画面里就有两三件东西 ——
           画面里只有一件包，就只对应清单里颜色对得上的那一条。

        二、清单里的产品这一帧出现得怎么样，填 presence_code：
          3 = 清单里的产品是画面主体，看得很清楚
          2 = 画面里有清单里的产品，但不是主体
          1 = 疑似是清单里的产品，但看不清或看不清形状
          0 = 没有出现清单里的产品

        【输出】
        {"presence_code": 0, "confidence": 0, "sharpness": 0, "note": "不超过 12 字，说明判断依据",
         "objects": [{"name": "黑色斜挎包", "color": "黑色", "product_index": 1, "role": "subject", "position": "center", "sharpness": 88, "confidence": 90, "note": "扣具很清楚"}]}
        最外层的 sharpness 是整帧清不清楚（糊了、拖影、被挡住都算不清楚）。
        """)
        return lines.joined(separator: "\n\n")
    }

    /// 把模型输出翻译成帧结论，越界值一律降级，不让模型编的分数污染排序。
    static func verdict(index: Int, time: Double, object: [String: Any], candidates: [BrollCandidate] = []) -> BrollFrameVerdict {
        let code = clamp(intValue(object["presence_code"]), to: 0...3)
        let confidence = clamp(intValue(object["confidence"]), to: 0...100)
        let sharpness = clamp(intValue(object["sharpness"]), to: 0...100)
        let note = (object["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BrollFrameVerdict(
            index: index,
            time: time,
            presence: BrollProductPresence.from(code: code),
            confidence: confidence,
            sharpness: sharpness,
            note: note,
            objects: objects(object["objects"], candidates: candidates)
        )
    }

    /// 把模型给的物品数组翻译成结构体。
    /// 名字空的、清单编号对不上的都按“认不出来的东西”处理，不让模型编的东西污染清单；
    /// 同一件东西被写了两次（模型常犯）只留最清楚的那条。
    static func objects(_ value: Any?, candidates: [BrollCandidate]) -> [BrollObject] {
        guard let list = value as? [Any] else { return [] }
        var result: [BrollObject] = []
        for (offset, element) in list.enumerated() {
            guard result.count < objectLimit, let raw = element as? [String: Any] else { continue }
            let name = ((raw["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = candidates.first { $0.index == intValue(raw["product_index"]) }
            let roleText = ((raw["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelColor = ((raw["color"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 颜色对不上就不算这一款。
            // 用户的判断顺序是「先看是不是这款产品，再看颜色对不对」，所以模型说它认出了某某号、
            // 但它自己写的颜色和那一号的颜色不是同一类时，宁可不认，也不要把颜色词硬套上去。
            let matched = candidate.flatMap { Self.colorMatches(modelColor, $0.color) ? $0 : nil }
            // 认到就写清单里的名字（含颜色）；没认到就用模型自己看到的那个名字。
            let label = matched?.displayLabel ?? name
            guard !label.isEmpty else { continue }
            let object = BrollObject(
                slot: offset + 1,
                label: label,
                productID: matched?.productID,
                sku: matched?.sku ?? "",
                color: modelColor.isEmpty ? (matched?.color ?? "") : modelColor,
                // 清单里的产品不写角色时按“陪衬”算，不写清单编号的按“认不出来”算。
                role: roleText.isEmpty ? (matched != nil ? .supporting : .unknown) : BrollObjectRole.from(code: roleText),
                spot: BrollSpot.from(code: (raw["position"] as? String) ?? ""),
                sharpness: clamp(intValue(raw["sharpness"]), to: 0...100),
                confidence: clamp(intValue(raw["confidence"]), to: 0...100),
                note: String(((raw["note"] as? String) ?? "").prefix(24))
            )
            if let index = result.firstIndex(where: { $0.identityKey == object.identityKey }) {
                if (object.sharpness, object.confidence) > (result[index].sharpness, result[index].confidence) {
                    result[index] = object
                }
            } else {
                result.append(object)
            }
        }
        return result
    }

    /// 模型看到的颜色和清单里那一款的颜色是不是同一类。
    ///
    /// 只在两边都说得清颜色时才判：模型没给颜色、或者清单里那款本来就没写颜色，
    /// 都按“过”，不拿没把握的信息去否定匹配。
    static func colorMatches(_ observed: String, _ expected: String) -> Bool {
        let seen = colorFamily(observed)
        let want = colorFamily(expected)
        guard !seen.isEmpty, !want.isEmpty else { return true }
        // 中性色之间容易互相误判（白/米白/灰），只在“确实不是一类”时才否定。
        return seen == want
    }

    /// 颜色词归族：同一个基色的说法算一类，别的颜色算另一类。
    /// 认不出来的说法返回空串 —— 不确定的颜色不参与判断，免得把对的匹配否掉。
    private static func colorFamily(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return "" }
        let table: [(family: String, words: [String])] = [
            ("black", ["黑", "black", "深黑", "炭黑", "墨"]),
            ("white", ["白", "white", "米白", "象牙", "奶油", "奶白", "燕麦"]),
            ("gray", ["灰", "gray", "grey", "银", "silver"]),
            ("red", ["红", "red", "酒红", "玫红", "粉红", "玫", "莓"]),
            ("orange", ["橙", "橘", "orange", "焦糖"]),
            ("yellow", ["黄", "yellow", "金", "gold", "香槟"]),
            ("green", ["绿", "green", "军绿", "橄榄", "薄荷"]),
            ("blue", ["蓝", "blue", "藏青", "navy", "牛仔"]),
            ("purple", ["紫", "purple", "violet"]),
            ("pink", ["粉", "pink"]),
            ("brown", ["棕", "brown", "咖啡", "褐", "栗", "tan", "驼", "杏色"])
        ]
        for entry in table where entry.words.contains(where: { value.contains($0) }) {
            return entry.family
        }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text.filter { $0.isNumber || $0 == "-" }) ?? 0 }
        return 0
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - 选片段（纯函数，可单测）

    /// 得分权重：能不能展示产品占一半，镜头稳不稳占四分之一。
    private static let productWeight = 0.50
    private static let stabilityWeight = 0.25
    private static let sharpnessWeight = 0.15
    private static let lengthWeight = 0.10
    /// 片段内超过这个速度（画面宽/高的百分比/秒）就不算“稳”。
    private static let gentleSpeed = 1.2
    /// 推荐片段的最短长度：太短的镜头在剪辑里没法用。
    private static let minimumDuration = 1.2

    /// 从帧结论里挑出推荐片段。纯函数，方便单测和回归。
    static func pick(verdicts: [BrollFrameVerdict], times: [Double], speeds: [Double], duration: Double) -> BrollProductPick {
        guard !verdicts.isEmpty else { return BrollProductPick() }
        let sorted = verdicts.sorted { $0.index < $1.index }
        // 先找最有价值的一帧：是不是主体 → 置信度 → 清晰度。
        let best = sorted.max { left, right in
            (left.presence.rank, left.confidence, left.sharpness) < (right.presence.rank, right.confidence, right.sharpness)
        }!
        let bestIndex = sorted.firstIndex(where: { $0.index == best.index }) ?? 0

        // 一个采样点都没认出产品：直接给 0 分、不给片段。
        // 不能因为“镜头很稳、素材很长”就凑出一个分数，那会让用户以为这条能用。
        if best.presence.rank == 0 {
            return BrollProductPick(
                start: 0,
                end: 0,
                score: 0,
                frames: sorted,
                reasons: ["\(sorted.count) 个采样点上都没有认出产品，这条不适合用来展示产品。"],
                summary: best.note
            )
        }

        func speed(_ index: Int) -> Double {
            guard !speeds.isEmpty, index >= 0, index < speeds.count else { return 0 }
            return speeds[index]
        }

        // 从最好的一帧往两边扩：只要邻居还有产品、而且这一段镜头不晃，就把它带上。
        var low = bestIndex
        var high = bestIndex
        while low > 0, sorted[low - 1].presence.rank >= 1, speed(low - 1) <= gentleSpeed { low -= 1 }
        while high < sorted.count - 1, sorted[high + 1].presence.rank >= 1, speed(high) <= gentleSpeed { high += 1 }

        let first = sorted[low].time
        let last = sorted[high].time
        let headroom = low > 0 ? (first - sorted[low - 1].time) / 2 : 0.4
        let tailroom = high < sorted.count - 1 ? (sorted[high + 1].time - last) / 2 : 0.6
        var start = max(0, first - headroom)
        var end = min(duration > 0 ? duration : last + tailroom, last + tailroom)
        if end - start < minimumDuration {
            let padding = (minimumDuration - (end - start)) / 2
            start = max(0, start - padding)
            end = min(duration > 0 ? duration : end + padding, end + padding)
        }
        if end <= start { end = min(duration, start + minimumDuration) }

        // 计分
        let windowSpeeds = speeds.isEmpty ? [] : Array(speeds[min(low, speeds.count - 1)...min(max(high - 1, low), speeds.count - 1)])
        let averageSpeed = windowSpeeds.isEmpty ? speed(low) : windowSpeeds.reduce(0, +) / Double(windowSpeeds.count)
        let stability = max(0, min(100, 100 - averageSpeed * 25))
        let sharpness = Double(sorted[low...high].map(\.sharpness).reduce(0, +)) / Double(high - low + 1)
        let presenceScore: Double
        switch best.presence {
        case .mainSubject: presenceScore = 100
        case .visible: presenceScore = 78
        case .hinted: presenceScore = 42
        case .none: presenceScore = 0
        }
        let productScore = presenceScore * (0.7 + 0.3 * Double(best.confidence) / 100)
        let lengthScore = min(100, (end - start) / 2.5 * 100)
        let score = Int((productScore * productWeight
            + stability * stabilityWeight
            + sharpness * sharpnessWeight
            + lengthScore * lengthWeight).rounded())

        var reasons: [String] = []
        reasons.append("\(BrollProductPick.timecode(best.time)) 这一帧产品最清楚（\(best.presence.rawValue)，置信 \(best.confidence)）。")
        if best.sharpness >= 60 { reasons.append("画面清晰度 \(best.sharpness)，不糊。") }
        else if best.sharpness > 0 { reasons.append("画面偏糊（清晰度 \(best.sharpness)），能换一条更好。") }
        // 速度档位要和上面的 gentleSpeed 一致：超过它的就别再说“不算晃”，那是骗自己。
        if averageSpeed <= 0.35 {
            reasons.append("这一段的镜头基本不动（\(formatted(averageSpeed)) 画面宽/秒），适合当产品定格。")
        } else if averageSpeed <= gentleSpeed {
            reasons.append("这一段的镜头在缓慢移动（\(formatted(averageSpeed)) 画面宽/秒），不算晃，可以留着。")
        } else {
            reasons.append("这一段镜头动得比较明显（\(formatted(averageSpeed)) 画面宽/秒），产品虽然看得清，但不适合做定格，用之前先看一眼。")
        }
        reasons.append("推荐片段 \(BrollProductPick.timecode(start))–\(BrollProductPick.timecode(end))，约 \(formatted(end - start)) 秒。")

        return BrollProductPick(
            start: start,
            end: end,
            score: max(0, min(100, score)),
            frames: sorted,
            reasons: reasons,
            summary: best.note
        )
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension Array {
    /// 按固定大小切块：并发调用时一批一批发。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 1 else { return map { [$0] } }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
