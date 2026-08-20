import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum WorkspacePage: String { case talking = "口播", storyboard = "分镜" }
    @Environment(EditorModel.self) private var model
    @AppStorage("projectSidebarCollapsed") private var projectSidebarCollapsed = false
    @State private var dropTargeted = false
    @State private var workspacePage = WorkspacePage.talking

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopBar(projectSidebarCollapsed: $projectSidebarCollapsed)
            TaskBanner()
            Divider()
            Group {
                if workspacePage == .talking { talkingWorkspace }
                else { StoryboardWorkspace(projectSidebarCollapsed: $projectSidebarCollapsed) }
            }
            WorkspaceBottomBar(page: $workspacePage)
        }
        .background(Color(red: 0.075, green: 0.082, blue: 0.09))
        .tint(Color(red: 0.15, green: 0.48, blue: 0.82))
        .preferredColorScheme(.dark)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).stroke(.indigo, lineWidth: 3).padding(8).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; Task { await model.importVideo(url) }; return true } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.movie]) { result in if case .success(let url) = result { Task { await model.importVideo(url) } } }
        .fileImporter(isPresented: $model.showProjectImporter, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case .success(let url):
                Task { do { try await model.openProject(url) } catch { model.taskState = .failed(error.localizedDescription) } }
            case .failure(let error): model.taskState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $model.showRelinkImporter, allowedContentTypes: [.movie]) { result in if case .success(let url) = result { Task { await model.relinkSource(url) } } }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(onClose: { model.showSettings = false })
                .environment(model)
                .frame(width: 560, height: 440)
        }
    }

    private var talkingWorkspace: some View {
        HSplitView {
            if !projectSidebarCollapsed {
                ProjectSidebar(onCollapse: { projectSidebarCollapsed = true }).frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            }
            VSplitView {
                VStack(spacing: 0) { PanelHeader(title: "素材", icon: "film.stack"); AssetsView() }.frame(minHeight: 150, idealHeight: 220)
                ChatPanel().frame(minHeight: 300)
            }.frame(minWidth: 290, idealWidth: 340, maxWidth: 460)
            MediaPanel().frame(minWidth: 290, idealWidth: 360, maxWidth: 460)
            VSplitView { ViewerPanel().frame(minHeight: 330); TimelinePanel().frame(minHeight: 220, idealHeight: 270) }.frame(minWidth: 520)
        }
    }
}

struct ProjectSidebar: View {
    @Environment(EditorModel.self) private var model
    let onCollapse: () -> Void
    @State private var renameURL: URL?
    @State private var renameText = ""
    @State private var deleteURL: URL?
    @State private var refreshID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("项目").font(.headline)
                Spacer()
                Button { model.newProject(); model.showImporter = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建项目")
                Button(action: onCollapse) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("折叠项目栏")
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(ProjectStore.recentProjects(), id: \.path) { url in
                        Button {
                            Task { do { try await model.openProject(url) } catch { model.taskState = .failed(error.localizedDescription) } }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "film")
                                Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                Spacer()
                            }.padding(.horizontal, 9).frame(height: 34)
                                .background(model.projectURL == url ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("重命名…", systemImage: "pencil") { renameURL = url; renameText = url.deletingPathExtension().lastPathComponent }
                                Button("移到废纸篓", systemImage: "trash", role: .destructive) { deleteURL = url }
                            }
                    }
                }.padding(8).id(refreshID)
            }
            Divider()
            Button { model.showProjectImporter = true } label: { Label("打开其他项目…", systemImage: "folder") }.buttonStyle(.plain).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .alert("重命名项目", isPresented: Binding(get: { renameURL != nil }, set: { if !$0 { renameURL = nil } })) {
                TextField("项目名称", text: $renameText)
                Button("取消", role: .cancel) { renameURL = nil }
                Button("重命名") {
                    guard let url = renameURL else { return }
                    do { try model.renameProject(url, to: renameText); refreshID = UUID(); renameURL = nil }
                    catch { model.taskState = .failed(error.localizedDescription) }
                }
            }
            .confirmationDialog("将这个项目移到废纸篓？", isPresented: Binding(get: { deleteURL != nil }, set: { if !$0 { deleteURL = nil } }), titleVisibility: .visible) {
                Button("移到废纸篓", role: .destructive) {
                    guard let url = deleteURL else { return }
                    do { try model.deleteProject(url); refreshID = UUID(); deleteURL = nil; model.taskState = .done("项目已移到废纸篓，可在 Finder 中恢复") }
                    catch { model.taskState = .failed(error.localizedDescription) }
                }
                Button("取消", role: .cancel) { deleteURL = nil }
            }
    }
}

