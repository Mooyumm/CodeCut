import AppKit
import CoreGraphics
import Foundation

/// 本机视觉大模型的接入层：llama.cpp 的 `llama-server` + Qwen3-VL（8B / 4B 可切换）。
///
/// 为什么不用 ollama：0.34.2 的 `ollama create` 从本地 GGUF 建模型这条路走不通
/// （连 `llama3.2` 这样的名字都会返回 `invalid model name`），而 llama-server
/// 一条命令就能同时挂载主干权重和视觉投影层，也没有中间格式。
///
/// 设计原则：
/// - **只跑在本机**。素材不出这台电脑，不调用任何云端接口。
/// - **模型不进 App 包**。运行时和权重都下载到 `~/Library/Application Support/CodeCut/`。
/// - 没准备好时所有调用都返回明确错误，不静默失败。
enum LocalVLMError: LocalizedError {
    case runtimeMissing
    case modelFilesMissing
    case serverUnavailable(String)
    case badResponse(String)
    case downloadFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: "本机还没有本地模型运行时。点“准备本地模型”下载一次即可。"
        case .modelFilesMissing: "本地模型权重还没下完。"
        case .serverUnavailable(let detail): "本地模型服务没有响应：\(detail)"
        case .badResponse(let detail): "本地模型返回了无法解析的内容：\(detail)"
        case .downloadFailed(let detail): "下载失败：\(detail)"
        case .cancelled: "已取消。"
        }
    }
}

/// 本地模型的准备状态，用来驱动界面提示。
enum LocalModelState: Equatable, Sendable {
    case unknown
    case checking
    case runtimeMissing
    case modelFilesMissing(Double)
    case serverDown
    case loading
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var label: String {
        switch self {
        case .unknown: "本地模型：未检查"
        case .checking: "本地模型：检查中…"
        case .runtimeMissing: "本地模型：未安装"
        case .modelFilesMissing(let progress): "本地模型：下载中 \(Int(progress * 100))%"
        case .serverDown: "本地模型：未启动"
        case .loading: "本地模型：加载中…"
        case .ready: "本地模型：\(LocalVLM.modelDisplayName) 就绪"
        case .failed(let text): "本地模型：\(text)"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .loading, .checking: "clock"
        default: "arrow.down.circle"
        }
    }
}

enum LocalVLM {
    /// 可选的本机视觉模型：换的是权重和视觉层，服务还是同一个 llama-server。
    /// 4B 大约是 8B 一半的内存、明显更快，代价是识别能力弱一些 —— 用哪一个是用户的取舍。
    enum Model: String, CaseIterable, Sendable {
        case eightB = "8B"
        case fourB = "4B"

        var displayName: String { "Qwen3-VL \(rawValue)" }
        var modelFileName: String { "Qwen3VL-\(rawValue)-Instruct-Q4_K_M.gguf" }
        var mmprojFileName: String { "mmproj-Qwen3VL-\(rawValue)-Instruct-Q8_0.gguf" }
        var modelApproxBytes: Int64 { self == .eightB ? 5_027_784_800 : 2_497_281_664 }
        var mmprojApproxBytes: Int64 { self == .eightB ? 752_289_728 : 453_974_304 }
        /// 两个模型都在同一个 ModelScope 仓库结构下，只有仓库名不同。
        var repoBase: String {
            "https://modelscope.cn/api/v1/models/Qwen/Qwen3-VL-\(rawValue)-Instruct-GGUF/repo?Revision=master&FilePath="
        }
        var note: String {
            switch self {
            case .eightB: "更准，但每次调用慢；约 5.5GB"
            case .fourB: "更快、约一半内存，识别能力弱一些；约 3GB"
            }
        }
    }

