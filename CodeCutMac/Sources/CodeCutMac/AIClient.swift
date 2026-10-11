import Foundation
import Security
import AVFoundation
import NaturalLanguage
import AppKit

struct AISettings: Sendable {
    /// 文本模型的来源。DeepSeek 云端接口已关闭，代码保留以便随时切回去。
    enum Backend: String, Sendable {
        case local
        case deepSeek
    }

    static let providerName = "DeepSeek"
    /// 跟着用户在设置里选的本地模型走，不能固化成 let。
    static var localServiceName: String { "本机 \(LocalVLM.modelDisplayName)" }
    /// 本机服务的 OpenAI 兼容入口。AIClient 直接指向它，云端接口已关闭。
    static var localEndpoint: String { LocalVLM.serverBase.appending(path: "v1").absoluteString }

    var baseURL: String
    var model: String
    var apiKey: String
    var backend: Backend = .deepSeek

    var isLocal: Bool { backend == .local }
    var serviceName: String { isLocal ? Self.localServiceName : Self.providerName }

    func requestBody(_ body: [String: Any]) -> [String: Any] {
        // `thinking` 是 DeepSeek 的参数，本机 llama.cpp 不认它，别发过去。
        guard !isLocal else { return body }
        var body = body
        body["thinking"] = ["type": "disabled"]
        return body
    }

    /// CodeCut 只走本机模型：不再需要 API Key，也不向 DeepSeek 发任何请求。
    static var current: Self { .local }

    static var local: Self {
        .init(baseURL: localEndpoint, model: "codecut-local", apiKey: "local", backend: .local)
    }

    static var deepSeek: Self {
        let defaults = UserDefaults.standard
        return .init(baseURL: defaults.string(forKey: "deepseek.baseURL") ?? "https://api.deepseek.com", model: defaults.string(forKey: "deepseek.model") ?? "deepseek-v4-flash", apiKey: KeychainStore.read("deepseek.apiKey") ?? "")
    }

    /// 本机后端在调用前要先把 llama-server 拉起来；没装运行时或权重会抛出明确错误。
    func prepare() async throws {
        guard isLocal else { return }
        _ = try await LocalVLM.ensureServer()
    }
}

enum AIError: LocalizedError {
    case missingKey, invalidURL, unauthorized, rateLimited, server(Int, String), invalidResponse(String), chunkFailed(Int, Int, String)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中填写 DeepSeek 的 API Key。"
        case .invalidURL: "AI API 地址无效。"
        case .unauthorized: "API Key 无效或没有该模型权限。"
        case .rateLimited: "AI 请求过于频繁，请稍后重试。"
        case .server(let code, let text): "AI API（\(code)）：\(text)"
        case .invalidResponse(let text): "AI 返回格式无法解析：\(text)"
        case .chunkFailed(let index, let total, let text): "第 \(index)/\(total) 个音频片段转写失败：\(text)"
        }
    }
}

private enum AIHTTP {
    static func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try checked(data: data, response: response)
    }
    static func checkedData(for request: URLRequest, uploading file: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        return try checked(data: data, response: response)
    }
    private static func checked(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("不是 HTTP 响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AIError.unauthorized }
        if http.statusCode == 429 { throw AIError.rateLimited }
        guard 200..<300 ~= http.statusCode else { throw AIError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "未知错误") }
        return data
    }
    static func endpoint(_ settings: AISettings, path: String) throws -> URL {
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw AIError.invalidURL }
        return url
    }
}