private struct TopBar: View {
    @Environment(EditorModel.self) private var model
    @Binding var projectSidebarCollapsed: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button { projectSidebarCollapsed.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain)
                .help(projectSidebarCollapsed ? "展开项目栏" : "折叠项目栏")
            Image(systemName: "scissors").font(.title3.weight(.semibold)).foregroundStyle(.indigo)
            Text("CutFlow").font(.headline)
            Divider().frame(height: 18)
            Text(model.projectName).foregroundStyle(.secondary).lineLimit(1)
            if model.hasUnsavedChanges { Circle().fill(.orange).frame(width: 6, height: 6).help("有未保存更改") }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z").disabled(!model.canUndo).help("撤销 ⌘Z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo).help("重做 ⇧⌘Z")
            Divider().frame(height: 18)
            Menu {
                Button("DaVinci Resolve 时间线 + 字幕", systemImage: "film.stack") { export(.resolve) }
                Button("Final Cut Pro 时间线 + 字幕", systemImage: "film") { export(.finalCutPro) }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.edl == nil || model.isWorking)
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("AI API 设置")
        }.padding(.horizontal, 16).frame(height: 50).background(.ultraThinMaterial)
    }
    private func export(_ format: TimelineExporter.Format) {
        guard let edl = model.edl else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "导出"
        if panel.runModal() == .OK, let folder = panel.url {
            do {
                try TimelineExporter.export(edl, projectName: model.projectName, folder: folder, format: format)
                let target = format == .resolve ? "DaVinci Resolve EDL" : "Final Cut Pro FCPXML"
                model.taskState = .done("已导出 \(target) 和独立 SRT 字幕轨道")
            } catch { model.taskState = .failed("导出失败：\(error.localizedDescription)") }
        }
    }
}

private struct TaskBanner: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        Group {
            switch model.taskState {
            case .idle: EmptyView()
            case .working(let text): HStack {
                if let progress = model.reviewProgress { ProgressView(value: progress).frame(width: 90) }
                else { ProgressView().controlSize(.small) }
                Text(text); Spacer()
            }.foregroundStyle(.secondary)
            case .failed(let text): HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(text); Spacer(); Button("关闭") { model.taskState = .idle } }.foregroundStyle(.red)
            case .done(let text): HStack { Image(systemName: "checkmark.circle.fill"); Text(text); Spacer(); Button("关闭") { model.taskState = .idle } }.foregroundStyle(.green)
            }
        }.font(.caption).padding(.horizontal, 14).frame(height: model.taskState == .idle ? 0 : 30).background(.bar)
    }
}

private struct ChatPanel: View {
    @Environment(EditorModel.self) private var model
    var pending: [EditSuggestion] { model.suggestions.filter { $0.state == .pending } }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack { PanelHeader(title: "AI 剪辑", icon: "sparkles"); if !pending.isEmpty { Menu("批量") { Button("全部删除") { model.decideAll(delete: true) }; Button("全部保留") { model.decideAll(delete: false) } }.padding(.trailing, 8) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            if message.role == .status {
                                Label(message.text, systemImage: message.text.hasPrefix("MiMo 正在") ? "ellipsis.circle" : (message.text.hasPrefix("请求失败") ? "exclamationmark.circle" : "checkmark.circle"))
                                    .font(.caption)
                                    .foregroundStyle(message.text.hasPrefix("请求失败") ? Color.red : Color.secondary)
                                    .frame(maxWidth: .infinity)
                                    .id(message.id)
                            } else {
                                Text(message.text).font(.system(size: 16)).textSelection(.enabled).padding(11)
                                    .background(message.role == .user ? Color.indigo.opacity(0.18) : Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading).id(message.id)
                            }
                        }
                        ForEach(pending) { SuggestionCard(item: $0) }
                        ForEach(model.breaths.filter { $0.state == .pending }) { BreathCard(item: $0) }
                    }.padding(12)
                }.onChange(of: model.messages.count) { _, _ in if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextField("告诉 MiMo 你想如何剪辑…", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(2...6).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .onSubmit { Task { await model.sendPrompt() } }
                HStack {
                    Label("MiMo V2.5", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("↩ 发送").font(.caption2).foregroundStyle(.tertiary)
                    Button { Task { await model.sendPrompt() } } label: { Image(systemName: model.isWorking ? "ellipsis" : "arrow.up").frame(width: 24, height: 24) }
                        .buttonStyle(.borderedProminent).clipShape(Circle()).disabled(model.isWorking || (model.words.isEmpty && model.manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12).frame(minHeight: 112)
        }
    }
}

private struct SuggestionCard: View {
    @Environment(EditorModel.self) private var model; let item: EditSuggestion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(item.title, systemImage: "wand.and.stars").font(.subheadline.weight(.semibold)); Spacer(); Text("\(Int(item.confidence * 100))%").font(.caption).foregroundStyle(.secondary) }
            Text(item.reason).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.2f–%.2f 秒", item.start, item.end)).font(.caption2).monospacedDigit()
            HStack { Button("试听") { model.preview(.init(start: item.start, end: item.end)) }; Spacer(); Button("保留") { model.decide(item.id, delete: false) }; Button("删除") { model.decide(item.id, delete: true) }.buttonStyle(.borderedProminent).tint(.red) }
        }.cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { model.focusSuggestion(item) }
    }
}

