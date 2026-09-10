import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceBottomBar: View {
    @Binding var page: ContentView.WorkspacePage
    var body: some View {
        HStack {
            Spacer()
            Picker("工作区", selection: $page) {
                Text("口播").tag(ContentView.WorkspacePage.talking)
                Text("分镜").tag(ContentView.WorkspacePage.storyboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Spacer()
        }
        .frame(height: 46)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
        .overlay(alignment: .top) { Divider() }
    }
}

struct StoryboardWorkspace: View {
    @Binding var projectSidebarCollapsed: Bool
    var body: some View {
        HSplitView {
            if !projectSidebarCollapsed {
                ProjectSidebar(onCollapse: { projectSidebarCollapsed = true }).frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            }
            StoryboardTablePanel().frame(minWidth: 620, idealWidth: 760)
            VSplitView {
                ViewerPanel().frame(minHeight: 320)
                StoryboardTimelinePanel().frame(minHeight: 300, idealHeight: 340)
            }.frame(minWidth: 560)
        }
    }
}

private struct StoryboardTablePanel: View {
    @Environment(EditorModel.self) private var model
    @State private var confirmReplace = false
    @State private var generatedPrompt = ""
    @State private var showingPrompt = false
    @State private var generatingPrompt = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("分镜制作表", systemImage: "rectangle.3.group")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button("生成全片") {
                    if model.storyboards.isEmpty { Task { await model.generateStoryboards() } }
                    else { confirmReplace = true }
                }.buttonStyle(.borderedProminent).disabled(model.words.isEmpty || model.isWorking)
                Button("重新生成选区") { Task { await model.generateStoryboards(selectedOnly: true) } }
                    .disabled(model.storyboardSelectedWordIDs.isEmpty || model.isWorking)
                Button("生成详细提示词", systemImage: "wand.and.stars") { Task { await generatePrompt() } }
                    .disabled(model.selectedStoryboardID == nil || generatingPrompt || model.isWorking)
                Button("导出 CSV") { exportCSV() }.disabled(model.storyboards.isEmpty || model.edl == nil)
            }.padding(.horizontal, 12).frame(height: 44).background(Color(red: 0.105, green: 0.115, blue: 0.125))
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0) {
                    storyboardHeader
                    ForEach(model.storyboards) { item in StoryboardTableRow(item: item) }
                }.padding(10)
            }
            if model.storyboards.isEmpty {
                ContentUnavailableView {
                    Label("还没有分镜参考", systemImage: "film.stack")
                } description: {
                    Text("AI 会根据剪辑后字幕设计实拍空镜和 MG 动画，并磁吸到对应内容。")
                } actions: {
                    Button("生成全片分镜") { Task { await model.generateStoryboards() } }.buttonStyle(.borderedProminent).disabled(model.words.isEmpty || model.isWorking)
                }
            }
        }
        .confirmationDialog("重新生成全片分镜？", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("替换现有分镜", role: .destructive) { Task { await model.generateStoryboards() } }
            Button("取消", role: .cancel) {}
        } message: { Text("现有分镜表会被新结果替换，可使用撤销恢复。") }
        .sheet(isPresented: $showingPrompt) { promptSheet }
    }

    private var storyboardHeader: some View {
        HStack(spacing: 6) {
            header("时间码", 112); header("对应字幕", 210); header("类型", 100); header("画面描述", 250)
            header("景别/构图", 180); header("镜头运动", 150); header("素材/动画元素", 190); header("备注", 170); header("操作", 100)
        }.padding(.vertical, 6).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
    private func header(_ text: String, _ width: Double) -> some View { Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: width, alignment: .leading) }
    private func exportCSV() {
        guard let edl = model.edl else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "导出分镜表"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let url = try TimelineExporter.exportStoryboardCSV(model.storyboards, edl: edl, projectName: model.projectName, folder: folder)
            model.taskState = .done("已导出分镜参考表：\(url.lastPathComponent)")
        } catch { model.taskState = .failed("分镜表导出失败：\(error.localizedDescription)") }
    }

    @MainActor private func generatePrompt() async {
        guard let id = model.selectedStoryboardID, let item = model.storyboards.first(where: { $0.id == id }) else { return }
        generatingPrompt = true
        model.taskState = .working("DeepSeek 正在生成详细 MG 动画提示词…")
        do {
            generatedPrompt = try await MiMoClient(settings: .deepSeek).generateDetailedStoryboardPrompt(item: item, subtitle: model.storyboardSubtitle(item), duration: model.storyboardOutputRange(item).duration)
            showingPrompt = true
            model.taskState = .done("详细 MG 动画提示词已生成")
        } catch { model.taskState = .failed("提示词生成失败：\(error.localizedDescription)") }
        generatingPrompt = false
    }

    private var promptSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Label("DeepSeek 详细 MG 动画提示词", systemImage: "wand.and.stars").font(.headline)
                Spacer()
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(generatedPrompt, forType: .string) }
                Button("导出 TXT") { exportPrompt() }.buttonStyle(.borderedProminent)
                Button("完成") { showingPrompt = false }
            }
            TextEditor(text: $generatedPrompt).font(.system(size: 14, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }.padding(16).frame(minWidth: 820, minHeight: 620)
    }

    private func exportPrompt() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(model.projectName)-MG动画提示词.txt"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try generatedPrompt.write(to: url, atomically: true, encoding: .utf8); model.taskState = .done("已导出提示词：\(url.lastPathComponent)") }
        catch { model.taskState = .failed("提示词导出失败：\(error.localizedDescription)") }
    }
}

