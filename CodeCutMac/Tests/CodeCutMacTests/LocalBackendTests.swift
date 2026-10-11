import Foundation
import Testing
@testable import CodeCutMac

// 这一项要真的把本机 Qwen3-VL 跑起来，所以默认不跑：
//     CODECUT_REAL_MODEL_TEST=1 swift test --filter localBackendAnswers
private let localBackendRealModelEnabled = ProcessInfo.processInfo.environment["CODECUT_REAL_MODEL_TEST"] == "1"

/// DeepSeek 云端接口已关闭：默认后端必须是本机模型，且不再需要 API Key。
@Test func currentBackendIsTheLocalModel() {
    let settings = AISettings.current
    #expect(settings.backend == .local)
    #expect(settings.isLocal)
    #expect(settings.serviceName.contains("本机"))
}

/// 本机后端不校验 API Key，也不该带 DeepSeek 专有的请求字段。
@Test func localBackendNeedsNoKeyAndSendsNoThinkingField() {
    let settings = AISettings.local
    #expect(!settings.baseURL.isEmpty)
    #expect(settings.baseURL.hasSuffix("/v1"))
    #expect(settings.baseURL.hasPrefix("http://127.0.0.1:"))
    let body = settings.requestBody(["model": settings.model])
    #expect(body["thinking"] == nil)
}

/// 云端后端的代码保留着，随时可以切回去，行为不变。
@Test func cloudBackendKeepsItsOwnIdentity() {
    let settings = AISettings(baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash", apiKey: "secret")
    #expect(settings.backend == .deepSeek)
    #expect(!settings.isLocal)
    #expect(settings.serviceName == "DeepSeek")
    #expect(settings.requestBody(["model": settings.model])["thinking"] != nil)
}

/// 真实跑一遍：DeepSeek 关掉之后，当前后端（本机模型）确实能应答，全程不需要 API Key。
@Test(.enabled(if: localBackendRealModelEnabled)) func localBackendAnswersThroughTheRealServer() async throws {
    let settings = AISettings.current
    #expect(settings.apiKey == "local")
    try await settings.prepare()
    try await AIClient(settings: settings).ping()
}