private struct BreathCard: View {
    @Environment(EditorModel.self) private var model; let item: BreathCandidate
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("气口 \(String(format: "%.2f", item.duration)) 秒", systemImage: "waveform.path").font(.subheadline.weight(.semibold))
            Text("\(item.leftText)  …  \(item.rightText)").font(.caption).foregroundStyle(.secondary)
            HStack { Button("试听") { model.preview(.init(start: item.start, end: item.end)) }; Spacer(); Button("保留") { model.decideBreath(item.id, delete: false) }; Button("删除") { model.decideBreath(item.id, delete: true) }.buttonStyle(.borderedProminent).tint(.red) }
        }.cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { model.focusBreath(item) }
    }
}

private struct MediaPanel: View {
    var body: some View {
        TranscriptView()
    }
}

private struct AssetsView: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            if let url = model.videoURL {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: "film").font(.title2); VStack(alignment: .leading, spacing: 3) { Text(url.lastPathComponent).lineLimit(1); Text("\(timecode(model.duration)) · \(String(format: "%.2f", model.frameRate)) fps").font(.caption).foregroundStyle(.secondary) }; Spacer() }
                    HStack {
                        Button { Task { await model.resegmentWithMiMo() } } label: { Label("重新断句", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .disabled(model.isWorking)
                        Button { Task { await model.transcribe(forceRecognition: true) } } label: { Label("重新识别", systemImage: "waveform.badge.mic") }
                            .buttonStyle(.borderedProminent).disabled(model.isWorking)
                    }
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else { ContentUnavailableView("尚无素材", systemImage: "film.stack", description: Text("拖入视频或点击顶部“导入”")) }
            Spacer()
        }.padding(12)
    }
}

private struct TranscriptView: View {
    @Environment(EditorModel.self) private var model
    @FocusState private var manuscriptFocused: Bool
    @State private var batchMode = false
    var body: some View {
        @Bindable var model = model
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    PanelHeader(title: "文字稿", icon: "text.quote")
                    Button("审阅") { Task { await model.reviewManuscript() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.words.isEmpty || model.isWorking)
                        .padding(.trailing, 10)
                }
                TextEditor(text: $model.manuscript)
                    .font(.system(size: 16)).scrollContentBackground(.hidden).padding(10)
                    .focused($manuscriptFocused)
                    .overlay(alignment: .topLeading) {
                        if model.manuscript.isEmpty { Text("粘贴或输入用于校对的 Word 文字稿…").foregroundStyle(.tertiary).padding(16).allowsHitTesting(false) }
                    }
                    .onChange(of: model.manuscript) { _, text in model.updateManuscript(text) }
                if !model.pendingReviewCorrections.isEmpty {
                    Divider()
                    HStack {
                        Text("红色为待确认修改").font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("取消") { model.cancelReview() }
                        Button("采用") { model.acceptReview() }.buttonStyle(.borderedProminent)
                    }.padding(.horizontal, 10).frame(height: 38)
                }
            }.frame(minHeight: 100)
            VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Label("字幕", systemImage: "captions.bubble").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("重新断句") { Task { await model.resegmentWithMiMo() } }
                            .disabled(model.videoURL == nil || model.isWorking)
                        if batchMode {
                            Button("全选") { model.selectAllSubtitles() }
                            Button("清除") { model.selectedWordIDs = [] }.disabled(model.selectedWordIDs.isEmpty)
                            Button("删除所选（\(model.selectedWordIDs.count)）", role: .destructive) {
                                model.deleteSubtitles(model.selectedWordIDs)
                                model.selectedWordIDs = []
                            }.disabled(model.selectedWordIDs.isEmpty)
                        }
                        Button(batchMode ? "完成" : "批量选择") {
                            batchMode.toggle()
                            if !batchMode { model.selectedWordIDs = [] }
                        }.disabled(model.words.isEmpty)
                    }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    if model.words.isEmpty {
                        ContentUnavailableView {
                            Label("暂无字幕", systemImage: "captions.bubble")
                        } description: {
                            Text("已清空字幕，可以使用本机缓存重新生成。")
                        } actions: {
                            HStack {
                                Button("重新断句") { Task { await model.resegmentWithMiMo() } }
                                Button("重新识别") { Task { await model.transcribe(forceRecognition: true) } }
                                    .buttonStyle(.borderedProminent)
                            }.disabled(model.videoURL == nil || model.isWorking)
                        }
                    } else { ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(model.subtitleCues) { cue in
                                    EditableCueRow(cue: cue, batchMode: batchMode).id(cue.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: model.selectedWordIDs.first) { _, first in
                            guard let first, let cue = model.subtitleCues.first(where: { $0.wordIDs.contains(first) }) else { return }
                            withAnimation { proxy.scrollTo(cue.id, anchor: .center) }
                        }
                        .onChange(of: model.focusRequestID) { _, _ in
                            guard let first = model.focusedWordID, let cue = model.subtitleCues.first(where: { $0.wordIDs.contains(first) }) else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(cue.id, anchor: .center) }
                        }
                    }
                    }
            }.frame(minHeight: 100)
        }
    }
}

