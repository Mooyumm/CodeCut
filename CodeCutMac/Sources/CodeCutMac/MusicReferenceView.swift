import SwiftUI
import AppKit

struct MusicReferenceWorkspace: View {
    @Environment(EditorModel.self) private var editor
    @Bindable var library: MusicReferenceLibrary
    @State private var showSettings = false
    @State private var showFolder = false
    @State private var folderName = ""
    @State private var renaming = false
    @State private var clipName = ""
    @State private var deleting = false
    @State private var deletingMusic: MusicReferenceTrack?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @FocusState private var annotationFocused: Bool
    @State private var showAIResult = false
    @State private var showAudioResult = false
    @State private var expandedFolders: Set<String> = []
    @State private var dropFolder: String?
    @State private var folderRowSelected = false
    @State private var folderRects: [String: CGRect] = [:]
    @AppStorage("musicReferenceWaveformHeight") private var waveformHeight = 130.0
    @State private var waveformResizeStart: Double?
    @State private var musicFolderScope = false
    @State private var showSeparationQueue = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("音乐参考库", systemImage: "music.note.list").font(.headline)
                Spacer()
                Text(library.saveStatus).font(.caption).foregroundStyle(.secondary)
                if library.qwenAudioBusy { Text("Qwen 分析中 · 去人声已暂停").font(.caption).foregroundStyle(.orange) }
                Button("去人声队列（\(library.separationQueue.filter { ["等待中", "处理中"].contains($0.status) }.count)）") { showSeparationQueue = true }
                Button("导入音乐", systemImage: "plus") { library.promptImport() }
                    .disabled(library.isImporting || library.readOnly)
                Button("设置", systemImage: "gearshape") { showSettings = true }
            }.padding(14)
            Divider()
            if library.document.tracks.isEmpty {
                ContentUnavailableView {
                    Label("建立你的配乐参考库", systemImage: "waveform")
                } description: {
                    Text("拖入 NCM、MP3 或其他音乐文件。\n空格播放 · I 设入点 · O 设出点 · 确认保存片段")
                } actions: {
                    Button("导入音乐") { library.promptImport() }.disabled(library.isImporting || library.readOnly)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(library.isSavingClip)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 200, idealWidth: 245, maxWidth: 320, maxHeight: .infinity)
                    GeometryReader { area in
                    VStack(spacing: 0) {
                        if let track = library.track { player(track, maximumWaveformHeight: max(100, area.size.height - 300)) }
                        else { Text("从左侧选择一首音乐").padding(25) }
                        Divider()
                        annotation.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if library.isSeparating {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("去人声 · " + library.separationTrackName).lineLimit(1)
                        Text(library.separationStage).foregroundStyle(.secondary)
                        Spacer()
                        TimelineView(.periodic(from: library.separationStartedAt, by: 1)) { timeline in
                            Text("已用时 " + musicTime(max(0, timeline.date.timeIntervalSince(library.separationStartedAt))))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let percent = library.separationPercent {
                            Text("\(Int(percent))%").monospacedDigit().frame(width: 45, alignment: .trailing)
                        } else { Text("准备中").foregroundStyle(.secondary) }
                    }.font(.caption)
                    if let percent = library.separationPercent {
                        ProgressView(value: percent, total: 100).progressViewStyle(.linear)
                            .accessibilityLabel("模型分离进度").accessibilityValue("\(Int(percent))%")
                    } else { ProgressView().progressViewStyle(.linear) }
                }.padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            HStack {
                if library.isImporting || library.isSavingClip || library.isRelocating || library.isSeparating || library.generatingID != nil || library.readingAudioID != nil { ProgressView().controlSize(.small) }
                Text(library.generatingID != nil ? library.generationProgress : library.notice).font(.caption).lineLimit(2)
                Spacer()
                if library.generatingID != nil { Button("取消 AI 生成") { library.cancelGeneration() } }
                if library.readingAudioID != nil { Button("取消读取") { library.cancelAudioReading() } }
                if library.isSeparating { Button("取消去人声") { library.cancelSeparation() } }
            }.padding(.horizontal, 14).frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.075, green: 0.082, blue: 0.09))
        .disabled(library.isRelocating)
        .onAppear {
            if library.track == nil, let first = library.document.tracks.first { library.selectTrack(first.id) }
            installKeys()
        }
        .onDisappear {
            library.pause()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
        }
        .sheet(isPresented: $showSettings) { storageSettings }
        .sheet(isPresented: $showSeparationQueue) { separationQueuePanel }
        .alert("新建文件夹", isPresented: $showFolder) {
            TextField("名称，可用 / 建立子文件夹", text: $folderName)
            Button("创建") {
                library.addFolder(folderName, music: musicFolderScope)
                let parts = library.selectedFolder.split(separator: "/")
                for i in 1...max(1, parts.count) where !parts.isEmpty { expandedFolders.insert(folderKey(parts.prefix(i).joined(separator: "/"), music: musicFolderScope)) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("例如：数码评测/思考。片段可通过右键菜单移入文件夹。") }
        .alert("重命名片段", isPresented: $renaming) {
            TextField("名称", text: $clipName)
            Button("保存") { if !clipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { library.editClip { $0.title = clipName } } }
            Button("取消", role: .cancel) {}
        }
        .alert("音乐参考库", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .confirmationDialog("删除片段记录？已保存的本地音频保留。", isPresented: $deleting) {
            Button("删除记录", role: .destructive) { library.removeSelectedClip() }
        }
        .alert("删除音乐？", isPresented: Binding(get: { deletingMusic != nil }, set: { if !$0 { deletingMusic = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let track = deletingMusic { library.deleteMusic(track.id) }
                deletingMusic = nil
            }
            Button("取消", role: .cancel) { deletingMusic = nil }
        } message: {
            if let track = deletingMusic {
                Text("将从当前参考库移除“\(track.name)”及其 \(track.clips.count) 个片段和批注，并把对应本地文件移到废纸篓。\n\n位置：\(library.root.path)\n\n最初导入的源文件和其他音乐版本不会删除。删除去人声版本后，可在原曲上重新去人声。")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索音乐、片段、批注", text: $library.query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([true, false], id: \.self) { music in
                    HStack {
                        Text(music ? "音乐库" : "片段库").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { musicFolderScope = music; folderName = ""; showFolder = true } label: { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(.plain).help(music ? "音乐库新建文件夹" : "片段库新建文件夹").disabled(library.readOnly)
                    }.padding(.vertical, 12)
                    folderTree("", music: music)
                    }
                }.font(.system(size: 12))
            }
            Text("本地独立参考库").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).frame(maxHeight: .infinity)
            .coordinateSpace(name: "musicReferenceTree")
            .onPreferenceChange(MusicFolderBounds.self) { folderRects = $0 }
    }

    private func acceptDrop(_ items: [String], to folder: String) -> Bool {
        guard items.count == 1, let item = items.first else { return false }
        let music = folder.hasPrefix("music|")
        let path = String(folder.dropFirst(music ? 6 : 5))
        guard music ? (item.contains("|track|") || item.contains("|musicfolder|")) : (item.contains("|clip|") || item.contains("|folder|")) else { return false }
        let moved = library.moveReference(item.replacingOccurrences(of: "|musicfolder|", with: "|folder|"), to: path, music: music)
        if moved { expandedFolders.insert(folder) }
        dropFolder = nil
        return moved
    }

    private func referenceDrag(_ payload: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("musicReferenceTree"))
            .onChanged { value in
                dropFolder = folderRects.first { $0.value.contains(value.location) }?.key
            }
            .onEnded { value in
                if let target = folderRects.first(where: { $0.value.contains(value.location) })?.key {
                    _ = acceptDrop([payload], to: target)
                }
                dropFolder = nil
            }
    }

    private func folderKey(_ path: String, music: Bool) -> String { (music ? "music|" : "clip|") + path }

    private func folderRow(_ folder: String, music: Bool) -> some View {
        let key = folderKey(folder, music: music)
        return HStack(spacing: 5) {
            if !folder.isEmpty {
                Button {
                    if expandedFolders.contains(key) { expandedFolders.remove(key) }
                    else { expandedFolders.insert(key) }
                    musicFolderScope = music
                    library.selectedFolder = folder; folderRowSelected = true
                    NSApp.keyWindow?.makeFirstResponder(nil)
                } label: {
                    Image(systemName: expandedFolders.contains(key) ? "chevron.down" : "chevron.right")
                        .frame(width: 18, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("展开或收起 " + folder)
            }
            Button {
                musicFolderScope = music
                library.selectedFolder = folder; folderRowSelected = true
                NSApp.keyWindow?.makeFirstResponder(nil)
            } label: {
                HStack {
                    Label(folder.isEmpty ? "根目录（拖到这里移出文件夹）" : (folder as NSString).lastPathComponent,
                          systemImage: folder.isEmpty ? "tray" : "folder")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 4).frame(maxWidth: .infinity)
        .background(dropFolder == key ? Color.teal.opacity(0.35) :
                        (folderRowSelected && musicFolderScope == music && library.selectedFolder == folder ? Color.teal.opacity(0.18) : .clear), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            musicFolderScope = music
            library.selectedFolder = folder; folderRowSelected = true
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MusicFolderBounds.self, value: [key: geometry.frame(in: .named("musicReferenceTree"))])
        })
        .highPriorityGesture(referenceDrag("codecut-reference|\(music ? "musicfolder" : "folder")|\(folder)"))
    }

    private func musicRow(_ track: MusicReferenceTrack) -> some View {
        Button {
            folderRowSelected = false
            library.selectTrack(track.id); library.selectedFolder = ""
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            Label(track.name, systemImage: "music.note")
                .lineLimit(1).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(.horizontal, 6)
                .background(!folderRowSelected && library.selectedClipID == nil && library.selectedTrackID == track.id ? Color.teal.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(track.name)
            .highPriorityGesture(referenceDrag("codecut-reference|track|\(track.id)"))
            .contextMenu {
                Button("加入去人声队列") { library.enqueueSeparation(track.id) }
                    .disabled(track.sourceTrackID != nil || library.readOnly)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(track)]) }
                Button("删除音乐…", role: .destructive) { deletingMusic = track }.disabled(!library.canDeleteMusic)
            }
    }

    private func folderTree(_ path: String, music: Bool) -> AnyView {
        let children = library.folders(music: music).filter {
            ($0 as NSString).deletingLastPathComponent == path
        }
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            if path.isEmpty {
                folderRow("", music: music)
            }
            ForEach(children, id: \.self) { folder in
                folderRow(folder, music: music)
                if expandedFolders.contains(folderKey(folder, music: music)) { folderTree(folder, music: music).padding(.leading, 16) }
            }
            if music {
                ForEach(library.visibleTracks.filter { ($0.folder ?? "") == path }) { track in musicRow(track) }
            }
            ForEach(music ? [] : library.visibleTracks) { track in
                ForEach(track.clips.filter { ($0.folder ?? "") == path }) { clip in
                    Button {
                        folderRowSelected = false
                        if library.selectedTrackID != track.id { library.selectTrack(track.id) }
                        library.selectClip(clip)
                        library.selectedFolder = clip.folder ?? ""
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform")
                            Text(clip.title).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(String(format: "%.1fs", clip.duration)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 27)
                            .background(!folderRowSelected && library.selectedClipID == clip.id ? Color.teal.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .highPriorityGesture(referenceDrag("codecut-reference|clip|\(clip.id)"))
                    .help("\(track.name) · \(musicTime(clip.start)) – \(musicTime(clip.end))\n\(clip.note)")
                    .contextMenu {
                        Button("重命名") { select(track, clip); clipName = clip.title; renaming = true }
                        Menu("移到文件夹") {
                            Button("未归档") { select(track, clip); library.editClip { $0.folder = nil } }
                            ForEach(library.document.folders ?? [], id: \.self) { folder in
                                Button(folder) { select(track, clip); library.editClip { $0.folder = folder } }
                            }
                        }
                        Button("删除记录", role: .destructive) { select(track, clip); deleting = true }
                    }
                }
            }
        })
    }

    private func select(_ track: MusicReferenceTrack, _ clip: MusicReferenceClip) {
        if library.selectedTrackID != track.id { library.selectTrack(track.id) }
        library.selectClip(clip)
    }

    private func player(_ track: MusicReferenceTrack, maximumWaveformHeight: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(track.name).font(.headline).lineLimit(1)
                Spacer()
                Button("加入去人声队列", systemImage: "waveform.badge.minus") {
                    library.enqueueSeparation(track.id)
                    showSeparationQueue = true
                }
                .help("处理整首音乐，保存独立伴奏版本；原曲和片段保留。AI 分离可能有少量残留或音质变化。")
                .disabled(library.isImporting || library.isSavingClip || library.readOnly || track.sourceTrackID != nil)
                Text("\(musicTime(library.playhead)) / \(musicTime(track.duration))").monospacedDigit()
            }
            MusicReferenceWaveform(library: library, duration: track.duration)
                .frame(height: min(maximumWaveformHeight, max(100, waveformHeight)))
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            ZStack {
                Color.clear
                Capsule().fill(.secondary.opacity(0.5)).frame(width: 48, height: 4)
            }
            .frame(height: 12).frame(maxWidth: .infinity).contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if waveformResizeStart == nil {
                        waveformResizeStart = min(maximumWaveformHeight, max(100, waveformHeight))
                    }
                    waveformHeight = min(maximumWaveformHeight, max(100, (waveformResizeStart ?? 130) + value.translation.height))
                }
                .onEnded { _ in waveformResizeStart = nil })
            .help("上下拖动调整波形高度")
            .accessibilityLabel("调整波形高度")
            .accessibilityValue("\(Int(min(maximumWaveformHeight, max(100, waveformHeight)))) 点")
            .accessibilityAdjustableAction { direction in
                waveformHeight = min(maximumWaveformHeight, max(100, min(maximumWaveformHeight, waveformHeight) + (direction == .increment ? 30 : -30)))
            }
            Slider(value: Binding(get: { library.playhead }, set: { library.seek($0) }), in: 0...max(0.1, track.duration))
            HStack {
                Button(library.isPlaying ? "暂停 · 空格" : "播放 · 空格") { togglePlay() }
                Button("入点 · I") { library.markIn() }
                Text(musicTime(library.selectionStart)).monospacedDigit()
                Button("出点 · O") { library.markOut() }
                Text(musicTime(library.selectionEnd)).monospacedDigit()
                Spacer()
                Button("试听选区") { library.play(selection: true) }
                Toggle("循环", isOn: $library.loopSelection).toggleStyle(.checkbox)
            }.font(.caption)
            HStack {
                Text("单击定位 · I / O 标记 · Option + 滚轮缩放 · 滚轮左右移动").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(library.isSavingClip ? "保存中…" : "确认片段") {
                    if musicFolderScope { library.selectedFolder = "" }
                    Task { await library.confirmClip() }
                }.buttonStyle(.borderedProminent)
                    .disabled(!library.canSaveClip || library.isSavingClip || library.readOnly || library.selectedClipID != nil)
            }
        }.padding(18)
    }

    private var annotation: some View {
        // Keep the entire inspector scrollable even in a short window. Editors
        // have bounded viewports instead of competing for infinite height.
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if let clip = library.clip {
                HStack {
                    Text(clip.title).font(.headline)
                    Text("\(musicTime(clip.start)) – \(musicTime(clip.end))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("导出片段") { library.export(all: false) }.disabled(library.isExporting)
                }
                TextEditor(text: Binding(get: { library.clip?.note ?? "" }, set: { text in library.editClip { $0.note = text } }))
                    .focused($annotationFocused)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(height: (showAIResult && clip.analysis != nil) || (showAudioResult && clip.audioFeatures != nil) ? 110 : 240)
                    .padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("片段批注").disabled(library.readOnly)
                HStack {
                    Button(library.readingAudioID == clip.id ? "读取中…" : "读取音乐", systemImage: "waveform") {
                        annotationFocused = false; showAudioResult = true; showAIResult = false
                        Task { await library.readAudio() }
                    }.disabled(library.qwenAudioBusy || library.readingAudioID != nil || library.generatingID != nil || library.readOnly || library.isRelocating)
                    Button(library.generatingID == clip.id ? "AI 正在整理…" : "AI 分类并生成提示词", systemImage: "sparkles") {
                        annotationFocused = false
                        showAIResult = true; showAudioResult = false
                        library.generate(all: false)
                    }.buttonStyle(.borderedProminent)
                        .disabled(library.qwenAudioBusy || library.readingAudioID != nil || library.generatingID != nil || library.readOnly || library.isRelocating)
                    Menu("更多") {
                        Button("为本曲有批注的片段批量生成") { showAIResult = true; library.generate(all: true) }
                            .disabled(library.generatingID != nil || library.readOnly)
                        Button("本地 AI 设置") { editor.showSettings = true }
                    }.fixedSize()
                    Text("音频特征 + 批注").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if let features = clip.audioFeatures {
                    DisclosureGroup("音频读取结果 · " + features.engine, isExpanded: $showAudioResult) {
                            VStack(alignment: .leading, spacing: 8) {
                                if clip.currentAudioFeatures == nil { Text("片段范围已改变，以下读取结果已过期，请重新读取。").foregroundStyle(.orange) }
                                Text(features.summary).frame(maxWidth: .infinity, alignment: .leading)
                                Text(features.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                            }.textSelection(.enabled).padding(.vertical, 6)
                    }
                }
                if let result = clip.analysis {
                    DisclosureGroup(isExpanded: $showAIResult) {
                            VStack(alignment: .leading, spacing: 10) {
                                if clip.isStale { Text("批注或范围已更新，请重新生成。以下是旧结果。").foregroundStyle(.orange) }
                                Text(result.reason).foregroundStyle(.secondary)
                                HStack {
                                    Text("音乐生成提示词").font(.headline)
                                    Spacer()
                                    Button("复制提示词与避免项", systemImage: "doc.on.doc") { library.copyPrompt() }
                                }
                                Text("可直接编辑，修改自动保存；重新生成会覆盖当前结果。")
                                    .font(.caption).foregroundStyle(.secondary)
                                resultEditor(\.prompt, label: "音乐生成提示词", height: 240)
                                Text("避免项").font(.headline)
                                resultEditor(\.avoid, label: "提示词避免项", height: 90)
                                Text("待确认：\(result.uncertainties)").font(.caption).foregroundStyle(.secondary)
                            }.font(.callout).textSelection(.enabled).padding(.vertical, 8)
                    } label: {
                        Text("AI 结果 · " + result.categories.joined(separator: " / ")).foregroundStyle(.teal)
                    }
                }
            } else {
                ContentUnavailableView("片段批注", systemImage: "square.and.pencil",
                                       description: Text("确认一个片段，或从左侧选择片段后开始记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(18)
        }.scrollIndicators(.visible)
    }

    private func resultEditor(_ field: WritableKeyPath<MusicReferenceAnalysis, String>, label: String, height: CGFloat) -> some View {
        TextEditor(text: Binding(
            get: { library.clip?.analysis?[keyPath: field] ?? "" },
            set: { value in library.editClip { $0.analysis?[keyPath: field] = value } }
        ))
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .frame(height: height)
        .padding(8)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(label)
        .disabled(library.readOnly || library.generatingID != nil)
    }

    private var separationQueuePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("去人声队列").font(.title2.bold())
            if library.qwenAudioBusy {
                Text("Qwen 正在读取音乐，去人声队列已暂停。分析结束自动恢复；被中断的一首从头重算。")
                    .foregroundStyle(.orange).font(.callout)
            }
            Text("逐首处理，避免同时占满内存。关闭此面板继续后台处理；退出程序不会保留待处理队列。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if library.separationQueue.isEmpty { Text("选择音乐，点击“加入去人声队列”。").foregroundStyle(.secondary) }
                    ForEach(library.separationQueue) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.name).lineLimit(1)
                                Spacer()
                                Text(job.status).foregroundStyle(.secondary)
                                if job.status == "等待中" {
                                    Button("移出队列") { library.removeWaitingSeparation(job.id) }
                                } else if job.id == library.activeSeparationJobID {
                                    Button("取消当前") { library.cancelSeparation() }
                                } else if ["失败", "已取消"].contains(job.status) {
                                    Button("重试") { library.enqueueSeparation(job.trackID) }
                                }
                            }
                            if job.id == library.activeSeparationJobID {
                                HStack {
                                    Text(library.separationStage)
                                    Spacer()
                                    if let percent = library.separationPercent { Text("\(Int(percent))%").monospacedDigit() }
                                }.font(.caption)
                                if let percent = library.separationPercent { ProgressView(value: percent, total: 100) }
                                else { ProgressView().progressViewStyle(.linear) }
                            }
                            if !job.detail.isEmpty { Text(job.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Button("清除已结束记录") { library.separationQueue.removeAll { !["等待中", "处理中"].contains($0.status) } }
                Spacer()
                Button("完成") { showSeparationQueue = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 620, height: 440)
    }

    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("音乐参考库设置").font(.title2.bold())
            Text("存储位置").font(.headline)
            Text(library.root.path).font(.callout).textSelection(.enabled)
            Text("与视频项目独立保存。Audio 保存导入音乐，Clips 保存已确认的片段音频和批注，library.json 保存文件夹与索引。")
                .foregroundStyle(.secondary)
            HStack {
                Button("在 Finder 中打开") { if library.save() { NSWorkspace.shared.open(library.root) } }
                Button("更改位置…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.message = "选择项目文件夹，将在其中新建 MusicReferences。现有参考库会完整复制过去，原位置保留备份。"
                    if panel.runModal() == .OK, let parent = panel.url {
                        Task { await library.relocate(to: parent.appending(path: "MusicReferences")) }
                    }
                }.disabled(library.isImporting || library.isSavingClip || library.isExporting || library.isSeparating || library.readOnly || library.readingAudioID != nil || library.generatingID != nil)
            }
            if library.isRelocating { ProgressView("正在复制参考库…") }
            Spacer()
            HStack { Spacer(); Button("完成") { showSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 590, height: 320).disabled(library.isRelocating)
    }

    private func togglePlay() {
        if library.isPlaying { library.pause() } else { library.play(selection: false) }
    }

    private func leaveTextEditing(_ window: NSWindow) {
        annotationFocused = false
        window.makeFirstResponder(nil)
    }

    /// Mouse events reach the native text view before SwiftUI gestures; do not
    /// attach a parent tap gesture that competes with waveform dragging.
    private static func isTextEditingTarget(_ view: NSView?) -> Bool {
        var current = view
        while let node = current {
            if let text = node as? NSTextView, text.isEditable { return true }
            if let field = node as? NSTextField, field.isEditable { return true }
            if let scroll = node as? NSScrollView,
               let text = scroll.documentView as? NSTextView, text.isEditable { return true }
            current = node.superview
        }
        return false
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard !showSettings, !showFolder, !renaming, !deleting, deletingMusic == nil, library.error == nil,
                  let window = event.window, window == NSApp.keyWindow,
                  window.attachedSheet == nil, let content = window.contentView else { return event }
            let location = content.convert(event.locationInWindow, from: nil)
            if !Self.isTextEditingTarget(content.hitTest(location)) { leaveTextEditing(window) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !showSettings, !showFolder, !renaming, !deleting, deletingMusic == nil, library.error == nil,
                  !library.isRelocating, !library.isSavingClip, library.track != nil,
                  NSApp.keyWindow?.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 53, let window = NSApp.keyWindow {
                leaveTextEditing(window)
                return nil
            }
            guard !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !(NSApp.keyWindow?.firstResponder is NSTextField) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": if !event.isARepeat { togglePlay() }; return nil
            case "i": library.markIn(); return nil
            case "o": library.markOut(); return nil
            default: return event
            }
        }
    }
}

private struct MusicFolderBounds: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct MusicTimelineViewport {
    var zoom = 1.0
    var start = 0.0
    func span(_ duration: Double) -> Double { max(0.001, duration) / zoom }
    mutating func scroll(delta: Double, anchor: Double, zooming: Bool, duration: Double) {
        guard duration > 0, delta.isFinite else { return }
        let oldSpan = span(duration)
        if zooming {
            let fraction = min(1, max(0, anchor))
            let time = start + fraction * oldSpan
            zoom = min(max(1, duration), max(1, zoom * exp(min(1, max(-1, delta * 0.012)))))
            start = time - fraction * span(duration)
        } else {
            start += delta * oldSpan / 700
        }
        start = min(max(0, duration - span(duration)), max(0, start))
    }
}

private struct MusicReferenceWaveform: View {
    @Bindable var library: MusicReferenceLibrary
    let duration: Double
    @State private var viewport = MusicTimelineViewport()
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("\(musicTime(viewport.start)) – \(musicTime(min(duration, viewport.start + viewport.span(duration)))) · \(viewport.zoom, specifier: "%.1f")×")
                    .monospacedDigit()
                Spacer()
                Button("显示全曲") { viewport = MusicTimelineViewport() }.buttonStyle(.plain)
            }.font(.caption2).foregroundStyle(.secondary)
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let span = viewport.span(duration)
            let startX = (library.selectionStart - viewport.start) / span * width
            let endX = (library.selectionEnd - viewport.start) / span * width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25))
                Canvas { context, size in
                    var path = Path()
                    let samples = library.waveform
                    for (i, sample) in samples.enumerated() {
                        let time = Double(i) / Double(max(1, samples.count - 1)) * duration
                        let x = (time - viewport.start) / span * size.width
                        guard x >= 0, x <= size.width else { continue }
                        let amplitude = max(1, Double(sample) * size.height * 0.43)
                        path.move(to: CGPoint(x: x, y: size.height / 2 - amplitude))
                        path.addLine(to: CGPoint(x: x, y: size.height / 2 + amplitude))
                    }
                    context.stroke(path, with: .color(.teal.opacity(0.7)), lineWidth: 1)
                }.allowsHitTesting(false)
                Rectangle().fill(.teal.opacity(0.17)).frame(width: max(1, endX - startX), height: height).offset(x: startX)
                    .allowsHitTesting(false)
                ForEach(library.track?.clips ?? []) { clip in
                    Rectangle().fill(.orange.opacity(0.8)).frame(width: max(2, clip.duration / span * width), height: 3)
                        .offset(x: (clip.start - viewport.start) / span * width, y: height - 3).allowsHitTesting(false)
                }
                Rectangle().fill(.white).frame(width: 1, height: height).offset(x: (library.playhead - viewport.start) / span * width).allowsHitTesting(false)
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let a = time(at: value.startLocation.x, width: width)
                    let b = time(at: value.location.x, width: width)
                    if abs(value.translation.width) > 3 { library.setRange(start: min(a, b), end: max(a, b)) }
                }.onEnded { value in
                    if abs(value.translation.width) <= 3 { library.seek(time(at: value.location.x, width: width)) }
                })
                if startX >= 0 && startX <= width { handle(x: startX, height: height, width: width, isStart: true) }
                if endX >= 0 && endX <= width { handle(x: endX, height: height, width: width, isStart: false) }
            }.clipped().coordinateSpace(name: "musicWave")
                .background(MusicTimelineScrollCapture { delta, anchor, zooming in
                    viewport.scroll(delta: delta, anchor: anchor, zooming: zooming, duration: duration)
                })
                .accessibilityLabel("参考音乐波形，Option 加滚轮缩放，普通滚轮左右移动")
        }
        }.onChange(of: library.selectedTrackID) { _, _ in viewport = MusicTimelineViewport() }
    }
    private func time(at x: Double, width: Double) -> Double {
        max(0, min(duration, viewport.start + x / max(1, width) * viewport.span(duration)))
    }
    private func handle(x: Double, height: Double, width: Double, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.teal).frame(width: 10, height: height)
            .overlay(Text(isStart ? "入" : "出").font(.system(size: 8)).foregroundStyle(.black))
            .offset(x: max(0, min(width - 10, x - 5)))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("musicWave")).onChanged { value in
                let time = time(at: value.location.x, width: width)
                if isStart { library.setRange(start: min(time, library.selectionEnd - 0.1), end: library.selectionEnd) }
                else { library.setRange(start: library.selectionStart, end: time) }
            })
    }
}

/// Observe only wheel events inside the waveform; leave notes and other scroll
/// views untouched, and do not intercept mouse clicks or handle dragging.
private struct MusicTimelineScrollCapture: NSViewRepresentable {
    var onScroll: (Double, Double, Bool) -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView(onScroll: onScroll) }
    func updateNSView(_ view: CaptureView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }
    final class CaptureView: NSView {
        var onScroll: (Double, Double, Bool) -> Void
        private var monitor: Any?
        init(onScroll: @escaping (Double, Double, Bool) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), self.bounds.width > 0 else { return event }
                let zooming = event.modifierFlags.contains(.option)
                let raw = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                let delta = raw * (event.hasPreciseScrollingDeltas ? 1 : 10)
                self.onScroll(zooming ? delta : -delta, point.x / self.bounds.width, zooming)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private func musicTime(_ value: Double) -> String {
    guard value.isFinite else { return "00:00.0" }
    return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
}