    /// 当前选用的模型（用户可切，记住选择）。
    static var selectedModel: Model {
        get { Model(rawValue: UserDefaults.standard.string(forKey: "localModelChoice") ?? "8B") ?? .eightB }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "localModelChoice") }
    }
    static var modelDisplayName: String { selectedModel.displayName }

    // MARK: - 路径

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CodeCut", directoryHint: .isDirectory)
    }
    static var modelDirectory: URL { supportDirectory.appending(path: "Models", directoryHint: .isDirectory) }
    static var runtimeDirectory: URL { supportDirectory.appending(path: "Runtime", directoryHint: .isDirectory) }
    static var llamaDirectory: URL { runtimeDirectory.appending(path: "llama.cpp", directoryHint: .isDirectory) }
    static var serverLogURL: URL { supportDirectory.appending(path: "llama-server.log") }

    static var modelFileName: String { selectedModel.modelFileName }
    static var mmprojFileName: String { selectedModel.mmprojFileName }
    static func modelFileURL() -> URL { modelDirectory.appending(path: modelFileName) }
    static func mmprojFileURL() -> URL { modelDirectory.appending(path: mmprojFileName) }

    /// llama.cpp 的预编译包。用固定版本，避免上游改动把行为带偏。
    static let llamaBuild = "b11065"
    static let runtimeArchiveURL = "https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/releases/download/\(llamaBuild)/llama-\(llamaBuild)-bin-macos-arm64.tar.gz"
    /// 模型 GGUF 走可达的镜像下载（国内直连官方源很慢）。
    static var modelRepoBase: String { selectedModel.repoBase }
    static var modelApproxBytes: Int64 { selectedModel.modelApproxBytes }
    static var mmprojApproxBytes: Int64 { selectedModel.mmprojApproxBytes }

    /// 服务端口。只监听本机回环地址。
    static let port = 8080
    /// 8080 上如果已经有**别人**（用户自己起的）在跑别的模型，我们不去动它，
    /// 改用这个端口起自己要用的模型 —— 这样换模型不需要先杀掉别的服务。
    static let fallbackPort = 8081
    /// 当前实际在用的端口（并发访问用一个锁包起来）。
    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = LocalVLM.port
        var port: Int {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private static let portBox = PortBox()
    private static var activePort: Int {
        get { portBox.port }
        set { portBox.port = newValue }
    }
    static var serverBase: URL { URL(string: "http://127.0.0.1:\(activePort)")! }
    static var currentPort: Int { activePort }

    // MARK: - 运行时

    static func serverBinary() -> URL? {
        let candidates = [
            llamaDirectory.appending(path: "llama-server").path,
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    /// 文件当前大小；读不到按 0 处理（会被当成没下完，走续传）。
    static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    // MARK: - 服务

    /// 服务是否已经加载完模型。
    static func serverReady() async -> Bool { await serverReady(port: activePort) }

    static func serverReady(port: Int) async -> Bool {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (object["status"] as? String) == "ok"
    }

    /// 服务在，但可能还在加载模型。
    static func serverResponding() async -> Bool { await serverResponding(port: activePort) }

    static func serverResponding(port: Int) async -> Bool {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse) != nil
    }

    /// 只会被本进程启动的那一个 llama-server。用锁包一层，避免多个调用点同时起两个服务。
    private final class ServerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        var value: Process? {
            get { lock.lock(); defer { lock.unlock() }; return process }
            set { lock.lock(); defer { lock.unlock() }; process = newValue }
        }
    }

    private static let serverBox = ServerBox()
    private static var ownedServer: Process? {
        get { serverBox.value }
        set { serverBox.value = newValue }
    }

    /// 起一个本地服务并等它把模型加载完。重复调用不会起第二个。
    ///
    /// 换模型时：我们自己起的服务会被停掉重起；**别人**（用户手动起的）占着 8080 且装的是
    /// 别的模型时，我们不动它，改用 8081 —— 这样切模型不需要先杀掉别的服务。
    @discardableResult
    static func ensureServer(timeout: TimeInterval = 180) async throws -> Bool {
        if await serverReady(), await serverUsesSelectedModel() { return true }

        // 我们自己起的服务装的是别的模型：停掉，换个模型重起。
        if ownedServer != nil {
            stopOwnedServer()
            try? await Task.sleep(for: .milliseconds(700))
        }

        var target = port
        if await serverResponding(port: port), !(await portUsesSelectedModel(port)) {
            target = fallbackPort
        }
        activePort = target

        if await serverResponding(port: target) {
            guard await portUsesSelectedModel(target) else {
                let name = await runningModelPath(port: target).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "另一个模型"
                throw LocalVLMError.serverUnavailable("\(target) 端口上正在跑 \(name)，不是当前选的 \(modelDisplayName)。先退出那个服务，或者把它选回来。")
            }
        } else {
            guard let binary = serverBinary() else { throw LocalVLMError.runtimeMissing }
            guard fileSize(modelFileURL()) >= modelApproxBytes,
                  fileSize(mmprojFileURL()) >= mmprojApproxBytes else { throw LocalVLMError.modelFilesMissing }
            try startServer(binary: binary, port: target)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { throw LocalVLMError.cancelled }
            if await serverReady(port: target) { return true }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        throw LocalVLMError.serverUnavailable("加载超时")
    }

    /// 某个端口上跑的是不是当前选中的模型。
    static func portUsesSelectedModel(_ port: Int) async -> Bool {
        guard let running = await runningModelPath(port: port) else { return true }
        return URL(fileURLWithPath: running).lastPathComponent == modelFileName
    }

    /// 正在跑的服务装的是哪个模型（llama-server 的 /props 会告诉我们）。
    static func runningModelPath() async -> String? { await runningModelPath(port: activePort) }

    static func runningModelPath(port: Int) async -> String? {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var request = URLRequest(url: base.appending(path: "props"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["model_path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    /// 服务上跑的是不是当前选中的模型。
    static func serverUsesSelectedModel() async -> Bool {
        guard let running = await runningModelPath() else { return true }
        return URL(fileURLWithPath: running).lastPathComponent == modelFileName
    }

    private static func startServer(binary: URL, port: Int = LocalVLM.port) throws {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelFileURL().path,
            "--mmproj", mmprojFileURL().path,
            "-c", "8192",
            "-ngl", "99",
            "--host", "127.0.0.1",
            "--port", "\(port)"
        ]
        process.currentDirectoryURL = llamaDirectory
        FileManager.default.createFile(atPath: serverLogURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: serverLogURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in Task { @MainActor in LocalVLM.ownedServer = nil } }
        try process.run()
        ownedServer = process
    }

    /// 关掉本进程起的服务；用户自己起的服务不动。App 退出时会调用。
    static func stopOwnedServer() {
        guard let process = ownedServer, process.isRunning else { return }
        process.terminate()
        ownedServer = nil
    }

    // MARK: - 下载

    static func remoteSize(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    /// 用系统自带的 curl 下载：可断点续传，进度直接看文件大小。
    static func download(from url: URL, to destination: URL, expected: Int64?, progress: @Sendable (Double) -> Void) async throws {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-L", "-C", "-", "--retry", "5", "--retry-delay", "3", "-o", destination.path, url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let total = expected ?? 0
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw LocalVLMError.cancelled
            }
            let written = fileSize(destination)
            if total > 0 { progress(min(1, Double(written) / Double(total))) }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if process.terminationStatus != 0 {
            let written = fileSize(destination)
            if total == 0 || written < total { throw LocalVLMError.downloadFailed("curl 退出码 \(process.terminationStatus)") }
        }
        progress(1)
    }

    /// 下载并解压 llama.cpp 运行时。
    static func installRuntime(progress: @Sendable (Double) -> Void) async throws {
        let archive = runtimeDirectory.appending(path: "llama-\(llamaBuild)-macos-arm64.tar.gz")
        let url = URL(string: runtimeArchiveURL)!
        try await download(from: url, to: archive, expected: await remoteSize(of: url), progress: progress)
        try? FileManager.default.createDirectory(at: llamaDirectory, withIntermediateDirectories: true)
        let unpack = runtimeDirectory.appending(path: "unpack", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: unpack)
        try await runCommand("/usr/bin/tar", ["xzf", archive.path, "-C", runtimeDirectory.path])
        // 包内目录名带版本号，这里统一摊平到 llama.cpp/ 下。
        let inner = runtimeDirectory.appending(path: "llama-\(llamaBuild)", directoryHint: .isDirectory)
        let source = FileManager.default.fileExists(atPath: inner.path) ? inner : unpack
        try copyContents(of: source, into: llamaDirectory)
        guard serverBinary() != nil else { throw LocalVLMError.downloadFailed("解压后没有找到 llama-server") }
    }

    private static func copyContents(of source: URL, into destination: URL) throws {
        guard let items = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let target = destination.appending(path: item.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: item, to: target)
        }
    }

    private static func runCommand(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                if finished.terminationStatus == 0 { continuation.resume() }
                else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: LocalVLMError.downloadFailed(text.suffix(300).description))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// 确保两个 GGUF 都在本地。
    static func ensureModelFiles(progress: @Sendable (Double) -> Void) async throws {
        let model = modelFileURL()
        let mmproj = mmprojFileURL()
        let modelURL = URL(string: modelRepoBase + modelFileName)!
        let mmprojURL = URL(string: modelRepoBase + mmprojFileName)!

        let needModel = fileSize(model) < modelApproxBytes
        let needMmproj = fileSize(mmproj) < mmprojApproxBytes
        let total = Double((needModel ? modelApproxBytes : 0) + (needMmproj ? mmprojApproxBytes : 0))
        var base: Int64 = 0

        if needModel {
            let start = min(fileSize(model), modelApproxBytes)
            let known = await remoteSize(of: modelURL) ?? modelApproxBytes
            try await download(from: modelURL, to: model, expected: known) { fraction in
                progress((Double(start) + Double(known) * fraction) / total)
            }
            base = modelApproxBytes
        }
        if needMmproj {
            let start = base
            let known = await remoteSize(of: mmprojURL) ?? mmprojApproxBytes
            try await download(from: mmprojURL, to: mmproj, expected: known) { fraction in
                progress((Double(start) + Double(known) * fraction) / total)
            }
        }
        progress(1)
    }

    // MARK: - 准备与状态

    /// 一条命令走完：装运行时 → 下模型 → 起服务。
    static func prepare(progress: @Sendable (Double, String) -> Void) async throws -> LocalModelState {
        if serverBinary() == nil {
            progress(0.01, "正在下载本地模型运行时（约 11MB）…")
            try await installRuntime { fraction in progress(fraction * 0.05, "正在下载本地模型运行时（约 11MB）…") }
        }
        if fileSize(modelFileURL()) < modelApproxBytes || fileSize(mmprojFileURL()) < mmprojApproxBytes {
            try await ensureModelFiles { fraction in
                progress(0.05 + fraction * 0.90, "正在下载 \(modelDisplayName)（约 \(modelApproxBytes / 1_000_000_000)GB，只需一次）…")
            }
        }
        progress(0.97, "正在加载本地模型…")
        _ = try await ensureServer()
        progress(1, "本地模型已就绪")
        return .ready
    }

    static func currentState() async -> LocalModelState {
        if serverBinary() == nil { return .runtimeMissing }
        if fileSize(modelFileURL()) < modelApproxBytes || fileSize(mmprojFileURL()) < mmprojApproxBytes {
            let done = Double(fileSize(modelFileURL())) / Double(modelApproxBytes + mmprojApproxBytes)
            return .modelFilesMissing(min(1, max(0, done)))
        }
        // 服务在跑、但装的是另一个模型时不算就绪：否则界面会显示“就绪”，
        // 实际却在用别的模型算（用户切了 4B 却还在跑 8B 就是这么发生的）。
        if await serverReady(), await serverUsesSelectedModel() { return .ready }
        if ownedServer != nil { return .loading }
        return .serverDown
    }

    // MARK: - 对话

    struct ChatOptions {
        var system = ""
        var prompt = ""
        var images: [Data] = []
        /// 跟在图片**后面**的补充文字。
        ///
        /// 每帧都会变的内容（比如“这一帧是 1:23 的画面”）必须放在图片后面：
        /// llama-server 会复用最长公共前缀，前缀在图片之前就变了的话，
        /// 参考图每帧都要重新编码一遍 —— 实测这一项就能让单次调用从 2 秒变成 12 秒。
        var trailingPrompt: String = ""
        var maxTokens = 512
        var timeout: TimeInterval = 600
    }

    /// 一次多模态对话，要求模型只输出 JSON。
    static func chatJSON(_ options: ChatOptions) async throws -> [String: Any] {
        _ = try await ensureServer()
        var content: [[String: Any]] = [["type": "text", "text": options.prompt]]
        for image in options.images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]
            ])
        }
        // 会变的那段文字放在图片后面：这样前缀（说明 + 参考图）在逐帧调用之间保持不变，
        // llama-server 的前缀缓存才命中得了。
        if !options.trailingPrompt.isEmpty {
            content.append(["type": "text", "text": options.trailingPrompt])
        }
        var messages: [[String: Any]] = []
        if !options.system.isEmpty { messages.append(["role": "system", "content": options.system]) }
        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": "codecut-local",
            "temperature": 0,
            "max_tokens": options.maxTokens,
            "response_format": ["type": "json_object"],
            "messages": messages
        ]

        var request = URLRequest(url: serverBase.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = options.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled { throw LocalVLMError.cancelled }
            throw LocalVLMError.serverUnavailable(error.localizedDescription)
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw LocalVLMError.badResponse("HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LocalVLMError.badResponse("响应结构不符合预期")
        }
        return try decodeJSON(text)
    }

    /// 模型偶尔会带 ```json 围栏或前导说明，这里做一次容错解析。
    static func decodeJSON(_ text: String) throws -> [String: Any] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = cleaned.range(of: "```") {
            cleaned = String(cleaned[fence.upperBound...])
            if cleaned.hasPrefix("json") { cleaned = String(cleaned.dropFirst(4)) }
            if let closing = cleaned.range(of: "```") { cleaned = String(cleaned[..<closing.lowerBound]) }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalVLMError.badResponse(text.prefix(200).description)
        }
        return object
    }

    /// 把任意图片文件读成给模型用的 JPEG（缩到 maxWidth，省显存也更快）。
    static func jpegData(from url: URL, maxWidth: CGFloat = 768, quality: CGFloat = 0.82) -> Data? {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return jpegData(from: cg, maxWidth: maxWidth, quality: quality)
    }

    static func jpegData(from cgImage: CGImage, maxWidth: CGFloat = 768, quality: CGFloat = 0.82) -> Data? {
        let width = CGFloat(cgImage.width)
        let scale = width > maxWidth ? maxWidth / width : 1
        let size = CGSize(width: max(1, width * scale), height: max(1, CGFloat(cgImage.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