private struct EditableCueRow: View {
    @Environment(EditorModel.self) private var model
    let cue: SubtitleCue
    let batchMode: Bool
    @State private var text: String
    @State private var isEditing = false
    init(cue: SubtitleCue, batchMode: Bool) { self.cue = cue; self.batchMode = batchMode; _text = State(initialValue: cue.text) }
    var body: some View {
        let repetition = model.suggestions.first { $0.type == .repetition && $0.state == .pending && !Set($0.wordIDs).isDisjoint(with: cue.wordIDs) }
        let retained = repetition == nil && model.suggestions.contains { $0.type == .repetition && $0.state == .pending && !Set($0.retainedWordIDs ?? []).isDisjoint(with: cue.wordIDs) }
        let transientHighlight = model.isTransientlyHighlighted(cue)
        HStack(alignment: .center, spacing: 7) {
            if batchMode {
                Button { model.toggleSubtitleSelection(cue) } label: {
                    Image(systemName: model.isSelected(cue) ? "checkmark.square.fill" : "square")
                }.buttonStyle(.plain).foregroundStyle(model.isSelected(cue) ? Color.accentColor : .secondary)
            }
            Button(preciseTimecode(cue.start)) { model.selectSubtitle(cue, additive: NSEvent.modifierFlags.contains(.command)) }.buttonStyle(.plain).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            if isEditing && !batchMode {
                InlineSubtitleTextField(text: $text, onCommit: commit, onDeleteAtStart: {
                    model.mergeSubtitle(startingWith: cue.wordIDs.first)
                    isEditing = false
                }, onSplit: { offset in
                    model.splitSubtitle(cue, text: text, atCharacterOffset: offset)
                    isEditing = false
                }).frame(minHeight: 20)
            } else {
                HStack(spacing: 6) {
                    proposedText.font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                    if let repetition {
                        Label("重复", systemImage: "arrow.trianglehead.2.clockwise.rotate.90").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        Button(role: .destructive) { model.decide(repetition.id, delete: true) } label: {
                            Image(systemName: "trash").frame(width: 20, height: 18)
                        }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.mini).help("删除这条重复字幕并跳到下一条")
                    }
                }.contentShape(Rectangle())
                    .onTapGesture(count: 2) { guard !batchMode else { return }; text = cue.text; isEditing = true }
                    .onTapGesture { batchMode ? model.toggleSubtitleSelection(cue) : model.selectSubtitle(cue, additive: NSEvent.modifierFlags.contains(.command)) }
            }
        }.padding(6)
            .background(transientHighlight ? Color.orange.opacity(0.32 * model.transientHighlightOpacity) : (model.isSelected(cue) ? Color.accentColor.opacity(0.18) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(transientHighlight ? Color.orange.opacity(model.transientHighlightOpacity) : (retained ? Color.mint : .clear), lineWidth: 2))
    }
    private func commit() { model.editSubtitle(cue, text: text); isEditing = false }
    private var proposedText: Text {
        if Set(cue.wordIDs).isDisjoint(with: model.pendingReviewCorrections.keys) { return Text(cue.text) }
        return cue.wordIDs.reduce(Text("")) { result, id in
            guard let word = model.words.first(where: { $0.id == id }) else { return result }
            let isLast = id == cue.wordIDs.last
            if let corrected = model.pendingReviewCorrections[id] {
                return result + Text(displayText(corrected, isLast: isLast)).foregroundColor(.red).underline(true, color: .red)
            }
            return result + Text(displayText(word.text, isLast: isLast))
        }
    }
    private func displayText(_ text: String, isLast: Bool) -> String {
        let text = TimelineEngine.subtitleDisplayText(text)
        return isLast ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

private struct InlineSubtitleTextField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onDeleteAtStart: () -> Void
    let onSplit: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field.currentEditor() ?? field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineSubtitleTextField
        init(_ parent: InlineSubtitleTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange().location == 0, textView.selectedRange().length == 0 {
                parent.onDeleteAtStart(); return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let utf16Offset = min(textView.selectedRange().location, (textView.string as NSString).length)
                let prefix = (textView.string as NSString).substring(to: utf16Offset)
                parent.onSplit(prefix.filter { !$0.isWhitespace }.count)
                return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onCommit() }
    }
}

private struct WordButton: View {
    @Environment(EditorModel.self) private var model; let word: TranscriptWord
    var body: some View {
        Button(word.text) { model.toggleWord(word.id) }.buttonStyle(.plain).padding(.horizontal, 5).padding(.vertical, 3)
            .background(word.isDeleted ? Color.red.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 4)).strikethrough(word.isDeleted, color: .red).foregroundStyle(word.isDeleted ? .secondary : .primary)
            .contextMenu { Button("播放这里") { model.seek(to: word.start); model.player.play() }; Button("仅定位") { model.seek(to: word.start) } }
            .help(String(format: "%.2f–%.2f 秒", word.start, word.end))
    }
}

