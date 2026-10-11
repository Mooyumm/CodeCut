import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorModel.self) private var model
    var onClose: (() -> Void)?
    @State private var testing = false
    @State private var testResult = ""

    private func close() {
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI 设置").font(.title2.weight(.semibold))
                        Text("断句、审阅、去重分析和分镜提示词都由本机模型完成；语音识别仍由本机 WhisperKit 完成")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            Section("模型服务") {
                LabeledContent("当前服务", value: AISettings.current.serviceName)
                LabeledContent("运行方式", value: "llama.cpp · 只在本机运行（\(AISettings.localEndpoint)）")
                Text("云端 DeepSeek 接口已关闭：不需要 API Key，文字稿和素材都不会离开这台电脑。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本机模型") {
                LabeledContent("状态", value: model.localModelState.label)
                if !model.localModelNotice.isEmpty {
                    Text(model.localModelNotice).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.isPreparingLocalModel ? "准备中…" : "准备本地模型") { Task { await model.prepareLocalModel() } }
                        .disabled(model.isPreparingLocalModel)
                    Button("检查状态") { Task { await model.refreshLocalModel() } }
                    Spacer()
                    Button(testing ? "测试中…" : "测试连接") {
                        testing = true
                        Task {
                            do {
                                try await AISettings.current.prepare()
                                try await AIClient(settings: .current).ping()
                                testResult = "连接成功"
                            } catch {
                                testResult = error.localizedDescription
                            }
                            testing = false
                        }
                    }.disabled(testing)
                    Button("完成", action: close).keyboardShortcut(.defaultAction)
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("连接成功") ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("设置")
        .onExitCommand(perform: close)
        .task { await model.refreshLocalModel() }
    }
}