private struct StoryboardTableRow: View {
    @Environment(EditorModel.self) private var model
    @State private var draft: StoryboardItem
    init(item: StoryboardItem) { _draft = State(initialValue: item) }
    var body: some View {
        HStack(spacing: 6) {
            Text(outputTime).font(.caption.monospacedDigit()).frame(width: 112, alignment: .leading)
            Text(model.storyboardSubtitle(draft).isEmpty ? "（时间锚点）" : model.storyboardSubtitle(draft)).lineLimit(2).frame(width: 210, alignment: .leading)
            Picker("", selection: $draft.kind) { ForEach(StoryboardKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
            field($draft.description, 250); field($draft.composition, 180); field($draft.cameraMovement, 150); field($draft.elements, 190); field($draft.notes, 170)
            HStack(spacing: 4) {
                Button { commit(); Task { await model.regenerateStoryboard(draft.id) } } label: { Image(systemName: "arrow.clockwise") }.help("重新生成这一条")
                Button(role: .destructive) { model.deleteStoryboard(draft.id) } label: { Image(systemName: "trash") }
            }.frame(width: 100)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(model.selectedStoryboardID == draft.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { commit(); if let item = model.storyboards.first(where: { $0.id == draft.id }) { model.selectStoryboard(item) } }
        .onSubmit(commit)
        .onDisappear(perform: commit)
        .onChange(of: model.storyboards.first(where: { $0.id == draft.id })) { _, item in if let item, item != draft { draft = item } }
    }
    private func field(_ text: Binding<String>, _ width: Double) -> some View { TextField("", text: text, axis: .vertical).lineLimit(1...3).textFieldStyle(.plain).padding(5).frame(width: width).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4)) }
    private var outputTime: String {
        let range = model.storyboardOutputRange(draft)
        return "\(clock(range.start))–\(clock(range.end))"
    }
    private func clock(_ value: Double) -> String { String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }
    private func commit() { model.replaceStoryboard(draft) }
}

private struct StoryboardTimelinePanel: View {
    @Environment(EditorModel.self) private var model
    @State private var pointsPerSecond = 24.0
    private let labelWidth = 92.0
    private var duration: Double { model.outputDuration }
    private var canvasWidth: Double { max(760, labelWidth + duration * pointsPerSecond + 40) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("分镜时间线", systemImage: "timeline.selection").font(.subheadline.weight(.semibold))
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                Divider().frame(height: 18)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $pointsPerSecond, in: 8...100).frame(width: 120)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Spacer()
                if !model.storyboardSelectedWordIDs.isEmpty { Text("已选字幕范围").font(.caption).foregroundStyle(.secondary); Button("清除选区") { model.storyboardSelectedWordIDs = []; model.storyboardSelectionAnchorID = nil } }
            }.padding(.horizontal, 12).frame(height: 38).background(.thinMaterial)
            ScrollView(.horizontal) { canvas.padding(.vertical, 8) }.background(Color(red: 0.075, green: 0.085, blue: 0.10))
        }
    }
    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, through: max(5, Int(duration.rounded(.up))), by: 5)), id: \.self) { second in
                let x = labelWidth + Double(second) * pointsPerSecond
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 258).offset(x: x, y: 18)
                Text("\(second)s").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.58)).offset(x: x + 3, y: 0)
            }
            track("实拍", "camera", 32); track("MG", "scribble.variable", 74); track("CC", "captions.bubble", 116); track("V1", "film", 158); track("A1", "waveform", 200)
            ForEach(model.storyboards.filter { $0.kind == .liveAction }) { storyboardClip($0, y: 32, color: .blue) }
            ForEach(model.storyboards.filter { $0.kind == .motionGraphics }) { storyboardClip($0, y: 74, color: .purple) }
            ForEach(model.visibleSubtitleCues) { cue in
                let start = TimelineEngine.outputTime(for: cue.start, deleted: model.deletedRanges)
                let end = TimelineEngine.outputTime(for: cue.end, deleted: model.deletedRanges)
                let selected = !Set(cue.wordIDs).isDisjoint(with: model.storyboardSelectedWordIDs)
                let fill = selected ? Color.orange.opacity(0.85) : Color(red: 0.34, green: 0.43, blue: 0.52)
                let width = max(3, (end - start) * pointsPerSecond - 2)
                RoundedRectangle(cornerRadius: 4).fill(fill)
                    .frame(width: width, height: 34)
                    .overlay(Text(cue.text).font(.caption2).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 5), alignment: .leading)
                    .offset(x: labelWidth + start * pointsPerSecond + 1, y: 116)
                    .onTapGesture { model.selectStoryboardCue(cue, extending: NSEvent.modifierFlags.contains(.shift)) }
            }
            ForEach(Array(model.keptRanges.enumerated()), id: \.offset) { _, range in
                let start = TimelineEngine.outputTime(for: range.start, deleted: model.deletedRanges)
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.18, green: 0.39, blue: 0.56)).frame(width: max(3, range.duration * pointsPerSecond - 2), height: 34).offset(x: labelWidth + start * pointsPerSecond + 1, y: 158)
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.16, green: 0.45, blue: 0.36)).frame(width: max(3, range.duration * pointsPerSecond - 2), height: 34).offset(x: labelWidth + start * pointsPerSecond + 1, y: 200)
            }
            let playhead = TimelineEngine.outputTime(for: model.currentTime, deleted: model.deletedRanges)
            Rectangle().fill(Color.red).frame(width: 2, height: 226).offset(x: labelWidth + playhead * pointsPerSecond, y: 24)
        }
        .frame(width: canvasWidth, height: 266, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard value.location.x >= labelWidth else { return }
            let output = min(duration, max(0, (value.location.x - labelWidth) / pointsPerSecond))
            model.seek(to: TimelineEngine.sourceTime(for: output, kept: model.keptRanges))
        })
    }
    private func track(_ name: String, _ icon: String, _ y: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.04)).frame(width: canvasWidth - labelWidth, height: 34).offset(x: labelWidth, y: y)
            Label(name, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.68)).offset(x: 8, y: y + 9)
        }
    }
    private func storyboardClip(_ item: StoryboardItem, y: Double, color: Color) -> some View {
        let range = model.storyboardOutputRange(item)
        return RoundedRectangle(cornerRadius: 5).fill(color.opacity(model.selectedStoryboardID == item.id ? 0.95 : 0.68))
            .frame(width: max(4, range.duration * pointsPerSecond - 2), height: 34)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.selectedStoryboardID == item.id ? Color.orange : Color.black.opacity(0.7), lineWidth: model.selectedStoryboardID == item.id ? 2 : 1))
            .overlay(Text(item.description).font(.caption2.weight(.medium)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6), alignment: .leading)
            .offset(x: labelWidth + range.start * pointsPerSecond + 1, y: y)
            .onTapGesture { model.selectStoryboard(item) }
    }
}