struct ViewerPanel: View {
    @Environment(EditorModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            HStack { PanelHeader(title: "预览", icon: "play.rectangle"); Spacer(); Text("\(timecode(model.currentTime)) / \(timecode(model.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 12) }
            ZStack {
                Color.black
                NativePlayerView(player: model.player)
                if model.burnSubtitles, let cue = model.activeSubtitle {
                    VStack { Spacer(); Text(cue.text).font(.system(size: max(16, model.subtitleFontSize * 0.52), weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 7)).padding(.bottom, 28).padding(.horizontal, 24) }
                }
                if model.videoURL == nil {
                    Color.black
                    VStack(spacing: 12) { Image(systemName: "arrow.down.doc").font(.largeTitle); Text("将视频拖入项目或点击“导入”").foregroundStyle(.secondary) }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8)).padding(12)
        }
    }
}

private struct TimelinePanel: View {
    @Environment(EditorModel.self) private var model
    @State private var pointsPerSecond = 24.0
    @State private var lastFollowTick = -1
    @State private var leftDragOrigin: Double?
    @State private var rightDragOrigin: Double?
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Label("时间线", systemImage: "timeline.selection").font(.subheadline.weight(.semibold))
                Divider().frame(height: 18)
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.keyboardShortcut(.space, modifiers: []).help("播放/暂停 Space")
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }.help("回到开头")
                Divider().frame(height: 18)
                Button { model.splitSubtitle(at: model.currentTime); model.selectedWordIDs = [] } label: { Image(systemName: "scissors") }.keyboardShortcut("b").disabled(model.words.isEmpty).help("在播放头处分割字幕 ⌘B")
                Button { model.mergeSubtitle(startingWith: model.selectedWordIDs.first); model.selectedWordIDs = [] } label: { Image(systemName: "rectangle.2.swap") }.disabled(model.selectedWordIDs.isEmpty).help("将所选字幕与上一条合并")
                Button { model.deleteSubtitles(model.selectedWordIDs); model.selectedWordIDs = [] } label: { Image(systemName: "trash") }.disabled(model.selectedWordIDs.isEmpty).help("仅删除所选字幕，不剪切视频或音频")
                Button { model.cleanupShortFragments() } label: { Label("清理碎片", systemImage: "sparkles") }
                    .disabled(model.shortFragments.isEmpty)
                    .help("删除两处剪切之间小于 0.35 秒的孤立音视频片段，可撤销")
                if !model.selectedWordIDs.isEmpty { Text("已选 \(model.selectedWordIDs.count) 词").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text("\(preciseTimecode(timelineCurrentTime)) / \(preciseTimecode(timelineDuration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(height: 38).background(.thinMaterial)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    timelineDisplayControls.fixedSize()
                    Spacer(minLength: 12)
                    timelineAnalysisControls.fixedSize()
                }

                VStack(spacing: 5) {
                    HStack(spacing: 9) {
                        timelineDisplayControls.fixedSize()
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 9) {
                        Spacer(minLength: 0)
                        timelineAnalysisControls.fixedSize()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { timelineCanvas.padding(.vertical, 8) }
                    .background(timelineBackground)
                    .onChange(of: Int(model.currentTime)) { _, _ in
                        guard model.isPlaying else { return }
                        followPlayhead(Int(timelineCurrentTime), with: proxy)
                    }
                    .onChange(of: model.isPlaying) { _, playing in if playing { followPlayhead(Int(timelineCurrentTime), with: proxy) } }
                    .onChange(of: model.focusRequestID) { _, _ in
                        lastFollowTick = -1
                        followPlayhead(Int(timelineCurrentTime), with: proxy)
                    }
            }
        }
        .onDeleteCommand { model.deleteSubtitles(model.selectedWordIDs); model.selectedWordIDs = [] }
        .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
    }