struct AIClient: Sendable {
    let settings: AISettings
    func chat(instruction: String, transcript: String) async throws -> String {
        var request = try authorizedRequest(path: "/chat/completions")
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0.2, "messages": [["role": "system", "content": "你是视频文字剪辑助手。只根据带时间戳的文字稿提出建议，不虚构内容，切点必须位于给定词语边界。"], ["role": "user", "content": "任务：\(instruction)\n\n文字稿：\n\(transcript)"]]]))
        let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
        guard let content = response.choices.first?.message.content, !content.isEmpty else { throw AIError.invalidResponse("没有文本内容") }
        return content
    }
    func ping() async throws { _ = try await chat(instruction: "只回复 OK", transcript: "测试") }

    // MARK: - 分镜配 B-roll

    /// 一条分镜行 + 本地筛出来的候选素材。候选描述是给人看的一句话，模型只看得到这些。
    struct BrollChoiceRequest: Sendable, Equatable {
        var row: Int
        var script: String
        var shot: String
        var note: String
        var candidates: [String]
    }

    /// 让本机模型在候选里挑一条。返回 行号（0 基）-> 候选序号（1 开始，0 表示都不合适）。
    /// 模型没答的行不会出现在字典里，调用方自己决定怎么兜底。
    func chooseBroll(for requests: [BrollChoiceRequest]) async throws -> [Int: Int] {
        guard !requests.isEmpty else { return [:] }
        let rule = """
        你是视频剪辑师，正在按分镜给口播配 B-roll 素材。
        每一条分镜会给出：台词、镜头类型、分镜备注，以及若干条候选素材的一句话描述（文件名｜时长｜画面标签｜画面结论｜认出来的物品）。
        判断标准只有两条：画面内容要对得上台词正在说的事；镜头类型和分镜备注里写的拍法（特写／细节／固定镜头／环绕移动…）要能实现。
        只挑真正对得上的那一条。都不合适就填 0，不要为了凑数挑“差不多”的素材。
        只返回 JSON：{"picks":[{"row":1,"pick":2}]}。row 是分镜序号（从 1 开始），pick 是候选序号（从 1 开始，都不合适填 0）。
        """
        var lines: [String] = []
        for request in requests {
            lines.append("分镜 \(request.row + 1)")
            lines.append("台词：\(request.script)")
            if !request.shot.isEmpty { lines.append("镜头类型：\(request.shot)") }
            if !request.note.isEmpty { lines.append("分镜备注：\(request.note)") }
            for (index, candidate) in request.candidates.enumerated() { lines.append("候选 \(index + 1)：\(candidate)") }
            lines.append("")
        }
        var request = try authorizedRequest(path: "/chat/completions")
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody([
            "model": settings.model,
            "temperature": 0,
            "max_tokens": 1024,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": rule], ["role": "user", "content": lines.joined(separator: "\n")]]
        ]))
        let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
        guard let raw = response.choices.first?.message.content else { throw AIError.invalidResponse("没有挑选结果") }
        return Self.parseBrollPicks(raw, requests: requests)
    }

    /// 解析挑选结果：只认得出、且序号落在候选范围内的 pick。模型偶尔会把序号写成字符串，这里一起兜住。
    static func parseBrollPicks(_ raw: String, requests: [BrollChoiceRequest]) -> [Int: Int] {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let items = (object["picks"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]]) ?? []
        let counts = Dictionary(uniqueKeysWithValues: requests.map { ($0.row + 1, $0.candidates.count) })
        var picks: [Int: Int] = [:]
        for item in items {
            guard let row = intValue(item["row"]), let count = counts[row] else { continue }
            guard let pick = intValue(item["pick"] ?? item["asset"] ?? item["index"]), pick >= 0, pick <= count else { continue }
            picks[row - 1] = pick
        }
        return picks
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    func generateDetailedStoryboardPrompt(item: StoryboardItem, subtitle: String, duration: Double) async throws -> String {
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你是资深 MG 动画导演、分镜师和动效执行指导。把用户给出的一条口播分镜扩写成可直接交付给设计师、动画师或视频生成模型的中文制作提示词。
        输出必须极其具体，不能使用“适当”“自然出现”“增加一些动效”等模糊表述。所有时间均以本条分镜 0 秒为起点，并且不得超过给定总时长。
        必须依次包含：
        1. 分镜目标、精确总时长、画幅与视觉风格；
        2. 整体入场：起始画面、入场时段、转场方式、速度曲线、镜头和背景如何建立；
        3. 按时间顺序拆解画面，每个文字、图形、图标、线条、数字、遮罩、背景层分别写清：出现时刻、持续时间、初始状态、入场方式、运动路径、关键帧变化、层级、颜色、材质、停留动作、与口播同步点、出场时刻和出场方式；
        4. 整体出场：最后画面、退场时段、各层退场先后、转场和与下一镜衔接；
        5. 镜头、构图、排版、安全区、字体、色彩、光影、音效建议；
        6. 最后给出一段不省略细节的“可复制生成提示词”。
        如果原方案是实拍，也要把它转换成能够表达相同信息的 MG 动画设计。不要修改或杜撰产品事实。
        使用清晰的 Markdown 标题与时间轴表格输出，不要输出 JSON，不要解释你是 AI。
        """
        let input = Self.storyboardPromptInput(item: item, subtitle: subtitle, duration: duration)
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0.3, "max_tokens": 8192, "messages": [["role": "system", "content": rule], ["role": "user", "content": input]]]))
        let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
        guard let content = response.choices.first?.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse("没有生成提示词") }
        return content
    }

    static func storyboardPromptInput(item: StoryboardItem, subtitle: String, duration: Double) -> String {
        """
        分镜总时长：\(String(format: "%.2f", duration)) 秒
        对应字幕：\(subtitle)
        原分镜类型：\(item.kind.rawValue)
        画面描述：\(item.description)
        景别与构图：\(item.composition)
        镜头运动：\(item.cameraMovement)
        MG 动画内容/素材元素：\(item.elements)
        制作备注：\(item.notes)
        """
    }

    func generateStoryboards(cues: [SubtitleCue], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [StoryboardItem] {
        guard !cues.isEmpty else { return [] }
        let batchSize = 98
        var generated: [StoryboardItem] = []
        let batchCount = Int(ceil(Double(cues.count) / Double(batchSize)))
        for (batch, targetStart) in stride(from: 0, to: cues.count, by: batchSize).enumerated() {
            let contextStart = max(0, targetStart - 2)
            let end = min(cues.count, targetStart + batchSize)
            let slice = Array(cues[contextStart..<end])
            generated += try await requestStoryboards(cues: slice, generateFromIndex: targetStart - contextStart)
            progress?(Double(batch + 1) / Double(batchCount))
        }
        var seen = Set<String>()
        return generated.filter { item in
            let key = "\(item.kind.rawValue)|\(item.wordIDs.first?.uuidString ?? "")|\(item.wordIDs.last?.uuidString ?? "")"
            return seen.insert(key).inserted
        }
    }

    private func requestStoryboards(cues: [SubtitleCue], generateFromIndex: Int) async throws -> [StoryboardItem] {
        let transcript = cues.enumerated().map { "\($0.offset)|\(String(format: "%.2f", $0.element.start))-\(String(format: "%.2f", $0.element.end))|\($0.element.text)" }.joined(separator: "\n")
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你是口播视频的分镜导演。根据已有字幕设计用于后期制作参考的实拍空镜或 MG 动画，不生成真实素材，也不能修改字幕。
        每条方案覆盖一个完整语义段，通常 8–20 秒。根据表达自动选择“实拍空镜”或“MG 动画”；同一区域确有必要时可各给一条。画面必须具体、可执行，避免“展示相关画面”这类空话。
        输入格式是“序号|源时间|字幕”。只为起始序号大于等于 (generateFromIndex) 的内容生成，前面的行仅作上下文。startIndex/endIndex 必须引用输入序号且 startIndex<=endIndex。
        只返回 JSON：{"items":[{"startIndex":0,"endIndex":2,"type":"实拍空镜","description":"画面描述","composition":"景别与构图","movement":"镜头运动","elements":"素材或动画元素","notes":"制作备注"}]}。
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0.25, "max_tokens": 8192, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": rule], ["role": "user", "content": transcript]]]))
        let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
        guard let raw = response.choices.first?.message.content else { throw AIError.invalidResponse("没有分镜内容") }
        return try Self.parseStoryboards(raw, cues: cues).filter { item in
            guard let first = item.wordIDs.first, let cueIndex = cues.firstIndex(where: { $0.wordIDs.contains(first) }) else { return false }
            return cueIndex >= generateFromIndex
        }
    }

    static func parseStoryboards(_ raw: String, cues: [SubtitleCue]) throws -> [StoryboardItem] {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? JSONDecoder().decode(StoryboardPayload.self, from: Data(cleaned.utf8)) else { throw AIError.invalidResponse("分镜 JSON 不完整或已被截断") }
        return payload.items.compactMap { item in
            guard cues.indices.contains(item.startIndex), cues.indices.contains(item.endIndex), item.endIndex >= item.startIndex else { return nil }
            let range = cues[item.startIndex...item.endIndex]
            let kind: StoryboardKind = item.type.contains("MG") ? .motionGraphics : .liveAction
            let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty, let first = range.first, let last = range.last else { return nil }
            return StoryboardItem(kind: kind, wordIDs: range.flatMap(\.wordIDs), fallbackStart: first.start, fallbackEnd: last.end, description: description, composition: item.composition, cameraMovement: item.movement, elements: item.elements, notes: item.notes)
        }
    }

    struct SegmentationOutcome: Sendable {
        var breaks: Set<UUID> = []
        var windowCount = 0
        var failedWindows = 0
    }

    /// 断句主入口。长稿先按章节切成带上下文的窗口，每个窗口都把**去掉序号后的纯文本**交给
    /// 模型换行，返回结果再逐字对齐回逐词稿；某个窗口对齐失败时只退那一个窗口到逐词序号方案，
    /// 不影响其它窗口。
    func segmentWordBoundaries(_ words: [TranscriptWord], reference: String = "") async throws -> SegmentationOutcome {
        let activeWords = words.filter { !$0.isDeleted }
        guard activeWords.count > 1 else { return SegmentationOutcome() }
        let windows = TimelineEngine.segmentationWindows(in: activeWords)
        var outcome = SegmentationOutcome(windowCount: windows.count)
        var firstError: Error?
        for window in windows {
            let slice = Array(activeWords[window])
            let before = Self.contextText(activeWords, endingBefore: window.lowerBound)
            let after = Self.contextText(activeWords, startingAt: window.upperBound)
            do {
                outcome.breaks.formUnion(try await segmentByReturnedArticle(slice, contextBefore: before, contextAfter: after, reference: reference))
            } catch {
                let articleError = error
                do {
                    outcome.breaks.formUnion(try await segmentByWordIndexes(slice, reference: reference))
                } catch let indexError {
                    outcome.failedWindows += 1
                    if firstError == nil {
                        firstError = AIError.invalidResponse("原文换行失败（\(articleError.localizedDescription)），序号换行也失败（\(indexError.localizedDescription)）")
                    }
                }
            }
        }
        // 全部窗口都失败才算断句失败；部分失败保留成功窗口的结果，其余交给本地规则。
        if outcome.breaks.isEmpty, let firstError { throw firstError }
        return outcome
    }

    /// 窗口前后各取一小段原文当上下文，让模型知道这一段从哪接上、后面要接什么。
    static func contextText(_ words: [TranscriptWord], endingBefore index: Int, limit: Int = 120) -> String {
        guard index > 0, index <= words.count else { return "" }
        var result: [String] = [], collected = 0
        for word in words[..<index].reversed() {
            collected += word.text.count
            if collected > limit { break }
            result.append(word.text)
        }
        return result.reversed().joined()
    }

    static func contextText(_ words: [TranscriptWord], startingAt index: Int, limit: Int = 120) -> String {
        guard index >= 0, index < words.count else { return "" }
        var result: [String] = [], collected = 0
        for word in words[index...] {
            collected += word.text.count
            if collected > limit { break }
            result.append(word.text)
        }
        return result.joined()
    }

    /// 把这一段的文字去掉 `[序号]` 后发给模型，让它在没有标记噪声的情况下只插换行。
    /// 返回的原文用带子编辑距离对齐回逐字稿，换行位置逐字映射成词边界。
    func segmentByReturnedArticle(_ activeWords: [TranscriptWord], contextBefore: String = "", contextAfter: String = "", reference: String) async throws -> Set<UUID> {
        let article = activeWords.map(\.text).joined()
        guard !article.isEmpty else { return [] }
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你是中文口播字幕断句器。输入是一整段连续的识别稿纯文本（往往没有标点或标点很少）。你唯一要做的调整是换行：在合适的位置插入换行符，把整段话切分成一条条适合观看的字幕。
        长稿会被分成几段分别送给你：你只处理 <article> 里的内容，<before> 和 <after> 只是上下文，不要给它们换行，也不要把它们抄进返回结果。
        严禁增加、删除或修改任何一个字和标点：不要纠正错别字、不要补充标点、不要删除重复、卡顿、语气词和 NG，也不要漏抄任何内容。返回的正文必须与输入逐字一致，只允许多出换行符。
        这是用于成片观看的字幕，不是语法分析。每条字幕至少 6 个有效字符，通常 10–24 字；语义完整比字数更重要，必要时可以稍长。
        禁止按固定字数机械换行，禁止连续多行都卡在相同字数。应优先在完整句意、自然语气停顿、话题转换和重新起句处换行。
        不得切断词语、主谓或动宾结构、介词结构、数字与单位、数量词、“的/地/得”结构、固定表达、品牌名或产品名。
        “这也是、就是、所以、但是、因为、而且、然后、但说实话”不能单独成行，必须与后面的完整意思放在一起。
        逗号只是候选分界，不是必须换行；逗号前后任一边过短或语义未完成时不得换行。句号、问号和感叹号通常是边界。顿号只表示并列，绝不能在顿号处分句。冒号不得拆开 3000:1 这类比例。
        错误示例：“这也是，\n为什么我觉得投影仪更适合租房。”
        正确示例：“这也是，为什么我觉得投影仪更适合租房。”
        错误示例：“就是花一，\n个容易接受的，\n价格。”
        正确示例：“就是花一，个容易接受的价格。”
        不要输出 JSON 之外的任何内容。只返回 JSON：{"article":"插入换行后的完整原文"}。
        """
        let input = Self.segmentationInput(article: article, reference: reference, contextBefore: contextBefore, contextAfter: contextAfter)
        // 输出长度和输入同量级，按字数给预算，避免长稿被截断。
        let budget = min(8192, max(2048, Int(Double(article.count) * 1.6) + 256))
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0, "max_tokens": budget, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": rule], ["role": "user", "content": input]]]))
        var lastError: Error = AIError.invalidResponse("没有断句原文")
        for _ in 0..<2 {
            let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
            guard let raw = response.choices.first?.message.content,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let returned = try Self.parseSegmentedArticle(raw)
                guard let result = TimelineEngine.applySegmentedArticle(returned, to: activeWords) else {
                    throw AIError.invalidResponse("返回原文与识别稿对不上")
                }
                return result.breaks
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 交给模型的用户消息：正文不带任何序号标记，窗口前后各附一小段上下文。
    static func segmentationInput(article: String, reference: String, contextBefore: String = "", contextAfter: String = "") -> String {
        var parts = ["请只为 <article> 内的识别稿插入换行，然后按 JSON 返回。不要改动任何文字和标点。"]
        if !contextBefore.isEmpty { parts.append("<before>\(contextBefore)</before>") }
        parts.append("<article>\(article)</article>")
        if !contextAfter.isEmpty { parts.append("<after>\(contextAfter)</after>") }
        if !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("<reference>\(reference)</reference>") }
        if !contextBefore.isEmpty || !contextAfter.isEmpty {
            parts.append("<before> 和 <after> 只是上下文，不要给它们换行，也不要把它们抄进返回结果。")
        }
        return parts.joined(separator: "\n")
    }

    /// 退回方案：逐词带序号，只让模型挑选换行序号。
    func segmentByWordIndexes(_ activeWords: [TranscriptWord], reference: String) async throws -> Set<UUID> {
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你是中文口播字幕断句器。输入是带有 [序号] 的逐词识别稿。你只能选择在哪个序号对应的词之前换行，严禁改写或复述原文。
        这是用于成片观看的字幕，不是语法分析。每条字幕至少 6 个有效字符，通常 10–24 字；语义完整比字数更重要，必要时可以稍长。
        禁止按固定字数机械换行，禁止连续多行都卡在相同字数。应优先在完整句意、自然语气停顿、话题转换和重新起句处换行。
        不得切断词语、主谓或动宾结构、介词结构、数字与单位、数量词、“的/地/得”结构、固定表达、品牌名或产品名。
        “这也是、就是、所以、但是、因为、而且、然后、但说实话”不能单独成行，必须与后面的完整意思放在一起。
        逗号只是候选分界，不是必须换行；逗号前后任一边过短或语义未完成时不得换行。句号、问号和感叹号通常是边界。顿号只表示并列，绝不能在顿号处分句。冒号不得拆开 3000:1 这类比例。
        错误示例：“这也是，\n为什么我觉得投影仪更适合租房。”
        正确示例：“这也是，为什么我觉得投影仪更适合租房。”
        错误示例：“就是花一，\n个容易接受的，\n价格。”
        正确示例：“就是花一，个容易接受的价格。”
        保留输入中所有重复、卡顿、语气词和 NG，因为你只负责断句。
        不要返回原文。只返回 JSON：{"break_before":[12,35,58]}。数组值必须是输入中真实存在且大于 0 的序号，表示在该序号的词之前换行。
        """
        let indexedArticle = activeWords.enumerated().map { "[\($0.offset)]\($0.element.text)" }.joined()
        let referenceNote = reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : """

        <reference>\(reference)</reference>
        """
        let input = """
        请为 <article> 内的实际识别稿选择换行序号。<reference> 只用于理解句意，不得从参考稿复制文字。
        <article>\(indexedArticle)</article>\(referenceNote)
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0, "max_tokens": 4096, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": rule], ["role": "user", "content": input]]]))
        var lastError: Error = AIError.invalidResponse("没有断句序号")
        for _ in 0..<2 {
            let response = try JSONDecoder().decode(ChatResponse.self, from: await AIHTTP.checkedData(for: request))
            guard let raw = response.choices.first?.message.content,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let indexes = try Self.parseSegmentationBreakIndexes(raw, wordCount: activeWords.count)
                return Set(indexes.map { activeWords[$0].id })
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parseSegmentedArticle(_ raw: String) throws -> String {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = try? JSONDecoder().decode(SegmentationPayload.self, from: Data(cleaned.utf8)), !payload.article.isEmpty { return payload.article }
        // 模型偶尔会直接在 JSON 字符串里写裸换行；补上转义后再解析一次。
        var repaired = "", inString = false, escaped = false
        for character in cleaned {
            if inString && !escaped {
                if character == "\n" { repaired += "\\n"; continue }
                if character == "\r" { repaired += "\\r"; continue }
                if character == "\t" { repaired += "\\t"; continue }
            }
            repaired.append(character)
            if character == "\"" && !escaped { inString.toggle() }
            if character == "\\" && !escaped { escaped = true } else { escaped = false }
        }
        guard let payload = try? JSONDecoder().decode(SegmentationPayload.self, from: Data(repaired.utf8)), !payload.article.isEmpty else {
            throw AIError.invalidResponse(cleaned)
        }
        return payload.article
    }

    static func parseSegmentationBreakIndexes(_ raw: String, wordCount: Int) throws -> [Int] {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? JSONDecoder().decode(SegmentationBreakPayload.self, from: Data(cleaned.utf8)) else {
            throw AIError.invalidResponse("断句序号 JSON 不完整")
        }
        let indexes = Array(Set(payload.breakBefore)).sorted()
        guard indexes.allSatisfy({ $0 > 0 && $0 < wordCount }) else {
            throw AIError.invalidResponse("断句序号超出逐词稿范围")
        }
        return indexes
    }

    func correct(reference: String, words: [TranscriptWord]) async throws -> [UUID: String] {
        if words.count > 400 {
            return try await withThrowingTaskGroup(of: [UUID: String].self) { group in
                for start in stride(from: 0, to: words.count, by: 400) {
                    let chunk = Array(words[start..<min(start + 400, words.count)])
                    group.addTask { try await correct(reference: reference, words: chunk) }
                }
                var merged: [UUID: String] = [:]
                for try await corrections in group { merged.merge(corrections) { _, latest in latest } }
                return merged
            }
        }
        // Request-local indexes avoid sending thousands of 36-character UUIDs.
        let transcript = words.enumerated().map { "\($0.offset)=\($0.element.text)" }.joined(separator: " ")
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你负责用用户提供的 Word 参考稿审阅机器字幕。
        机器字幕是唯一时间轴骨架：必须保持现有顺序、断句、数量和时间，不得新增、删除、合并、拆分或重排字幕。只修正明确的错别字、同音字、语音识别错误、品牌名、产品名和术语；极明确的漏字可并入对应 id 的 text，但不得为此改变时间轴骨架。
        参考例：大眼尘→大眼橙；自延权封闭→自研全封闭；机密Play6→极米Play6；格觉灰尘→隔绝灰尘；受命→寿命；提醒校正→梯形校正；无机旋停→无极悬停；个影→膈应；减约→简约；投方→投放；正动→转动；黑盒子白拿→黑盒子摆在那；牧羊→木羊。
        参考稿与口播不一致时以机器字幕为准；输入中没有的已删内容绝不得恢复；结尾 NG 残留、重复、卡顿和语气词保留不删。
        机器字幕中“数字=文字”的数字是临时 id。只返回文字确实发生变化的项目，严禁回传未修改项目，通常修改数量应远少于字幕字数。
        只返回 JSON：{"corrections":[{"id":"原数字","text":"修正文字"}]}，没有明确错误就返回空数组。
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": rule], ["role": "user", "content": "参考稿和要求：\n\(reference)\n\n机器字幕：\n\(transcript)"]]]))
        let data = try await AIHTTP.checkedData(for: request)
        let response = try JSONDecoder().decode(CorrectionResponse.self, from: data)
        guard let raw = response.choices.first?.message.content else { throw AIError.invalidResponse("没有校对内容") }
        return try Self.parseIndexedCorrections(raw, words: words)
    }

    func correct(reference: String, cues: [SubtitleCue], words: [TranscriptWord]) async throws -> [UUID: String] {
        let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        let lines = cues.map { cue in cue.wordIDs.compactMap { wordsByID[$0] } }
        let chunks = lines.reduce(into: [[[TranscriptWord]]]()) { chunks, line in
            if chunks.isEmpty || chunks[chunks.count - 1].reduce(0, { $0 + $1.count }) + line.count > 400 { chunks.append([]) }
            chunks[chunks.count - 1].append(line)
        }
        return try await withThrowingTaskGroup(of: [UUID: String].self) { group in
            for chunk in chunks { group.addTask { try await correctLines(reference: reference, lines: chunk) } }
            var merged: [UUID: String] = [:]
            for try await corrections in group { merged.merge(corrections) { _, latest in latest } }
            return merged
        }
    }

    private func correctLines(reference: String, lines: [[TranscriptWord]]) async throws -> [UUID: String] {
        let transcript = lines.enumerated().map { "\($0.offset)|\(Self.joinedText($0.element))" }.joined(separator: "\n")
        var request = try authorizedRequest(path: "/chat/completions")
        let rule = """
        你负责用用户提供的 Word 参考稿审阅机器字幕。
        机器字幕是唯一时间轴骨架：每个“行号|字幕”都是一条完整字幕，必须保持现有顺序和行数，不得新增、删除、合并、拆分或重排行。
        只修正明确的错别字、同音字、语音识别错误、品牌名、产品名和术语；极明确的漏字可补入原行。
        参考稿与口播不一致时以机器字幕为准；输入中没有的已删内容绝不得恢复；重复、卡顿和语气词保留不删。
        只返回文字确实发生变化的整行，行号必须来自输入。只返回 JSON：{"lines":[{"id":0,"text":"修正后的完整字幕行"}]}，无错误返回空数组。
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": rule], ["role": "user", "content": "参考稿和要求：\n\(reference)\n\n机器字幕：\n\(transcript)"]]]))
        let response = try JSONDecoder().decode(CorrectionResponse.self, from: await AIHTTP.checkedData(for: request))
        guard let raw = response.choices.first?.message.content else { throw AIError.invalidResponse("没有校对内容") }
        return try Self.parseLineCorrections(raw, lines: lines)
    }

    static func parseLineCorrections(_ raw: String, lines: [[TranscriptWord]]) throws -> [UUID: String] {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = try? JSONDecoder().decode(LineCorrectionPayload.self, from: Data(cleaned.utf8)) else { throw AIError.invalidResponse("返回 JSON 不完整或已被截断") }
        return result.lines.reduce(into: [:]) { corrections, item in
            guard lines.indices.contains(item.id), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            corrections.merge(Self.mapCorrectedLine(item.text, to: lines[item.id])) { _, latest in latest }
        }
    }

    static func mapCorrectedLine(_ corrected: String, to words: [TranscriptWord]) -> [UUID: String] {
        guard !words.isEmpty, corrected != joinedText(words) else { return [:] }
        let characters = Array(corrected)
        guard characters.count >= words.count else { return [:] }
        var replacements: [UUID: String] = [:]
        for index in words.indices {
            let start = index * characters.count / words.count
            let end = (index + 1) * characters.count / words.count
            let text = String(characters[start..<end])
            if text != words[index].text { replacements[words[index].id] = text }
        }
        return replacements
    }

    private static func joinedText(_ words: [TranscriptWord]) -> String {
        words.reduce(into: "") { text, word in
            let value = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = text.last, let first = value.first, last.isASCII && (last.isLetter || last.isNumber) && first.isASCII && (first.isLetter || first.isNumber) { text += " " }
            text += value
        }
    }

    static func parseIndexedCorrections(_ raw: String, words: [TranscriptWord]) throws -> [UUID: String] {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = try? JSONDecoder().decode(CorrectionPayload.self, from: Data(cleaned.utf8)) else { throw AIError.invalidResponse("返回 JSON 不完整或已被截断") }
        return result.corrections.reduce(into: [:]) { corrections, item in
            guard let index = Int(item.id), words.indices.contains(index), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.text != words[index].text else { return }
            corrections[words[index].id] = item.text
        }
    }

    static func parseCorrections(_ raw: String, validIDs: Set<UUID>) throws -> [UUID: String] {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = try? JSONDecoder().decode(CorrectionPayload.self, from: Data(cleaned.utf8)) else { throw AIError.invalidResponse(cleaned) }
        return result.corrections.reduce(into: [:]) { corrections, item in
            guard let id = UUID(uuidString: item.id), validIDs.contains(id), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            corrections[id] = item.text
        }
    }

    fileprivate func authorizedRequest(path: String) throws -> URLRequest {
        // 本机服务不校验 Authorization；云端后端才需要 Key。
        guard settings.isLocal || !settings.apiKey.isEmpty else { throw AIError.missingKey }
        // 本机模型比云端慢得多（长提示词能跑几分钟），超时按后端分开。
        var request = URLRequest(url: try AIHTTP.endpoint(settings, path: path), timeoutInterval: settings.isLocal ? 900 : 120)
        request.httpMethod = "POST"; request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
    private struct CorrectionResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
    private struct CorrectionPayload: Decodable { struct Item: Decodable { let id, text: String }; let corrections: [Item] }
    private struct LineCorrectionPayload: Decodable { struct Item: Decodable { let id: Int; let text: String }; let lines: [Item] }
    private struct SegmentationBreakPayload: Decodable {
        let breakBefore: [Int]
        enum CodingKeys: String, CodingKey { case breakBefore = "break_before" }
    }
    private struct SegmentationPayload: Decodable { let article: String }
    private struct StoryboardPayload: Decodable {
        struct Item: Decodable { let startIndex, endIndex: Int; let type, description, composition, movement, elements, notes: String }
        let items: [Item]
    }
}

struct AIASRClient: Sendable {
    let settings: AISettings
    static func parseText(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw AIError.invalidResponse("没有转写文字") }
        return text
    }

    static func mergeOverlappingChunks(_ chunks: [[TranscriptWord]]) -> [TranscriptWord] {
        guard var merged = chunks.first else { return [] }
        let punctuation = CharacterSet.punctuationCharacters
        func normalized(_ words: ArraySlice<TranscriptWord>) -> String {
            words.flatMap { $0.text.unicodeScalars }.filter { !punctuation.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
        }
        for chunk in chunks.dropFirst() {
            guard !merged.isEmpty, !chunk.isEmpty else { merged += chunk; continue }
            let searchLimit = min(80, merged.count, chunk.count)
            var dropCount = 0
            if searchLimit >= 2 {
                for count in stride(from: searchLimit, through: 2, by: -1) {
                    let suffix = normalized(merged.suffix(count))
                    let prefix = normalized(chunk.prefix(count))
                    if suffix.count >= 2, suffix == prefix { dropCount = count; break }
                }
            }
            if dropCount == 0 {
                // Fallback for punctuation differences: compare unequal slice lengths.
                outer: for leftCount in stride(from: searchLimit, through: 2, by: -1) {
                    let suffix = normalized(merged.suffix(leftCount))
                    guard suffix.count >= 2 else { continue }
                    for rightCount in stride(from: searchLimit, through: 2, by: -1) where normalized(chunk.prefix(rightCount)) == suffix {
                        dropCount = rightCount
                        break outer
                    }
                }
            }
            merged += chunk.dropFirst(dropCount)
        }
        return merged
    }

    static func estimatedWords(text: String, start: Double, duration: Double, speechRanges: [TimeRange]? = nil) -> [TranscriptWord] {
        let timedTokens = text.map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let weights = timedTokens.map { token -> Double in
            token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } ? 0.12 : 1
        }
        let total = weights.reduce(0, +)
        let voiced = (speechRanges ?? [.init(start: 0, end: duration)])
            .map { TimeRange(start: max(0, min(duration, $0.start)), end: max(0, min(duration, $0.end))) }
            .filter { $0.duration > 0.01 }
        guard !voiced.isEmpty else { return [] }
        let voicedDuration = voiced.reduce(0) { $0 + $1.duration }
        var groups = Array(repeating: [Int](), count: voiced.count), consumedWeight = 0.0
        for index in timedTokens.indices {
            let midpoint = (consumedWeight + weights[index] / 2) / total * voicedDuration
            var elapsed = 0.0, rangeIndex = voiced.count - 1
            for candidate in voiced.indices {
                if midpoint < elapsed + voiced[candidate].duration { rangeIndex = candidate; break }
                elapsed += voiced[candidate].duration
            }
            groups[rangeIndex].append(index)
            consumedWeight += weights[index]
        }
        var result = Array<TranscriptWord?>(repeating: nil, count: timedTokens.count)
        for rangeIndex in voiced.indices where !groups[rangeIndex].isEmpty {
            let indices = groups[rangeIndex]
            let groupWeight = indices.reduce(0.0) { $0 + weights[$1] }
            var cursor = start + voiced[rangeIndex].start
            for index in indices {
                let end = index == indices.last ? start + voiced[rangeIndex].end : min(start + voiced[rangeIndex].end, cursor + voiced[rangeIndex].duration * weights[index] / groupWeight)
                result[index] = TranscriptWord(text: timedTokens[index], start: cursor, end: end)
                cursor = end
            }
        }
        return result.compactMap { $0 }
    }

    static func retrying<T>(maxAttempts: Int = 3, initialDelayNanoseconds: UInt64 = 600_000_000, operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await operation() }
            catch {
                guard attempt < maxAttempts, isRetryable(error) else { throw error }
                try await Task.sleep(nanoseconds: initialDelayNanoseconds * UInt64(attempt))
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case AIError.rateLimited = error { return true }
        if case AIError.server(let code, _) = error { return code >= 500 }
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
    }

    private struct ChatResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
}

enum AudioChunker {
    struct Chunk: Sendable {
        let url: URL, start: Double, duration: Double
        let speechRanges: [TimeRange]
        let ownershipDuration: Double
        var speechStart: Double { speechRanges.first?.start ?? 0 }
        var speechDuration: Double { max(0.05, (speechRanges.last?.end ?? duration) - speechStart) }
    }

    static func makeWAVChunks(videoURL: URL) async throws -> [Chunk] {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { throw AIError.invalidResponse("视频没有可读取的音轨") }
        let sampleRate = Int(basic.pointee.mSampleRate.rounded())
        let channels = Int(basic.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else { throw AIError.invalidResponse("音轨采样率或声道无效") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AIError.invalidResponse("无法读取音轨") }
        let blockAlign = channels * 2
        // 远程 ASR 只回文本、没有逐词时间戳。短的重叠窗口
        // reduce boundary omissions and keep local VAD alignment tight.
        var pcm = Data()
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw AIError.invalidResponse("无法读取音频数据") }
            pcm.append(data)
        }
        guard reader.status == .completed else { throw reader.error ?? AIError.invalidResponse("音轨读取失败") }
        let windowBytes = sampleRate * blockAlign * 8
        let strideBytes = sampleRate * blockAlign * 6
        var chunks: [Chunk] = [], offset = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + windowBytes)
            let isLast = end == pcm.count
            let slice = Data(pcm[offset..<end])
            let ownership = isLast ? slice.count : min(strideBytes, slice.count)
            chunks.append(try writeWAV(slice, start: Double(offset) / Double(sampleRate * blockAlign), ownershipDuration: Double(ownership) / Double(sampleRate * blockAlign), sampleRate: sampleRate, channels: channels))
            if isLast { break }
            offset += strideBytes
        }
        return chunks
    }

    private static func writeWAV(_ pcm: Data, start: Double, ownershipDuration: Double? = nil, sampleRate: Int, channels: Int) throws -> Chunk {
        var wav = Data()
        func text(_ value: String) { wav.append(Data(value.utf8)) }
        func uint16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        func uint32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
        let blockAlign = channels * 2
        text("RIFF"); uint32(UInt32(36 + pcm.count)); text("WAVEfmt "); uint32(16); uint16(1); uint16(UInt16(channels)); uint32(UInt32(sampleRate)); uint32(UInt32(sampleRate * blockAlign)); uint16(UInt16(blockAlign)); uint16(16); text("data"); uint32(UInt32(pcm.count)); wav.append(pcm)
        let url = FileManager.default.temporaryDirectory.appending(path: "CodeCut-ASR-\(UUID().uuidString).wav")
        try wav.write(to: url, options: .atomic)
        let duration = Double(pcm.count) / Double(sampleRate * blockAlign)
        return .init(url: url, start: start, duration: duration, speechRanges: speechRanges(pcm: pcm, sampleRate: sampleRate, channels: channels), ownershipDuration: ownershipDuration ?? duration)
    }

    static func speechBounds(pcm: Data, sampleRate: Int, channels: Int) -> (start: Double, end: Double) {
        let ranges = speechRanges(pcm: pcm, sampleRate: sampleRate, channels: channels)
        let fullDuration = Double(pcm.count) / Double(max(1, sampleRate * channels * 2))
        return (ranges.first?.start ?? 0, ranges.last?.end ?? fullDuration)
    }

    static func speechRanges(pcm: Data, sampleRate: Int, channels: Int) -> [TimeRange] {
        let windowFrames = max(1, sampleRate / 50)
        var levels: [Double] = []
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            let frames = values.count / max(1, channels)
            for start in stride(from: 0, to: frames, by: windowFrames) {
                let end = min(frames, start + windowFrames)
                var sum = 0.0, samples = 0
                for frame in start..<end {
                    for channel in 0..<channels {
                        let value = Double(values[frame * channels + channel]) / 32768
                        sum += value * value; samples += 1
                    }
                }
                levels.append(samples > 0 ? sqrt(sum / Double(samples)) : 0)
            }
        }
        let fullDuration = Double(pcm.count) / Double(max(1, sampleRate * channels * 2))
        guard let peak = levels.max(), peak > 0 else { return [.init(start: 0, end: fullDuration)] }
        let sorted = levels.sorted()
        let noiseFloor = sorted[sorted.count / 5]
        let threshold = max(0.006, noiseFloor * 2.5, peak * 0.08)
        let active = levels.indices.filter { levels[$0] >= threshold }
        guard var first = active.first else { return [.init(start: 0, end: fullDuration)] }
        let windowDuration = Double(windowFrames) / Double(sampleRate)
        let bridgeWindows = max(1, Int((0.22 / windowDuration).rounded(.up)))
        var previous = first, ranges: [TimeRange] = []
        for index in active.dropFirst() {
            if index - previous > bridgeWindows {
                ranges.append(.init(start: max(0, Double(first) * windowDuration - 0.06), end: min(fullDuration, Double(previous + 1) * windowDuration + 0.06)))
                first = index
            }
            previous = index
        }
        ranges.append(.init(start: max(0, Double(first) * windowDuration - 0.06), end: min(fullDuration, Double(previous + 1) * windowDuration + 0.06)))
        return TimelineEngine.merge(ranges).filter { $0.duration >= 0.08 }
    }
}

enum AudioWaveform {
    static func samples(videoURL: URL, count: Int = 800) async throws -> [Float] {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return [] }
        let duration = try await asset.load(.duration).seconds
        let sampleRate = max(1, Int(basic.pointee.mSampleRate.rounded()))
        let channels = max(1, Int(basic.pointee.mChannelsPerFrame))
        let totalFrames = max(1, Int(duration * Double(sampleRate)))
        let samplingStride = max(1, totalFrames / max(1, count * 24))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AIError.invalidResponse("无法读取音频波形") }
        var result = Array(repeating: Float.zero, count: count), frameCursor = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                let frames = values.count / channels
                for frame in Swift.stride(from: 0, to: frames, by: samplingStride) {
                    let bucket = min(count - 1, (frameCursor + frame) * count / totalFrames)
                    for channel in 0..<channels {
                        let amplitude = Float(abs(Int32(values[frame * channels + channel]))) / 32768
                        result[bucket] = max(result[bucket], amplitude)
                    }
                }
                frameCursor += frames
            }
        }
        guard reader.status == .completed else { throw reader.error ?? AIError.invalidResponse("音频波形读取失败") }
        let peak = result.max() ?? 0
        return peak > 0 ? result.map { $0 / peak } : result
    }
}

enum VideoThumbnails {
    static func jpegData(videoURL: URL, count: Int = 24) async throws -> [Data] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [Data] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.62]) { images.append(data) }
        }
        return images
    }
}

struct AIEditClient: Sendable {
    let settings: AISettings
    func analyze(words: [TranscriptWord]) async throws -> [EditSuggestion] {
        let transcript = words.map { "id=\($0.id.uuidString) [\($0.start)-\($0.end)] \($0.text)" }.joined(separator: "\n")
        var request = try AIClient(settings: settings).authorizedRequest(path: "/chat/completions")
        let schema = "返回纯 JSON 数组。每项字段：type(filler|correction|repetition|invalid), title, reason, confidence(0-1), word_ids(UUID数组), start, end。只引用给出的UUID，不要直接执行删除。"
        request.httpBody = try JSONSerialization.data(withJSONObject: settings.requestBody(["model": settings.model, "temperature": 0.1, "response_format": ["type": "json_object"], "messages": [["role": "system", "content": "你负责找出口播中的口误、自我纠正、重复表达、填充词和无效内容。\(schema)"], ["role": "user", "content": transcript]]]))
        let data = try await AIHTTP.checkedData(for: request)
        let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        guard let raw = envelope.choices.first?.message.content else { throw AIError.invalidResponse("没有分析内容") }
        let cleaned = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = Data(cleaned.utf8)
        let items: [SuggestionDTO]
        if let direct = try? JSONDecoder().decode([SuggestionDTO].self, from: content) { items = direct }
        else if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: content) { items = wrapped.suggestions }
        else { throw AIError.invalidResponse(cleaned) }
        let validIDs = Set(words.map(\.id))
        return items.compactMap { dto in
            let ids = dto.word_ids.compactMap(UUID.init(uuidString:)).filter(validIDs.contains)
            guard !ids.isEmpty, let kind = EditSuggestion.Kind(rawValue: dto.type) else { return nil }
            return EditSuggestion(type: kind, title: dto.title, reason: dto.reason, confidence: min(1, max(0, dto.confidence)), wordIDs: ids, start: dto.start, end: dto.end)
        }
    }
    private struct ChatEnvelope: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
    private struct SuggestionDTO: Decodable { let type, title, reason: String; let confidence: Double; let word_ids: [String]; let start, end: Double }
    private struct Wrapper: Decodable { let suggestions: [SuggestionDTO] }
}

enum KeychainStore {
    private static let service = "com.codecut"
    /// 旧版本用的是 com.codecut.mimo，读取时回退一次，避免用户重新填 Key。
    private static let legacyServices = ["com.codecut.mimo"]
    nonisolated(unsafe) private static var sessionValues: [String: String] = [:]
    private static let lock = NSLock()

    struct Error: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "macOS 钥匙串保存失败：\(detail)"
        }
    }

    static func save(_ value: String, key: String) throws {
        lock.withLock { sessionValues[key] = value }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Error(status: status) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Error(status: addStatus) }
    }
    static func read(_ key: String) -> String? {
        if let value = lock.withLock({ sessionValues[key] }) { return value }
        if let value = readFromKeychain(service: service, key: key) {
            lock.withLock { sessionValues[key] = value }
            return value
        }
        for legacy in legacyServices {
            guard let value = readFromKeychain(service: legacy, key: key), !value.isEmpty else { continue }
            try? save(value, key: key)
            lock.withLock { sessionValues[key] = value }
            return value
        }
        return nil
    }
    private static func readFromKeychain(service: String, key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
}
