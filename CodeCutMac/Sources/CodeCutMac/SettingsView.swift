import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)?
    @AppStorage("ai.provider") private var provider = "mimo"
    @AppStorage("mimo.baseURL") private var baseURL = "https://api.xiaomimimo.com/v1"
    @AppStorage("mimo.model") private var model = "mimo-v2.5-pro"
    @AppStorage("mimo.asrModel") private var asrModel = "mimo-v2.5-asr"
    @AppStorage("mimo.asrPath") private var asrPath = "/chat/completions"
    @State private var apiKey = ""
    @AppStorage("deepseek.baseURL") private var deepSeekBaseURL = "https://api.deepseek.com"
    @AppStorage("deepseek.model") private var deepSeekModel = "deepseek-v4-flash"
    @State private var deepSeekAPIKey = ""
    @State private var saved = false
    @State private var testing = false
    @State private var testResult = ""

    private func saveAPIKey() {
        do {
            try KeychainStore.save(provider == "deepseek" ? deepSeekAPIKey : apiKey, key: provider == "deepseek" ? "deepseek.apiKey" : "mimo.apiKey")
            saved = true
            testResult = ""
        } catch {
            saved = false
            testResult = "\(error.localizedDescription)；Key 仅在本次运行中可用。请从 Xcode 使用稳定签名运行 App。"
        }
    }

    private func close() {
        saveAPIKey()
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text("AI API 设置").font(.title2.weight(.semibold)); Text("用于断句、审阅和剪辑分析；语音识别仍由本机 WhisperKit 完成").foregroundStyle(.secondary) }
                    Spacer(); Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            Section("AI 提供商") {
                Picker("使用模型", selection: $provider) {
                    Text("MiMo V2.5").tag("mimo")
                    Text("DeepSeek V4 Flash").tag("deepseek")
                }.pickerStyle(.segmented)
                Text(provider == "deepseek" ? "启用后所有文本任务只调用 DeepSeek，不再调用 MiMo。" : "当前所有文本任务使用 MiMo。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("连接") {
                SecureField("API Key", text: provider == "deepseek" ? $deepSeekAPIKey : $apiKey)
                TextField("Base URL", text: provider == "deepseek" ? $deepSeekBaseURL : $baseURL)
            }
            Section("模型") {
                TextField("文本模型", text: provider == "deepseek" ? $deepSeekModel : $model)
                if provider == "mimo" {
                    TextField("语音识别模型（保留兼容）", text: $asrModel)
                    TextField("ASR 接口路径（保留兼容）", text: $asrPath)
                }
            }
            Section {
                HStack {
                    Text("密钥保存在 macOS 钥匙串，不写入项目文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if saved { Label("已存钥匙串", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button(testing ? "测试中…" : "测试连接") { saveAPIKey(); testing = true; Task { do { try await MiMoClient(settings: .current).ping(); testResult = saved ? "连接成功" : "连接成功，但 Key 仅在本次运行中可用" } catch { testResult = error.localizedDescription }; testing = false } }.disabled(testing)
                    Button("保存") { saveAPIKey() }
                        .buttonStyle(.borderedProminent)
                    Button("完成", action: close)
                        .keyboardShortcut(.defaultAction)
                }
                if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("连接成功") ? .green : .red) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("设置")
        .onExitCommand(perform: close)
        .task {
            if asrPath == "/audio/transcriptions" { asrPath = "/chat/completions" }
            apiKey = KeychainStore.read("mimo.apiKey") ?? ""
            deepSeekAPIKey = KeychainStore.read("deepseek.apiKey") ?? ""
        }
    }
}