    private let labelWidth = 68.0
    private let timelineBackground = Color(red: 0.095, green: 0.105, blue: 0.12)
    private let videoClipColor = Color(red: 0.18, green: 0.39, blue: 0.56)
    private let audioClipColor = Color(red: 0.16, green: 0.45, blue: 0.36)
    private let subtitleClipColor = Color(red: 0.34, green: 0.43, blue: 0.52)
    private let selectedOutline = Color(red: 1.0, green: 0.72, blue: 0.16)

    @ViewBuilder
    private var timelineDisplayControls: some View {
        Toggle("字幕", isOn: Binding(get: { model.burnSubtitles }, set: { model.setBurnSubtitles($0) }))
            .toggleStyle(.switch)
            .controlSize(.mini)
        Stepper("\(Int(model.subtitleFontSize))", value: Binding(get: { model.subtitleFontSize }, set: { model.setSubtitleFontSize($0) }), in: 24...80, step: 2)
            .frame(width: 78)
            .controlSize(.mini)
            .help("字幕字号")
        Divider().frame(height: 18)
        Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
        Slider(value: $pointsPerSecond, in: 8...100)
            .frame(width: 110)
            .help("缩放时间轴")
        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var timelineAnalysisControls: some View {
        Picker("气口", selection: Binding(get: { model.breathMode }, set: { model.breathMode = $0 })) {
            ForEach(EditorModel.BreathMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .frame(width: 150)
        .controlSize(.small)
        Picker("去重", selection: Binding(get: { model.dedupeMode }, set: { model.dedupeMode = $0 })) {
            ForEach(EditorModel.DedupeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .frame(width: 150)
        .controlSize(.small)
        Button("执行") { model.executeDedupe() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.words.isEmpty)
    }

    private var timelineDuration: Double { max(0, model.outputDuration) }
    private var timelineCurrentTime: Double { TimelineEngine.outputTime(for: model.currentTime, deleted: model.deletedRanges) }
    private var canvasWidth: Double { max(760, labelWidth + timelineDuration * pointsPerSecond + 40) }
    private var tickInterval: Int { pointsPerSecond >= 60 ? 1 : (pointsPerSecond >= 20 ? 5 : 10) }
    private var wholeSeconds: ClosedRange<Int> { 0...max(1, Int(timelineDuration.rounded(.up))) }
    private func followPlayhead(_ second: Int, with proxy: ScrollViewProxy) {
        let target = min(wholeSeconds.upperBound, max(0, second))
        guard target != lastFollowTick else { return }
        lastFollowTick = target
        withAnimation(.linear(duration: 0.12)) { proxy.scrollTo("timeline-second-\(target)", anchor: .center) }
    }
    private var timelineCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth)
                ForEach(wholeSeconds, id: \.self) { second in
                    Color.clear.frame(width: pointsPerSecond, height: 1).id("timeline-second-\(second)")
                }
            }.frame(height: 1)
            ForEach(Array(stride(from: 0, through: max(tickInterval, Int(timelineDuration.rounded(.up))), by: tickInterval)), id: \.self) { second in
                let x = labelWidth + Double(second) * pointsPerSecond
                Rectangle().fill(Color.white.opacity(second % (tickInterval * 2) == 0 ? 0.15 : 0.08)).frame(width: 1, height: 176).offset(x: x, y: 22)
                Text(axisLabel(second)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.62)).offset(x: x + 3, y: 2)
            }
            trackLabel("CC", icon: "captions.bubble", y: 42)
            trackLabel("V1", icon: "film", y: 88)
            trackLabel("A1", icon: "waveform", y: 134)
            trackBackground(y: 38); trackBackground(y: 84); trackBackground(y: 130)
            if let url = model.videoURL {
                ForEach(Array(model.keptRanges.enumerated()), id: \.offset) { index, range in
                    mediaClip(text: index == 0 ? url.lastPathComponent : "片段 \(index + 1)", color: videoClipColor, y: 84, range: range, showsThumbnails: true)
                    mediaClip(text: index == 0 ? "原始音频" : "音频 \(index + 1)", color: audioClipColor, y: 130, range: range, showsWaveform: true)
                }
                trimHandle(isStart: true)
                trimHandle(isStart: false)
            }
            ForEach(model.subtitleCues.filter { $0.end > model.trimStart && $0.start < model.effectiveTrimEnd }) { cue in
                let visibleStart = TimelineEngine.outputTime(for: max(cue.start, model.trimStart), deleted: model.deletedRanges)
                let visibleEnd = TimelineEngine.outputTime(for: min(cue.end, model.effectiveTrimEnd), deleted: model.deletedRanges)
                let width = max(3, (visibleEnd - visibleStart) * pointsPerSecond - 2)
                let transientHighlight = model.isTransientlyHighlighted(cue)
                let selected = model.isSelected(cue)
                let fillColor = transientHighlight ? Color.orange.opacity(0.55 * model.transientHighlightOpacity) : (selected ? subtitleClipColor.opacity(0.96) : subtitleClipColor.opacity(0.78))
                let strokeColor = transientHighlight ? Color.orange.opacity(model.transientHighlightOpacity) : (selected ? selectedOutline : Color.black.opacity(0.65))
                RoundedRectangle(cornerRadius: 4)
                    .fill(fillColor)
                    .frame(width: width, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(strokeColor, lineWidth: transientHighlight || selected ? 2 : 1))
                    .overlay(Text(cue.text).font(.caption2.weight(.medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 5), alignment: .leading)
                    .offset(x: labelWidth + visibleStart * pointsPerSecond + 1, y: 38)
                    .onTapGesture { model.selectSubtitle(cue, additive: NSEvent.modifierFlags.contains(.command)) }
            }
            if let breath = model.transientHighlightedBreath {
                let visibleStart = TimelineEngine.outputTime(for: breath.start, deleted: model.deletedRanges)
                let visibleEnd = TimelineEngine.outputTime(for: breath.end, deleted: model.deletedRanges)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.28 * model.transientHighlightOpacity))
                    .frame(width: max(4, (visibleEnd - visibleStart) * pointsPerSecond), height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(model.transientHighlightOpacity), lineWidth: 3))
                    .shadow(color: Color.orange.opacity(0.65 * model.transientHighlightOpacity), radius: 5)
                    .offset(x: labelWidth + visibleStart * pointsPerSecond, y: 130)
                    .allowsHitTesting(false)
            }
            Rectangle().fill(Color(red: 0.96, green: 0.28, blue: 0.24)).frame(width: 2, height: 176)
                .offset(x: labelWidth + min(timelineDuration, max(0, timelineCurrentTime)) * pointsPerSecond, y: 22)
                .shadow(color: .red.opacity(0.35), radius: 2)
        }
        .frame(width: canvasWidth, height: 206, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard value.location.x >= labelWidth else { return }
            let outputTime = min(timelineDuration, max(0, (value.location.x - labelWidth) / pointsPerSecond))
            model.seek(to: TimelineEngine.sourceTime(for: outputTime, kept: model.keptRanges))
        })
    }
    private func trackLabel(_ text: String, icon: String, y: Double) -> some View {
        Label(text, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.68)).frame(width: labelWidth - 8, alignment: .leading).offset(x: 8, y: y + 9)
    }
    private func trackBackground(y: Double) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.045)).frame(width: canvasWidth - labelWidth, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .offset(x: labelWidth, y: y)
    }
    private func mediaClip(text: String, color: Color, y: Double, range: TimeRange, showsWaveform: Bool = false, showsThumbnails: Bool = false) -> some View {
        let width = max(3, range.duration * pointsPerSecond - 2)
        let waveform = waveformSamples(for: range)
        let thumbnails = thumbnailData(for: range)
        return RoundedRectangle(cornerRadius: 4).fill(color).frame(width: width, height: 36)
            .overlay {
                if showsThumbnails && !thumbnails.isEmpty {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, data in
                                if let image = NSImage(data: data) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: geometry.size.width / CGFloat(thumbnails.count), height: geometry.size.height).clipped() }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 4)).opacity(0.62)
                }
            }
            .overlay { if showsWaveform && !waveform.isEmpty { WaveformShape(samples: waveform).stroke(Color.white.opacity(0.72), lineWidth: 1) } }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.7), lineWidth: 1))
            .overlay(Text(text).font(.caption2.weight(.medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8), alignment: .leading)
            .offset(x: labelWidth + TimelineEngine.outputTime(for: range.start, deleted: model.deletedRanges) * pointsPerSecond + 1, y: y)
    }
    private func waveformSamples(for range: TimeRange) -> [Float] {
        guard model.duration > 0, !model.waveform.isEmpty else { return [] }
        let lower = min(model.waveform.count, max(0, Int(range.start / model.duration * Double(model.waveform.count))))
        let upper = min(model.waveform.count, max(lower, Int(range.end / model.duration * Double(model.waveform.count))))
        return Array(model.waveform[lower..<upper])
    }
    private func thumbnailData(for range: TimeRange) -> [Data] {
        guard model.duration > 0, !model.thumbnails.isEmpty else { return [] }
        let lower = min(model.thumbnails.count - 1, max(0, Int(range.start / model.duration * Double(model.thumbnails.count))))
        let upper = min(model.thumbnails.count, max(lower + 1, Int(ceil(range.end / model.duration * Double(model.thumbnails.count)))))
        return Array(model.thumbnails[lower..<upper])
    }
    private func trimHandle(isStart: Bool) -> some View {
        let time = TimelineEngine.outputTime(for: isStart ? model.trimStart : model.effectiveTrimEnd, deleted: model.deletedRanges)
        return ZStack(alignment: isStart ? .leading : .trailing) {
            Rectangle().fill(Color.yellow).frame(width: 3, height: 82)
            RoundedRectangle(cornerRadius: 2).fill(Color.yellow).frame(width: 9, height: 16).offset(x: isStart ? -3 : 3, y: -33)
        }
        .frame(width: 10, height: 82)
        .offset(x: labelWidth + time * pointsPerSecond - 5, y: 84)
        .help(isStart ? "拖动入点" : "拖动出点")
        .gesture(DragGesture().onChanged { value in
            if isStart {
                if leftDragOrigin == nil { leftDragOrigin = model.trimStart; model.beginTrimEdit() }
                model.updateTrimStart((leftDragOrigin ?? model.trimStart) + value.translation.width / pointsPerSecond)
            } else {
                if rightDragOrigin == nil { rightDragOrigin = model.effectiveTrimEnd; model.beginTrimEdit() }
                model.updateTrimEnd((rightDragOrigin ?? model.effectiveTrimEnd) + value.translation.width / pointsPerSecond)
            }
        }.onEnded { _ in
            if isStart { leftDragOrigin = nil } else { rightDragOrigin = nil }
            model.finishTrimEdit()
        })
    }
    private func axisLabel(_ seconds: Int) -> String { seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s" }
}

private struct WaveformShape: Shape {
    let samples: [Float]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let middle = rect.midY
        for (index, sample) in samples.enumerated() {
            let x = rect.minX + CGFloat(index) / CGFloat(samples.count - 1) * rect.width
            let height = max(1, CGFloat(sample) * rect.height * 0.45)
            path.move(to: CGPoint(x: x, y: middle - height))
            path.addLine(to: CGPoint(x: x, y: middle + height))
        }
        return path
    }
}

struct PanelHeader: View { let title: String, icon: String; var body: some View { HStack { Label(title, systemImage: icon).font(.headline.weight(.semibold)); Spacer() }.padding(.horizontal, 12).frame(height: 42).background(Color(red: 0.105, green: 0.115, blue: 0.125)) } }
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
private struct FlowLayout: Layout { var spacing: CGFloat; func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { let width=proposal.width ?? 300;var x:CGFloat=0,y:CGFloat=0,row:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>width{x=0;y+=row+spacing;row=0};x+=s.width+spacing;row=max(row,s.height)};return .init(width:width,height:y+row) };func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout()){var x=bounds.minX,y=bounds.minY,row:CGFloat=0;for v in subviews{let s=v.sizeThatFits(.unspecified);if x+s.width>bounds.maxX{x=bounds.minX;y+=row+spacing;row=0};v.place(at:.init(x:x,y:y),proposal:.init(s));x+=s.width+spacing;row=max(row,s.height)}} }
private extension View { func cardStyle() -> some View { padding(11).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5))) } }
private func timecode(_ seconds: Double) -> String { guard seconds.isFinite else { return "00:00" }; return String(format: "%02d:%02d", Int(seconds)/60, Int(seconds)%60) }
private func preciseTimecode(_ seconds: Double) -> String { guard seconds.isFinite else { return "00:00.0" }; return String(format: "%02d:%04.1f", Int(seconds)/60, seconds.truncatingRemainder(dividingBy: 60)) }
