import AVKit
import AppKit
import SwiftUI

/// B-roll 工作区：左边是导入进来的全部素材，右边是认出来的产品分组；
/// 再往右是产品档案、预览和识别结果。
///
/// 左边那一栏刻意不做分类：它是“素材都在不在”的底账。
/// 分类是识别结果，所以放在右边，而且一条素材可以同时出现在好几个产品分组里。
struct BrollWorkspace: View {
    @Binding var projectSidebarCollapsed: Bool
    @Environment(EditorModel.self) private var model
    @State private var dropTargeted = false
    /// 产品档案展开/折叠：折叠时面板只能占标题那一条，预览要立刻贴上去，不能留空隙。
    @State private var profileExpanded = true

    var body: some View {
        HSplitView {
            if !projectSidebarCollapsed {
                ProjectSidebar(onCollapse: { projectSidebarCollapsed = true }).frame(minWidth: 150, idealWidth: 180, maxWidth: 220)
            }
            BrollPoolPanel().frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            BrollGroupPanel().frame(minWidth: 340, idealWidth: 520, maxHeight: .infinity)
            // 产品档案不放在 VSplitView 里：折叠之后 VSplitView 会留着原来的高度，
            // 预览上面就空出一条。竖排 VStack 里它的高度就是"标题 + 内容"，
            // 折叠时自然只剩标题那一条，预览立刻贴上去。
            VStack(spacing: 0) {
                ProductProfilePanel(expanded: $profileExpanded)
                    .frame(maxHeight: profileExpanded ? 330 : 44)
                VSplitView {
                    BrollPreviewPanel().frame(minHeight: 220)
                    BrollAnalysisPanel().frame(minHeight: 220, idealHeight: 300)
                }
            }.frame(minWidth: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 拖到这一页就该进 B-roll 库。以前这里没有接收区，文件会落到顶层那个
        // “导入主视频”上 —— B-roll 片段被当成了口播的主视频（真实踩过）。
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addBrollAssetsFromDrop(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .bottom) {
            if dropTargeted {
                Text("松手就加进「全部素材」，并自动开始识别")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 62)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 全部素材（左栏）

/// 拖拽载荷：把"哪几条素材"编成一段明文拖过去。
///
/// 用明文而不是自定义 UTType：为一个内部拖拽去 Info.plist 里声明类型不值得，
/// 而且带上固定前缀就不会把别处拖来的文字当成素材。
enum BrollDragPayload {
    static let prefix = "codecut-broll-assets:"

    static func encode(_ ids: [UUID]) -> String {
        prefix + ids.map(\.uuidString).joined(separator: ",")
    }

    static func decode(_ text: String) -> [UUID] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count)
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }
}

/// 导入进来的素材都在这儿：只回答“有没有导进来、认过没有”，不分类。
private struct BrollPoolPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var confirmRemove = false
    @State private var pendingRemoval: UUID?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            progressBars
            Divider()
            // 空状态只有一块不弹性的内容，必须显式撑满，否则整个 HSplitView 会缩成一小条。
            if model.brollAssets.isEmpty { emptyState.frame(maxWidth: .infinity, maxHeight: .infinity) } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("把这条素材移出 B-roll 库？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移出媒体库", role: .destructive) {
                if let pendingRemoval { model.removeBrollAssets([pendingRemoval]) }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只从 CodeCut 的媒体库里移除，硬盘上的原始文件不会被动。")
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Label("全部素材", systemImage: "rectangle.stack").font(.headline.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text("\(model.brollAssets.count)").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.isAnalyzingBrollProduct || model.isAnalyzingBroll {
                Button("停止", role: .destructive) {
                    model.cancelBrollProductAnalysis()
                    model.cancelBrollAnalysis()
                }
            } else {
                Button {
                    Task { await model.analyzeBrollProducts(ids: model.brollAssets.map(\.id)) }
                } label: {
                    Image(systemName: "scope")
                }
                .disabled(model.brollAssets.isEmpty || !model.localModelState.isReady)
                .help(model.localModelState.isReady
                      ? (model.productProfile.isConfigured
                         ? "认物品：本机逐条看素材（每条 5 帧），列出画面里有什么、哪一件是清单里的产品。会重认全部素材；只补没认过的用下面那行。"
                         : "还没有读 brief：这次只会列出画面里的物品，认不出是哪一款产品。")
                      : "先在上面的产品档案里点“准备本地模型”。")
                Button {
                    Task { await model.analyzeBroll(ids: model.brollAssets.filter { !$0.isAnalyzed }.map(\.id)) }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(model.brollAssets.isEmpty || model.brollAssets.allSatisfy(\.isAnalyzed))
                .help("算运动曲线：本机逐条分析它的运动（轨迹、速度、静止/匀速/加速区间），Apple Vision 光流，不联网")
            }
            Button { model.promptImportBroll() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderedProminent)
                .help("添加 B-roll 素材（可选文件，也可以直接选整个文件夹）")
        }
        .padding(.horizontal, 10).frame(height: 42).background(Color(red: 0.105, green: 0.115, blue: 0.125))
    }

    private var searchBar: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            if model.projectURL == nil {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("还没有项目：素材跟着项目保存。")
                    Spacer(minLength: 4)
                    Button("新建") { model.promptNewProject() }
                }.font(.caption2).padding(.horizontal, 10).frame(height: 28).background(Color.orange.opacity(0.12))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜文件、产品、颜色、方向", text: $model.brollQuery).textFieldStyle(.plain).font(.caption)
                if !model.brollQuery.isEmpty { Button { model.brollQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 10).padding(.top, 7)
            HStack(spacing: 6) {
                Toggle(isOn: $model.brollOnlyPendingUnknown) {
                    HStack(spacing: 3) {
                        Image(systemName: "questionmark.circle")
                        Text("只看待确认 \(model.pendingUnknownBrollCount)")
                    }
                }
                .toggleStyle(.checkbox).font(.caption2)
                .disabled(model.pendingUnknownBrollCount == 0 && !model.brollOnlyPendingUnknown)
                .help("只看还有“不认识的东西”没确认的素材：确认过是竞品或不是产品之后，它们就不再出现在这里。")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 5)
            // 已经加进来、但还没认过物品的素材：给一个明确入口，别让它一直躺在那儿没结果。
            if unrecognizedCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("\(unrecognizedCount) 条还没认过物品")
                    Button(model.isAnalyzingBrollProduct ? "正在认…" : "开始批量认") {
                        Task { await model.analyzeBrollProducts(ids: model.brollAssets.filter { $0.inventory == nil }.map(\.id)) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.localModelState.isReady || model.isAnalyzingBrollProduct)
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 4)
                // 帧数就是调用次数：这条直接把"要花多久"摊开给用户看。
                HStack(spacing: 5) {
                    Text("抽帧").foregroundStyle(.secondary)
                    Picker("抽帧", selection: Binding(get: { model.brollScanMode }, set: { model.brollScanMode = $0; UserDefaults.standard.set($0.rawValue, forKey: "brollScanMode") })) {
                        ForEach(BrollScanMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 108)
                    .help(model.brollScanMode.detail)
                    Spacer(minLength: 0)
                    Text(estimateLine)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 4)
            }
            Text("算过运动曲线 \(model.analyzedBrollCount) 条 · 认过物品 \(model.scannedBrollCount) 条")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 7)
                .help("右侧状态点：灰=还没认过物品 · 橙=有待确认的东西 · 绿=已归类 · 蓝=认过但还没归类")
        }
    }

    /// 库里有、却一次都没认过物品的素材条数（0 就整行不显示）。
    private var unrecognizedCount: Int {
        model.brollAssets.filter { $0.inventory == nil }.count
    }

    /// “这一批大概要多久”：用实测的每次调用耗时估，没有实测值就按 15 秒估。
    private var estimateLine: String {
        let perCall = model.brollSecondsPerCall ?? 15
        let frames = Double(model.brollScanMode.rawValue)
        let perClip = perCall * frames
        guard unrecognizedCount > 0 else { return String(format: "每次调用约 %.0f 秒", perCall) }
        let total = perClip * Double(unrecognizedCount)
        return String(format: "每次约 %.0f 秒 · 这一批约 %.0f 分钟", perCall, total / 60)
    }

    @ViewBuilder private var progressBars: some View {
        if let progress = model.brollAnalysisProgress {
            ProgressView(value: progress) {
                Text("画面内容识别 \(Int(progress * 100))%").font(.caption2)
            }
            .progressViewStyle(.linear).padding(.horizontal, 10).padding(.bottom, 6)
        }
        if let progress = model.brollProductProgress {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress).progressViewStyle(.linear)
                Text(model.brollProductNotice.isEmpty ? "本地模型正在认画面物品…" : model.brollProductNotice)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 10).padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有 B-roll 素材", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("把 B-roll 视频或整个文件夹加进来。加进来只是登记，原文件不会被复制或改动。")
        } actions: {
            Button("添加 B-roll 素材") { model.promptImportBroll() }.buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(model.visibleBrollAssets) { asset in
                    row(asset)
                }
            }
            .padding(8)
            if model.visibleBrollAssets.isEmpty {
                Text("没有符合条件的素材").font(.caption).foregroundStyle(.secondary).padding(.top, 30)
            }
        }
    }

    private func row(_ asset: BrollAsset) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.5))
                if let image = model.brollThumbnails[asset.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 62, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(brollClock(asset.duration)).font(.caption2.monospacedDigit())
                    if let products = productsLine(asset) {
                        Text("·").font(.caption2)
                        Text(products).font(.caption2).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // 状态点：一眼看出这条处于哪一步。颜色含义写在提示里，不用猜。
            Circle()
                .fill(statusColor(asset))
                .frame(width: 7, height: 7)
                .help(statusHint(asset))
        }
        .padding(5)
        .background(model.brollSelection.contains(asset.id) ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        // 点选 / ⌘ 点选：选中的这一批可以直接拖到右边的文件夹里。
        .onTapGesture {
            model.selectBroll(
                asset.id,
                extend: NSEvent.modifierFlags.contains(.command),
                range: NSEvent.modifierFlags.contains(.shift)
            )
        }
        // 拖的是"整个选中批次"：拖其中一条，动的是这一批。
        .draggable(BrollDragPayload.encode(dragIDs(for: asset)))
        .contextMenu {
            if model.brollSelection.count > 1, model.brollSelection.contains(asset.id) {
                Text("已选 \(model.brollSelection.count) 条")
            }
            // 不想拖也可以走菜单：模型认不出来的素材（局部特写、对比产品）靠这一步归类。
            Menu("加入文件夹") {
                if model.brollGroups.isEmpty {
                    Text("先在右边新建一个文件夹")
                } else {
                    ForEach(model.brollGroups) { group in
                        Button(group.label) {
                            model.assignBrollAssets(dragIDs(for: asset), to: group.id)
                        }
                    }
                }
            }
            Button("在访达中显示", systemImage: "folder") { model.revealBrollInFinder(asset.id) }
            Divider()
            Button("移出媒体库", systemImage: "trash", role: .destructive) { pendingRemoval = asset.id; confirmRemove = true }
        }
        .task(id: asset.id) { await model.ensureBrollThumbnail(asset.id) }
    }

    /// 状态点的颜色：灰=还没认过，橙=有待确认的东西，绿=已归类，蓝=认过但还没归类。
    private func statusColor(_ asset: BrollAsset) -> Color {
        guard let inventory = asset.inventory else { return Color.secondary.opacity(0.35) }
        if !model.pendingUnknowns(in: asset).isEmpty { return .orange }
        if !model.brollFolders(of: asset).isEmpty { return .green }
        return .accentColor
    }

    private func statusHint(_ asset: BrollAsset) -> String {
        guard let inventory = asset.inventory else { return "还没认过物品" }
        if !model.pendingUnknowns(in: asset).isEmpty { return "有 \(model.pendingUnknowns(in: asset).count) 件东西等你确认" }
        let folders = model.brollFolders(of: asset)
        if !folders.isEmpty { return "已归类：" + folders.map(\.name).joined(separator: "、") }
        return "认过物品，但还没归到任何文件夹"
    }

    /// 拖这条时要带走哪些素材：它是选中批次里的一条，就带整批；否则只带它自己。
    private func dragIDs(for asset: BrollAsset) -> [UUID] {
        model.brollSelection.contains(asset.id) ? model.brollSelectedAssets.map(\.id) : [asset.id]
    }

    /// 这一条素材里有哪几个产品、手动放进了哪个文件夹（缩到一行）。
    private func productsLine(_ asset: BrollAsset) -> String? {
        var parts: [String] = []
        if let inventory = asset.inventory {
            if !inventory.appearances.isEmpty {
                let names = inventory.appearances.prefix(2).map(\.label).joined(separator: "、")
                parts.append(inventory.appearances.count > 2 ? "\(names) +\(inventory.appearances.count - 2)" : names)
            }
            if !inventory.suspected.isEmpty { parts.append("疑似 \(inventory.suspected.count) 款") }
        }
        // 手动归类过的：直接把文件夹名写出来，一眼看出你把它放哪儿了。
        let manual = model.brollFolders(of: asset).filter(\.manual).map(\.name)
        if !manual.isEmpty { parts.append("→ " + manual.prefix(2).joined(separator: "、")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 按产品分组（右栏）

/// 分类结果：一款产品（含颜色）一个文件夹，只收实拍里真的认出来的那几款。
/// 一条素材里出现了两个产品，它就会在两个文件夹里各出现一次 —— 这是同一份素材，不是副本。
private struct BrollGroupPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var confirmRemove = false
    @State private var pendingRemoval: UUID?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: UUID?
    @State private var renamingName = ""
    @State private var dropTargetFolder: UUID?
    /// 折叠起来的文件夹（点标题左边的三角）。
    @State private var collapsedFolders: Set<UUID> = []

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if model.brollGroups.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("把这条素材移出 B-roll 库？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移出媒体库", role: .destructive) {
                if let pendingRemoval { model.removeBrollAssets([pendingRemoval]) }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只从 CodeCut 的媒体库里移除，硬盘上的原始文件不会被动。")
        }
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名，例如 对比产品", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("新建") {
                model.createBrollFolder(named: newFolderName)
                newFolderName = ""
            }
        } message: {
            Text("模型认不出来的素材（局部特写、不在 brief 里的对比产品）靠这个归类：建好之后把左栏的素材拖进来。")
        }
        .alert("重命名文件夹", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("文件夹名", text: $renamingName)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("改名") {
                if let renamingFolder { model.renameBrollFolder(renamingFolder, to: renamingName) }
                renamingFolder = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("按产品分组", systemImage: "folder").font(.headline.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text("\(model.brollGroups.count) 个文件夹 · 未归入 \(model.brollUngroupedCount) 条")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if !model.brollSelection.isEmpty {
                Text("已选 \(model.brollSelection.count) 条")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
            Button {
                newFolderName = ""
                showingNewFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .help("自己建一个文件夹（比如“对比产品”），然后把左栏的素材拖进去")
        }
        .padding(.horizontal, 12).frame(height: 42).background(Color(red: 0.105, green: 0.115, blue: 0.125))
    }

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 9) {
                Picker("方向", selection: $model.brollMotionFilter) {
                    Text("全部方向").tag(BrollMotion?.none)
                    ForEach(BrollMotion.allCases, id: \.self) { Text($0.rawValue).tag(BrollMotion?.some($0)) }
                }.labelsHidden().frame(width: 132)
                Divider().frame(height: 18)
                Picker("产品", selection: $model.brollProductFilter) {
                    Text("全部素材").tag(BrollProductPresence?.none)
                    Text(BrollProductPresence.mainSubject.rawValue).tag(BrollProductPresence?.some(.mainSubject))
                    Text(BrollProductPresence.visible.rawValue).tag(BrollProductPresence?.some(.visible))
                    Text("没拍到产品").tag(BrollProductPresence?.some(.none))
                }.labelsHidden().frame(width: 116)
                Toggle(isOn: $model.brollSortByPick) { Text("按推荐分排") }
                    .toggleStyle(.checkbox).font(.caption)
                    .disabled(model.pickedBrollCount == 0)
                    .help("挑过产品镜头的素材按推荐分从高到低排在最前面。")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 38)
    }

    private var emptyState: some View {
        Group {
            if model.brollAssets.isEmpty {
                ContentUnavailableView {
                    Label("还没有素材", systemImage: "rectangle.stack")
                } description: {
                    Text("先从左栏把 B-roll 加进来。")
                }
            } else if isFiltering {
                ContentUnavailableView {
                    Label("没有符合条件的分组", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("换一个搜索词，或者把方向、产品筛选清掉。")
                }
            } else {
                ContentUnavailableView {
                    Label("还没有产品分组", systemImage: "folder")
                } description: {
                    Text("分组来自识别结果：先读一份 brief，再点左栏的识别按钮，认出哪一款产品就长出哪个文件夹。")
                } actions: {
                    Button("识别画面物品") { Task { await model.analyzeBrollProducts(ids: model.brollAssets.map(\.id)) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.localModelState.isReady)
                }
            }
        }
    }

    private var isFiltering: Bool {
        !model.brollQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.brollMotionFilter != nil
            || model.brollProductFilter != nil
            || model.brollOnlyPendingUnknown
    }

    private var groups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(model.brollGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        folderHeader(group)
                        if !collapsedFolders.contains(group.id) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 10)], spacing: 10) {
                            ForEach(group.assets) { asset in
                                BrollCard(
                                    asset: asset,
                                    selected: model.brollSelection.contains(asset.id),
                                    onRemove: { pendingRemoval = asset.id; confirmRemove = true },
                                    folderLabel: group.label,
                                    onRemoveFromFolder: { model.removeBrollAssets([asset.id], from: group.id) }
                                )
                                .onTapGesture {
                                    model.selectBroll(
                                        asset.id,
                                        extend: NSEvent.modifierFlags.contains(.command),
                                        range: NSEvent.modifierFlags.contains(.shift)
                                    )
                                }
                                .draggable(BrollDragPayload.encode(model.brollSelection.contains(asset.id) ? model.brollSelectedAssets.map(\.id) : [asset.id]))
                            }
                        }
                        }
                    }
                    // 拖到这一块的任何位置都算放进这个文件夹。
                    .padding(6)
                    .background(dropTargetFolder == group.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.flatMap(BrollDragPayload.decode)
                        guard !ids.isEmpty else { return false }
                        model.assignBrollAssets(ids, to: group.id)
                        return true
                    } isTargeted: { targeted in
                        if targeted { dropTargetFolder = group.id }
                        else if dropTargetFolder == group.id { dropTargetFolder = nil }
                    }
                }
                if model.brollUngroupedCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
                        Text("还有 \(model.brollUngroupedCount) 条素材没认到任何产品 —— 它们只在左栏的「全部素材」里。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
        }
    }

    private func folderHeader(_ group: BrollGroup) -> some View {
        let collapsed = collapsedFolders.contains(group.id)
        return HStack(spacing: 7) {
            // 折叠：文件夹多了之后一屏看不完，先收起来几个。
            Button {
                if collapsed { collapsedFolders.remove(group.id) } else { collapsedFolders.insert(group.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "展开这个文件夹" : "折叠这个文件夹")
            Image(systemName: group.isManual ? "folder.badge.plus" : "folder.fill")
                .foregroundStyle(group.isManual ? Color.orange : Color.accentColor)
            Text(group.label).font(.callout.weight(.semibold)).lineLimit(1)
            if !group.sku.isEmpty { BrollItemChip(text: group.sku, symbol: "barcode", tint: .secondary) }
            if group.isManual { BrollItemChip(text: "手动", symbol: "hand.draw", tint: .orange) }
            Text("\(group.count) 条").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if dropTargetFolder == group.id {
                Text("松手放进来").font(.caption2).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .contextMenu {
            if group.isManual {
                Button("重命名…", systemImage: "pencil") {
                    renamingFolder = group.id
                    renamingName = group.label
                }
                Button("删除文件夹", systemImage: "trash", role: .destructive) { model.deleteBrollFolder(group.id) }
            } else {
                Text("这是 brief 里的产品分组：名字跟着产品清单走")
            }
        }
    }
}

// MARK: - 单条素材卡片

private struct BrollCard: View {
    @Environment(EditorModel.self) private var model
    let asset: BrollAsset
    let selected: Bool
    let onRemove: () -> Void
    /// 在某个文件夹里显示时，带上"从该文件夹移出"。
    var folderLabel: String? = nil
    var onRemoveFromFolder: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                if let image = model.brollThumbnails[asset.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Text(brollClock(asset.duration)).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(5)
            }
            .overlay(alignment: .topLeading) { motionBadge }
            .overlay(alignment: .topTrailing) { productBadge }
            HStack(spacing: 4) {
                Text(asset.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(asset.resolutionLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(contentLine)
                .font(.caption2).foregroundStyle(asset.isAnalyzed ? .secondary : .tertiary).lineLimit(1)
            if let curve = asset.analysis?.motionCurve, curve.isUsable {
                BrollSpeedSparkline(curve: curve).frame(height: 18)
            }
            if let inventory = asset.inventory, !inventory.items.isEmpty {
                // 这条素材归哪几个产品，卡片上直接标出来：
                // 同一条素材可以同时属于两个产品，所以在两个分组里都会看到这几个标签。
                ChipFlow(spacing: 4) {
                    ForEach(inventory.appearances.prefix(2)) { product in
                        BrollItemChip(
                            text: product.label,
                            symbol: product.focusCount > 0 ? "scope" : "shippingbox",
                            tint: .accentColor
                        )
                    }
                    if inventory.appearances.count > 2 {
                        BrollItemChip(text: "+\(inventory.appearances.count - 2) 款", symbol: "square.stack", tint: .secondary)
                    }
                    // 只在背景/陪衬里出现的同款：标成“疑似”，不冒充“这条拍到了它”。
                    ForEach(inventory.suspected.prefix(1)) { product in
                        BrollItemChip(text: "疑似 \(product.label)", symbol: "questionmark.circle", tint: .secondary)
                    }
                    if inventory.suspected.count > 1 {
                        BrollItemChip(text: "+\(inventory.suspected.count - 1) 疑似", symbol: "square.stack", tint: .secondary)
                    }
                    // 一件产品都没认到时，至少把主角写出来 —— 不然卡片上什么都没有。
                    if inventory.appearances.isEmpty, inventory.suspected.isEmpty, let subject = inventory.subject {
                        BrollItemChip(text: subject.label, symbol: "scope", tint: .secondary)
                    }
                    if !inventory.pending.isEmpty {
                        BrollItemChip(text: "待确认 \(inventory.pending.count)", symbol: "questionmark.circle", tint: .orange)
                    }
                }
            }
            // 手动归类的标签：拖进文件夹之后要能在这条素材上看到"它属于哪儿"。
            if !asset.manualFolderIDs.isEmpty {
                ChipFlow(spacing: 4) {
                    ForEach(model.brollFolders(of: asset), id: \.name) { folder in
                        BrollItemChip(
                            text: folder.name,
                            symbol: folder.manual ? "hand.draw" : "folder",
                            tint: folder.manual ? .orange : .accentColor
                        )
                    }
                }
            }
            // 没读 brief 时只列物品，不显示“没拍到产品”这类结论 —— 那会让人以为素材不行。
            if let pick = asset.productPick, pick.hasTarget {
                HStack(spacing: 4) {
                    Image(systemName: pick.presence.symbol)
                    Text(pick.isUsable ? "用 \(pick.timecodeRange)" : (pick.containsProduct ? "片段偏短" : "没拍到产品"))
                    Spacer(minLength: 0)
                    Text("\(pick.score) 分")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(pick.isUsable ? Color.accentColor : Color.secondary)
                .lineLimit(1)
            }
        }
        .padding(7)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.white.opacity(0.07), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("AI 识别这一条", systemImage: "wand.and.stars") { Task { await model.analyzeBroll(ids: [asset.id]) } }
            Button("在访达中显示", systemImage: "folder") { model.revealBrollInFinder(asset.id) }
            if let onRemoveFromFolder, let folderLabel {
                Divider()
                Button("从「\(folderLabel)」移出", systemImage: "folder.badge.minus", action: onRemoveFromFolder)
            }
            Divider()
            Button("移出媒体库", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .task(id: asset.id) { await model.ensureBrollThumbnail(asset.id) }
    }

    @ViewBuilder private var motionBadge: some View {
        if let analysis = asset.analysis, asset.isAnalyzed {
            HStack(spacing: 3) {
                Image(systemName: analysis.motion.symbol).font(.caption2)
                Text(analysis.motion.rawValue).font(.caption2)
                if analysis.zoom != .none {
                    Image(systemName: analysis.zoom.symbol).font(.caption2)
                    Text(analysis.zoom.rawValue).font(.caption2)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 5))
            .padding(5)
        }
    }

    /// 产品徽章：只说“有没有拍到产品”，不说镜头语言。
    @ViewBuilder private var productBadge: some View {
        if let pick = asset.productPick {
            HStack(spacing: 3) {
                Image(systemName: pick.presence.symbol).font(.caption2)
                Text(pick.presence.rawValue).font(.caption2)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(pick.containsProduct ? Color.black : Color.white)
            .background(pick.containsProduct ? Color.accentColor.opacity(0.92) : Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 5))
            .padding(5)
        }
    }

    /// 状态那一行：画面内容标签不再显示（那是低置信度的泛泛分类），
    /// 只留"这条走到哪一步了"这种有用的信息。
    private var contentLine: String {
        if !asset.isAnalyzed {
            return asset.inventory != nil ? "认过物品，还没算运动曲线" : "未识别"
        }
        if let inventory = asset.inventory, !inventory.items.isEmpty {
            if let subject = inventory.subject { return "画面主角：" + subject.label }
            return "认到 \(inventory.items.count) 件东西"
        }
        return "已算运动曲线"
    }
}

// MARK: - 预览

/// 物品小标签：卡片和识别结果里共用。
private struct BrollItemChip: View {
    let text: String
    var symbol: String = "circle"
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
    }
}

/// 产品档案：告诉本地模型“这次要展示的是什么产品”。
/// brief 决定产品是什么，参考图决定模型能不能用眼睛把它认出来。
private struct ProductProfilePanel: View {
    @Environment(EditorModel.self) private var model
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                ScrollView { content.padding(12) }
            }
        }
        // 不要在这里写 maxHeight: .infinity：那会让 VSplitView 以为这块永远要占满，
        // 折叠之后就留下一大条空隙。高度交给外层的 frame 控制。
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color.black.opacity(0.14))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("产品档案", systemImage: "shippingbox").font(.headline.weight(.semibold)).lineLimit(1).layoutPriority(1)
            Text(model.productProfile.isConfigured ? model.productProfile.name : "还没读 brief")
                .font(.caption).foregroundStyle(model.productProfile.isConfigured ? .secondary : .tertiary).lineLimit(1)
            Spacer(minLength: 6)
            Button { Task { await model.prepareLocalModel() } } label: {
                Label(model.localModelState.label, systemImage: localModelSymbol)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(localModelColor.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isPreparingLocalModel)
            .help(model.localModelState.isReady ? "本地模型已就绪，点一下可以重新检查。" : "点这里一次性下载本地模型运行时和权重，之后挑产品镜头全部在本机完成。")
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                .buttonStyle(.plain).help(expanded ? "收起产品档案" : "展开产品档案")
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Color(red: 0.105, green: 0.115, blue: 0.125))
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            localModelSection
            briefSection
            if model.productProfile.isConfigured { profileSection }
            analyzeSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("本地模型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // 换模型：4B 更快、4B 更省内存，但识别能力弱一些 —— 这个取舍交给用户。
            HStack(spacing: 6) {
                Text("视觉模型").font(.caption).foregroundStyle(.secondary)
                Picker("视觉模型", selection: Binding(get: { model.localModelChoice }, set: { model.selectLocalModel($0) })) {
                    ForEach(LocalVLM.Model.allCases, id: \.rawValue) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 196)
                .help("换模型会重启本地服务；没下载过的那个会先下载（4B 约 3GB）")
                Text(model.localModelChoice.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Image(systemName: localModelSymbol).foregroundStyle(localModelColor)
                Text(model.localModelState.label).font(.callout.weight(.medium))
                Spacer(minLength: 6)
                if model.isPreparingLocalModel {
                    Button("取消", role: .destructive) { model.cancelLocalModelPreparation() }
                } else if model.localModelState.isReady {
                    Button("重新检查") { Task { await model.refreshLocalModel() } }
                } else {
                    Button("准备本地模型", systemImage: "arrow.down.circle") { Task { await model.prepareLocalModel() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if !model.localModelNotice.isEmpty {
                Text(model.localModelNotice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("视觉模型（Qwen3-VL 8B）跑在这台电脑上，视频不用上传，断网也能用。第一次点“准备本地模型”会下载运行时和权重。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("产品说明").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.productProfile.briefPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未选择 brief")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Button("读 brief", systemImage: "doc.text.magnifyingglass") { model.promptProductBrief() }
                    .disabled(model.isAnalyzingBrollProduct || model.isPreparingLocalModel)
                    .help("选品牌方给的 brief（PDF）。本地模型会先弄清产品是什么、长什么样，再挑镜头。")
                Button("加参考图", systemImage: "photo.badge.plus") { model.promptProductReferenceImages() }
                    .help("brief 里没有清楚的产品图时，可以自己补几张能看清产品本体的照片。")
                if model.productProfile.isConfigured {
                    Button("重读 brief", systemImage: "arrow.clockwise") { model.promptProductBrief() }
                        .disabled(model.isAnalyzingBrollProduct || model.isPreparingLocalModel)
                }
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.productProfile.summary.isEmpty {
                Text(model.productProfile.summary).font(.callout)
            }
            // 产品清单：brief 里给到的每一款每一种颜色都在这里，实拍认出哪一款就归哪一款。
            if !model.productProfile.products.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("产品清单").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(model.productProfile.products.count) 款").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                        Text("实拍里认出哪一款，就归到哪一款").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(model.productProfile.products) { product in
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.secondary)
                            Text(product.shortLabel).font(.caption).lineLimit(1)
                            if !product.sku.isEmpty { BrollItemChip(text: product.sku, symbol: "barcode", tint: .secondary) }
                            Spacer(minLength: 4)
                            Text("参考图 \(product.referenceImages.count) 张").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if !model.productProfile.features.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("要认出来的特征").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ChipFlow(spacing: 6) {
                        ForEach(model.productProfile.features, id: \.self) { Chip(text: $0, tint: .accentColor) }
                    }
                }
            }
            if !model.productProfile.avoid.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("不要误判成").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ChipFlow(spacing: 6) {
                        ForEach(model.productProfile.avoid, id: \.self) { Chip(text: $0, tint: .orange) }
                    }
                }
            }
            if !model.productProfile.knownCompetitors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("已确认的竞品").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text("识别时会直接按竞品判断").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ChipFlow(spacing: 6) {
                        ForEach(model.productProfile.knownCompetitors, id: \.self) { Chip(text: $0, tint: .orange) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("产品参考图").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(model.productProfile.referenceImages.count) 张").font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    Text("模型靠这几张图认产品").font(.caption2).foregroundStyle(.tertiary)
                }
                if model.productProfile.referenceImages.isEmpty {
                    Text("还没有参考图。读 brief 时会自动从里面挑产品图，也可以手动加。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.productProfile.referenceImages) { reference in
                                referenceThumb(reference)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
            if let builtAt = model.productProfile.builtAt {
                Text("档案生成于 \(builtAt.formatted(date: .abbreviated, time: .shortened)) · \(model.productProfile.engine)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func referenceThumb(_ reference: ProductReferenceImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = model.productReferenceThumbnails[reference.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 84, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Button { model.removeProductReference(reference.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain).padding(2)
        }
        .help(reference.caption.isEmpty ? reference.path : reference.caption)
        .task(id: reference.id) { await model.ensureReferenceThumbnail(reference.id) }
    }

    private var analyzeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("识别画面物品").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("本机会逐条看素材的 5 个采样点：画面里有哪些东西、哪一件是「\(model.productProfile.name.isEmpty ? "这个产品" : model.productProfile.name)」、哪一段既有产品又稳、能直接用来展示。识别结果只在这台电脑上算，素材不出门。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.brollAssets.isEmpty {
                Text("这一批要问本地模型 \(model.brollAssets.count * BrollAnalyzer.visionSampleCount) 次（每条 \(BrollAnalyzer.visionSampleCount) 帧），会一条条跑，中途可以停。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if model.isAnalyzingBrollProduct {
                    Button("停止识别", role: .destructive) { model.cancelBrollProductAnalysis() }
                } else {
                    Button("识别所有素材", systemImage: "scope") { Task { await model.analyzeBrollProducts(ids: model.brollAssets.map(\.id)) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAnalyze)
                }
                Spacer(minLength: 6)
                Text("已识别 \(model.pickedBrollCount) 条 · 拍到产品 \(model.productBrollCount) 条")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let progress = model.brollProductProgress {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
            if !model.brollProductNotice.isEmpty {
                Text(model.brollProductNotice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !model.localModelState.isReady {
                Text("本地模型还没就绪，先点上面的“准备本地模型”。")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !model.productProfile.isConfigured {
                // 没有档案也能跑：只列画面里的物品。要认出是哪一款产品，得先读 brief。
                Text("还没有产品档案：现在跑只会列出画面里的物品，认不出是哪一款产品。读一份 brief 就能对号入座。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var canAnalyze: Bool {
        model.localModelState.isReady && !model.brollAssets.isEmpty
    }

    private var localModelSymbol: String {
        switch model.localModelState {
        case .ready: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .checking, .loading: "hourglass"
        case .modelFilesMissing: "arrow.down.circle"
        case .runtimeMissing, .serverDown, .unknown: "cpu"
        }
    }

    private var localModelColor: Color {
        switch model.localModelState {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

/// 产品档案里的小标签。文稿页复用。
struct Chip: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

private struct BrollPreviewPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var player = AVPlayer()
    @State private var position = 0.0
    @State private var playingID: UUID?
    /// 播到这一刻就自动停。预览一整段可用片段时用：从入点播到出点，不越过它继续播。
    @State private var stopAt: Double?
    /// 空格键监听器。装上就吃掉空格，所以不在编辑文字时才装。
    @State private var keyMonitor: Any?

    private var asset: BrollAsset? { model.brollAssets.first { $0.id == model.selectedBrollID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("B-roll 预览", systemImage: "play.rectangle").font(.headline.weight(.semibold))
                if let asset { Text(asset.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let asset { Text("\(brollClock(position)) / \(brollClock(asset.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).frame(height: 42).background(Color(red: 0.105, green: 0.115, blue: 0.125))
            ZStack {
                Color.black
                if asset != nil { NativePlayerView(player: player) }
                else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack").font(.largeTitle)
                        Text("在左边选一条 B-roll 就能在这里预览").foregroundStyle(.secondary)
                    }
                }
            }
            if let asset {
                HStack(spacing: 9) {
                    Button { toggle() } label: { Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill") }
                        .help("播放 / 暂停（空格）")
                    Button { stopAt = nil; seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                        .help("回到开头")
                    Slider(value: $position, in: 0...max(0.1, asset.duration)) { editing in
                        if editing { stopAt = nil } else { seek(to: position) }
                    }
                    Text(asset.resolutionLabel).font(.caption).foregroundStyle(.secondary)
                    if let stopAt {
                        // 正在预览某一段：说清楚会停在哪，别让人以为播放器卡住了。
                        Text("播到 \(brollClock(stopAt)) 自动停").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).frame(height: 40).background(.thinMaterial)
            }
        }
        .onChange(of: model.selectedBrollID) { _, _ in load() }
        // 识别结果里点某个时间点：跳到那一刻，好核对认出来的东西是不是真在那一帧。
        .onChange(of: model.brollPreviewRequest) { _, request in
            guard let request, request.assetID == asset?.id else { return }
            load()
            seek(to: request.time)
            // 带 stopAt = 预览这一整段；不带的只是跳过去看一眼，不动播放状态。
            stopAt = request.stopAt
            if request.stopAt != nil { player.play() }
        }
        .onAppear { load(); installSpaceKey() }
        .onDisappear { player.pause(); removeSpaceKey() }
        .task {
            // 轮询播放位置：比维护 AVPlayer 的周期观察者更省事，也不会漏掉 seek。
            while !Task.isCancelled {
                if player.timeControlStatus == .playing {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite {
                        position = seconds
                        model.brollPreviewTime = seconds
                    }
                    if let stopAt, seconds >= stopAt - 0.03 {
                        // 停在出点上，不越过它继续播。
                        player.pause()
                        self.stopAt = nil
                        seek(to: stopAt)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func load() {
        guard let asset else { player.replaceCurrentItem(with: nil); playingID = nil; return }
        guard playingID != asset.id else { return }
        playingID = asset.id
        position = 0
        model.brollPreviewTime = 0
        stopAt = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: asset.path)))
    }

    private func toggle() {
        if player.timeControlStatus == .playing { player.pause(); stopAt = nil; return }
        // 停在结尾时再按播放，从头来 —— 不然按下去什么都没发生。
        if position >= (asset?.duration ?? 0) - 0.05 { seek(to: 0) }
        stopAt = nil
        player.play()
    }

    private func seek(to time: Double) {
        let clamped = min(max(0, time), max(0, asset?.duration ?? 0))
        position = clamped
        model.brollPreviewTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 空格播放

    /// 空格播放这一条素材。
    ///
    /// 用本地事件监听而不是 `keyboardShortcut(.space)`：没有修饰键的快捷键会连
    /// 文本框里的空格一起吃掉，搜索框就打不出空格了。这里只在“没在编辑文字”时
    /// 拦截，其余情况原样放行给文本框。
    private func installSpaceKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !Self.isEditingText else { return event }
            toggle()
            return nil
        }
    }

    private func removeSpaceKey() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 光标是不是在文本里。SwiftUI 的 TextField / TextEditor 都把编辑工作交给
    /// 一个 NSTextView（field editor），所以认它就够了。
    private static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return (responder as? NSView) is NSTextField
    }
}

// MARK: - 识别结果

private struct BrollAnalysisPanel: View {
    @Environment(EditorModel.self) private var model
    /// 逐帧明细默认收起：平时用不到，想看的时候再展开。
    @State private var frameLinesExpanded = false

    private var asset: BrollAsset? { model.brollAssets.first { $0.id == model.selectedBrollID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("AI 识别结果", systemImage: "wand.and.stars").font(.headline.weight(.semibold))
                    .lineLimit(1).layoutPriority(1)
                Text("本地识别 · 不联网").font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 6)
                if let asset {
                    Button("识别这条") { Task { await model.analyzeBroll(ids: [asset.id]) } }.disabled(model.isAnalyzingBroll)
                    Button { model.revealBrollInFinder(asset.id) } label: { Image(systemName: "folder") }.help("在访达中显示")
                    Button(role: .destructive) { model.removeBrollAssets([asset.id]) } label: { Image(systemName: "trash") }.help("移出 B-roll 库")
                }
            }.padding(.horizontal, 12).frame(height: 42).background(Color(red: 0.105, green: 0.115, blue: 0.125))
            Divider()
            ScrollView {
                if let asset { detail(asset) } else {
                    Text("还没有选中素材").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
        }
    }

    @ViewBuilder private func detail(_ asset: BrollAsset) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            segmentsSection(asset)
            itemsSection(asset)
            motionSection(asset)
            if let pick = asset.productPick, pick.hasTarget { productSection(asset, pick) }
            HStack(spacing: 18) {
                stat("时长", brollClock(asset.duration))
                stat("分辨率", asset.resolutionLabel)
            }
            // 画面标签（"行李箱 31%" 那种）和文字版的运动方向都不显示了：
            // 前者是低置信度的泛泛分类，后者已经被上面的运动曲线代替。
            // 「还没算过运动曲线」的入口在可用片段那一块，这里只说产品档案准备好了没有。
            if !asset.isAnalyzed, model.productProfile.isConfigured {
                Text("产品档案已就绪：点上面的“识别画面物品”，本机会列出每一帧里有什么、哪一件是「\(model.productProfile.name)」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(asset.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }

    // MARK: - 可用片段

    /// 这条素材里能直接剪进去的段。
    ///
    /// 判定只看运动轨迹，跟有没有认过产品无关 —— 环境空镜、花絮、产品清单里
    /// 没有的东西，照样能切出可用片段来。跑过物品识别时会把焦点切换点也算进去。
    @ViewBuilder private func segmentsSection(_ asset: BrollAsset) -> some View {
        let segments = asset.usableSegments
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("可用片段").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(asset.analysis?.motionCurve?.isUsable == true ? "\(segments.count) 段" : "—")
                    .font(.caption2).foregroundStyle(.tertiary)
                if segments.contains(where: \.approved) {
                    Text("· 已勾选 \(segments.filter(\.approved).count) 段").font(.caption2).foregroundStyle(.green)
                }
                Spacer(minLength: 6)
                Text("每段至少 \(String(format: "%.1f", BrollMotionCurve.minimumSegmentDuration)) 秒")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .help("可用片段 = 画面在这段时间里稳定地走完一个完整的运动。固定镜头取静止的那一段；移动镜头每完成一个单向过程算一段（滑轨过去再回来是两段）；轻微的上下漂移也算。判定只看运动轨迹，不联网、不需要产品识别。出入点可以手动调，打勾的是你认可的段。")

            if let curve = asset.analysis?.motionCurve, curve.isUsable {
                if segments.isEmpty {
                    Text("这条没有可用片段：每一段都短于 \(String(format: "%.1f", BrollMotionCurve.minimumSegmentDuration)) 秒，或者整条都在调整机位、来回晃。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    BrollSegmentBar(curve: curve, segments: segments)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(asset: asset, segment: segment, index: index + 1)
                        }
                    }
                    Text("浅灰是没能成段的部分：运镜的起手、转折、收尾，以及固定镜头前后挪机器的那两下。段内平均速度越小越稳；出入点调过之后，打勾前先播一遍再确认。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text("还没算过运动曲线，切不出可用片段。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("算这条的运动曲线") { Task { await model.analyzeBroll(ids: [asset.id]) } }
                    .disabled(model.isAnalyzingBroll)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func segmentRow(asset: BrollAsset, segment: BrollUsableSegment, index: Int) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: segment.kind.symbol)
                .font(.caption)
                .foregroundStyle(BrollSegmentStyle.tint(segment.kind))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    BrollItemChip(text: segment.kind.rawValue, symbol: segment.kind.symbol, tint: BrollSegmentStyle.tint(segment.kind))
                        .help(segment.kind.detail)
                    // 平移了就说往哪走；只推近/拉远的不报方向，免得写成“固定镜头”。
                    if segment.kind == .oneWay, segment.motion != .staticShot {
                        BrollItemChip(text: segment.motion.rawValue, symbol: segment.motion.symbol, tint: .secondary)
                    }
                    if segment.zoom != .none {
                        BrollItemChip(text: segment.zoom.rawValue, symbol: segment.zoom.symbol, tint: .secondary)
                    }
                    Text(segment.timecodeRange).font(.caption.monospacedDigit())
                    Text("\(String(format: "%.1f", segment.duration)) 秒").font(.caption2).foregroundStyle(.secondary)
                    if segment.isAdjusted {
                        BrollItemChip(text: "手动出入点", symbol: "slider.horizontal.below.rectangle", tint: .purple)
                    }
                    if segment.focusSwitchTime != nil {
                        BrollItemChip(text: "焦点切换处", symbol: "scope", tint: .orange)
                    } else if segment.hasInnerFocusSwitch {
                        BrollItemChip(text: "段内有焦点切换", symbol: "exclamationmark.circle", tint: .orange)
                    }
                }
                Text(segmentDetail(segment, index: index))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                // 从入点播到出点，到了自动停 —— 一段一段看比拖着进度条找快得多。
                Button { model.playBrollSegment(asset.id, segment) } label: {
                    Image(systemName: "play.rectangle")
                }
                .help("从入点播到出点，到了自动停")
                Button("设入") { model.setBrollSegmentBoundary(asset.id, segmentID: segment.id, isStart: true, time: model.brollPreviewTime) }
                    .help("把入点设成预览里画面停住的那一刻：先把预览拖到想切的地方，再点这里")
                Button("设出") { model.setBrollSegmentBoundary(asset.id, segmentID: segment.id, isStart: false, time: model.brollPreviewTime) }
                    .help("把出点设成预览里画面停住的那一刻：先把预览拖到想切的地方，再点这里")
                Button { model.clearBrollSegmentEdit(asset.id, segmentID: segment.id) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!segment.isAdjusted && !segment.approved)
                .help("还原成识别切出来的出入点，勾选也一起清掉")
            }
            .buttonStyle(.borderless).font(.caption2)
            // 勾选放在每一段的最后：一行打勾 = 这段我认可。
            Toggle("", isOn: Binding(
                get: { segment.approved },
                set: { model.setBrollSegmentApproved(asset.id, segmentID: segment.id, approved: $0) }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .help("这段可以用：打勾记下来，后面接分镜表时先看打勾的。")
        }
    }

    private func segmentDetail(_ segment: BrollUsableSegment, index: Int) -> String {
        var parts = ["第 \(index) 段"]
        parts.append("平均 \(String(format: "%.2f", segment.averageSpeed)) %/秒")
        parts.append("净位移 \(String(format: "%.1f", segment.netShift))%")
        // 累计位移远大于净位移 = 画面在来回走，标出来才知道“稳”是怎么来的。
        if segment.travelled > segment.netShift * 2 + 0.5 {
            parts.append("累计 \(String(format: "%.1f", segment.travelled))%（来回走）")
        }
        if segment.focusSwitchTime != nil { parts.append("在焦点切换处切开") }
        else if segment.hasInnerFocusSwitch { parts.append("段内焦点切换离端点太近，没切开") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 画面里的物品

    /// 这条素材里认出了什么：每一件是什么、算不算产品、谁是主角、焦点在哪几帧换了人。
    @ViewBuilder private func itemsSection(_ asset: BrollAsset) -> some View {
        if let inventory = asset.inventory {
            VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("画面里的物品").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(inventory.items.count) 件 · \(inventory.focusTrack.count) 个采样点").font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                if inventory.focusSwitches > 0 {
                    BrollItemChip(text: "焦点换过 \(inventory.focusSwitches) 次", symbol: "arrow.left.arrow.right", tint: .orange)
                }
            }
            ForEach(inventory.items) { item in itemRow(item) }
            if !inventory.focusTrack.isEmpty { focusTrack(inventory) }
            frameLines(asset.productPick?.frames ?? [])
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func itemRow(_ item: BrollInventoryItem) -> some View {
        let isSubject = item.focusCount > 0
        let isCompetitor = model.productProfile.knownCompetitors.contains(item.label)
        let isIgnored = model.productProfile.knownIgnored.contains(item.label)
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: isSubject ? "scope" : item.role.symbol)
                .font(.caption)
                .foregroundStyle(isSubject ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.label).font(.callout.weight(.medium)).lineLimit(1)
                    if isSubject { BrollItemChip(text: "主角", symbol: "scope", tint: .accentColor) }
                    // 认出来了、但一次主角都没当过：多半是背景里的同款，标成疑似更老实。
                    if item.isMatched, !isSubject {
                        BrollItemChip(text: "疑似出现", symbol: "questionmark.circle", tint: .secondary)
                    }
                    BrollItemChip(text: item.role.rawValue, symbol: item.role.symbol, tint: .secondary)
                    if !item.sku.isEmpty { BrollItemChip(text: item.sku, symbol: "barcode", tint: .secondary) }
                    if isCompetitor { BrollItemChip(text: "已确认竞品", symbol: "flag", tint: .orange) }
                    if isIgnored { BrollItemChip(text: "已忽略", symbol: "eye.slash", tint: .secondary) }
                }
                Text(itemDetail(item))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                // 视频里核对：跳到它最清楚的那一帧，看看到底认对了没有。
                Button("看 \(BrollProductPick.timecode(item.sharpestTime))") { model.previewBrollMoment(item.sharpestTime) }
                    .buttonStyle(.borderless)
                    .help("把预览跳到这件东西最清楚的一刻")
                // 模型不认识的东西、和像别家产品的东西，都交给人确认：
                // 确认一次就写进产品档案，下次不用再问。
                if !item.isMatched, item.role.needsConfirmation, !isCompetitor, !isIgnored {
                    Button("这是竞品") { model.confirmBrollCompetitor(item.label) }.buttonStyle(.borderless)
                    Button("不是产品") { model.ignoreBrollObject(item.label) }.buttonStyle(.borderless)
                }
            }
            .font(.caption2)
        }
    }

    private func itemDetail(_ item: BrollInventoryItem) -> String {
        var parts: [String] = []
        if !item.times.isEmpty { parts.append("出现 \(item.timecodes)") }
        parts.append("最清楚 \(BrollProductPick.timecode(item.sharpestTime))（清晰 \(item.sharpest)）")
        if item.focusCount > 0 { parts.append("\(item.focusCount) 帧里是焦点") }
        if !item.note.isEmpty { parts.append(item.note) }
        return parts.joined(separator: " · ")
    }

    /// 焦点走向：相邻同一件的采样点合成一段，一眼看出焦点什么时候换了人。
    @ViewBuilder private func focusTrack(_ inventory: BrollInventory) -> some View {
        let segments = Self.focusSegments(inventory.focusTrack)
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("焦点走向").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 5) {
                        Image(systemName: "scope").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(segment.label).font(.caption).lineLimit(1)
                        // 点时间码就跳到那一段，方便确认焦点是不是真的换了人。
                        Button { model.previewBrollMoment(segment.start) } label: {
                            Text(segment.start == segment.end
                                 ? BrollProductPick.timecode(segment.start)
                                 : "\(BrollProductPick.timecode(segment.start))–\(BrollProductPick.timecode(segment.end))")
                                .font(.caption2.monospacedDigit())
                        }
                        .buttonStyle(.borderless)
                        .help("把预览跳到这一刻")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 运动曲线

    /// 这条素材是怎么动的：轨迹、速度曲线、阶段划分，都用数据说，不用文字形容。
    @ViewBuilder private func motionSection(_ asset: BrollAsset) -> some View {
        if let curve = asset.analysis?.motionCurve, curve.isUsable {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("运动曲线").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(curve.samples.count) 个采样点 · \(String(format: "%.1f", curve.sampledDuration)) 秒")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    Text(curve.engine).font(.caption2).foregroundStyle(.tertiary)
                }
                .help("位移刻度与识别结果里的“首尾位移”一致（同一套光流估计）：方向、快慢变化和阶段是准的，百分比是这套算法的刻度，不是像素值。")

                // 数字摘要：首尾净位移、速度、阶段数。
                HStack(spacing: 16) {
                    motionStat("净位移", String(format: "水平 %+.1f%% · 垂直 %+.1f%%", curve.samples.last?.x ?? 0, curve.samples.last?.y ?? 0))
                    motionStat("峰值速度", String(format: "%.2f 画面宽/秒", curve.peakSpeed))
                    motionStat("平均速度", String(format: "%.2f 画面宽/秒", curve.averageSpeed))
                }

                // 轨迹：整条片子的路线，颜色从蓝（开头）到橙（结尾）。
                VStack(alignment: .leading, spacing: 3) {
                    Text("轨迹（画面宽高的百分比，0 是起点）").font(.caption2).foregroundStyle(.secondary)
                    BrollTrajectoryChart(curve: curve).frame(height: 104)
                }

                // 速度：点一下跳到那一刻，用来核对“这里是不是真的停住了”。
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("速度").font(.caption2).foregroundStyle(.secondary)
                        Text("点曲线可以跳到那一刻").font(.caption2).foregroundStyle(.tertiary)
                    }
                    BrollSpeedChart(curve: curve) { time in model.previewBrollMoment(time) }
                }

                // 阶段：剪辑真正能用的是区间。
                VStack(alignment: .leading, spacing: 4) {
                    Text("运动阶段").font(.caption2).foregroundStyle(.secondary)
                    BrollPhaseBar(curve: curve)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(curve.phases) { phase in
                            HStack(spacing: 5) {
                                Image(systemName: phase.kind.symbol)
                                    .font(.system(size: 9))
                                    .foregroundStyle(BrollMotionStyle.tint(phase.kind))
                                Text(phase.kind.rawValue).font(.caption2)
                                Text("\(BrollProductPick.timecode(phase.start))–\(BrollProductPick.timecode(phase.end))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                                Button("跳到") { model.previewBrollMoment(phase.start) }
                                    .buttonStyle(.borderless).font(.caption2)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func motionStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }

    /// 逐帧物品：每条采样帧里有什么、焦点落在谁身上。
    @ViewBuilder private func frameLines(_ frames: [BrollFrameVerdict]) -> some View {
        if !frames.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                // 逐帧明细默认收起，展开才显示；展开时顺带把这句话解释也放出来。
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { frameLinesExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: frameLinesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        Text("逐帧结论").font(.caption2.weight(.semibold))
                        Text("\(frames.count) 帧").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(frameLinesExpanded ? "收起逐帧明细" : "展开看每一帧认到了什么")
                if frameLinesExpanded {
                    ForEach(frames) { frame in
                        HStack(alignment: .top, spacing: 5) {
                            Text(BrollProductPick.timecode(frame.time))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(frameLine(frame))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                    Text("模型对每一帧里每件东西都给了“清不清楚”，最清楚的那件就是这一帧的焦点所在——焦点换来换去，说明这条素材里有对焦转移。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func frameLine(_ frame: BrollFrameVerdict) -> String {
        guard !frame.objects.isEmpty else { return frame.note.isEmpty ? "没有认出物品" : frame.note }
        let focus = BrollInventory.focus(of: frame.objects)
        return frame.objects.map { object in
            var text = object.label
            if let spot = object.spot { text += "（\(spot.rawValue)" } else { text += "（" }
            text += "，清晰 \(object.sharpness)）"
            if object.slot == focus?.slot { text = "★ " + text }
            return text
        }.joined(separator: " · ")
    }

    /// 把焦点序列压成段落。
    private static func focusSegments(_ points: [BrollFocusPoint]) -> [(label: String, start: Double, end: Double)] {
        var segments: [(label: String, start: Double, end: Double)] = []
        for point in points {
            if let last = segments.last, last.label == point.label {
                segments[segments.count - 1].end = point.time
            } else {
                segments.append((point.label, point.time, point.time))
            }
        }
        return segments
    }

    /// 产品结论：这条素材有没有拍到产品、哪一段能直接用。
    @ViewBuilder private func productSection(_ asset: BrollAsset, _ pick: BrollProductPick) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("产品镜头", systemImage: pick.presence.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.productProfile.name.isEmpty ? pick.engine : model.productProfile.name)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                // 用的是哪个视觉模型：换模型试效果时要能一眼看出这批结果是谁算的。
                BrollItemChip(text: pick.engine, symbol: "cpu", tint: .secondary)
                Spacer()
                Text("\(pick.score) 分").font(.callout.weight(.semibold))
            }
            HStack(spacing: 8) {
                Label(pick.presence.rawValue, systemImage: pick.presence.symbol)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((pick.containsProduct ? Color.accentColor : Color.white).opacity(pick.containsProduct ? 0.22 : 0.08), in: Capsule())
                if pick.isUsable {
                    Text("推荐片段 \(pick.timecodeRange) · \(String(format: "%.1f", pick.duration)) 秒")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.green.opacity(0.2), in: Capsule())
                } else if pick.containsProduct {
                    Text("拍到了产品，但没有够长够稳的一段").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !pick.frames.isEmpty {
                HStack(spacing: 5) {
                    ForEach(pick.frames) { frame in
                        VStack(spacing: 1) {
                            Image(systemName: frame.presence.symbol).font(.caption2)
                            Text(BrollProductPick.timecode(frame.time)).font(.caption2.monospacedDigit())
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(frame.presence.rank >= BrollProductPresence.visible.rank ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        .help("\(frame.presence.rawValue) · 置信 \(frame.confidence)% · 清晰度 \(frame.sharpness)%\(frame.note.isEmpty ? "" : " · \(frame.note)")")
                    }
                }
            }
            if !pick.summary.isEmpty {
                Text(pick.summary).font(.callout)
            }
            if !pick.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(pick.reasons.enumerated()), id: \.offset) { _, reason in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "circle.fill").font(.system(size: 3)).padding(.top, 5)
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("加入分镜表", systemImage: "text.badge.plus") { model.addBrollPickToStoryboard(asset.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pick.isUsable)
                    .help(pick.isUsable ? "把 \(pick.timecodeRange) 这一段写成一条分镜，后面按分镜剪就行。" : "这条没有挑到可用的产品片段。")
                Button("重挑这条", systemImage: "arrow.clockwise") { Task { await model.analyzeBrollProducts(ids: [asset.id]) } }
                    .disabled(model.isAnalyzingBrollProduct || !model.localModelState.isReady)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(pick.isUsable ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(pick.isUsable ? 0.4 : 0.15), lineWidth: 1))
    }
}

// MARK: - 小工具

// MARK: - 运动曲线的画法

/// 运动阶段的配色：静止是灰的，匀速是蓝的，加减速是橙/青，来回晃是粉的。
private enum BrollMotionStyle {
    static func tint(_ kind: BrollMotionPhaseKind) -> Color {
        switch kind {
        case .hold: .gray
        case .steady: .blue
        case .accelerating: .orange
        case .decelerating: .teal
        case .unsettled: .pink
        }
    }
}

/// 可用片段的配色：固定镜头绿、单向移动蓝、小幅漂移青。
private enum BrollSegmentStyle {
    static func tint(_ kind: BrollSegmentKind) -> Color {
        switch kind {
        case .lockedOff: .green
        case .oneWay: .blue
        case .drift: .teal
        }
    }
}

/// 可用片段条：整条素材铺成一条，能用的段按类型上色，剩下的浅灰。
///
/// 一眼看出这条片子里「哪几段能用、断在哪」—— 数字列表说的是多长多久，
/// 这一条说的是它们各自在片子的什么位置。
private struct BrollSegmentBar: View {
    let curve: BrollMotionCurve
    let segments: [BrollUsableSegment]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BrollSegmentStyle.tint(segment.kind).opacity(0.85))
                        .frame(width: max(3, width(of: segment, in: geometry.size)))
                        .offset(x: position(segment.start, in: geometry.size))
                        .help("\(segment.kind.rawValue) · \(segment.timecodeRange) · \(String(format: "%.1f", segment.duration)) 秒")
                }
            }
        }
        .frame(height: 12)
        .help("彩色段是可用片段，浅灰是没能成段的部分（起手、转折、收尾）。横轴是曲线采到的那一段素材，约等于全片。")
    }

    /// 时间 → 这条小条上的横向位置。横轴是整条素材（用曲线覆盖到的那一段）。
    private func position(_ time: Double, in size: CGSize) -> Double {
        let origin = curve.samples.first?.time ?? 0
        let span = max(0.01, (curve.samples.last?.time ?? 0) - origin)
        return min(max((time - origin) / span, 0), 1) * size.width
    }

    private func width(of segment: BrollUsableSegment, in size: CGSize) -> Double {
        position(segment.end, in: size) - position(segment.start, in: size)
    }
}

/// 轨迹图：把逐点累计位移画成一条路径，颜色从蓝（开头）渐变到橙（结尾）。
private struct BrollTrajectoryChart: View {
    let curve: BrollMotionCurve

    var body: some View {
        Canvas { context, size in
            guard curve.samples.count >= 2 else { return }
            // 以起点为中心，按最大位移缩放。位移都很小的时候给一个下限，
            // 免得把纯手持的几像素抖动放大成一大片摆动。
            let extent = max(2.0, curve.samples.reduce(0) { max($0, max(abs($1.x), abs($1.y))) } * 1.25)
            func point(_ sample: BrollMotionSample) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + CGFloat(sample.x / extent) * size.width / 2,
                    y: size.height / 2 + CGFloat(sample.y / extent) * size.height / 2
                )
            }

            var grid = Path()
            grid.move(to: CGPoint(x: size.width / 2, y: 4))
            grid.addLine(to: CGPoint(x: size.width / 2, y: size.height - 4))
            grid.move(to: CGPoint(x: 4, y: size.height / 2))
            grid.addLine(to: CGPoint(x: size.width - 4, y: size.height / 2))
            context.stroke(grid, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            for index in 1..<curve.samples.count {
                let progress = Double(index) / Double(curve.samples.count - 1)
                var segment = Path()
                segment.move(to: point(curve.samples[index - 1]))
                segment.addLine(to: point(curve.samples[index]))
                context.stroke(segment, with: .color(color(at: progress)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let first = curve.samples.first {
                let start = point(first)
                context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
            }
            if let last = curve.samples.last {
                let end = point(last)
                context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(.orange))
            }
        }
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .help("白点 = 起点，橙点 = 终点；线条越暖表示越靠后")
    }

    /// 蓝 → 橙：一眼看出哪一段是开头、哪一段是结尾。
    private func color(at progress: Double) -> Color {
        Color(hue: 0.58 - 0.5 * min(max(progress, 0), 1), saturation: 0.8, brightness: 0.95)
    }
}

/// 速度曲线：横轴是时间，纵轴是瞬时速度。点一下跳到那一刻。
private struct BrollSpeedChart: View {
    let curve: BrollMotionCurve
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard curve.samples.count >= 2 else { return }
                let peak = max(curve.peakSpeed, 0.05)
                let duration = max(curve.sampledDuration, 0.01)
                let startTime = curve.samples.first?.time ?? 0
                func point(_ sample: BrollMotionSample) -> CGPoint {
                    CGPoint(
                        x: CGFloat((sample.time - startTime) / duration) * size.width,
                        y: size.height - CGFloat(min(1, sample.speed / peak)) * (size.height - 8) - 4
                    )
                }
                var line = Path()
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (index, sample) in curve.samples.enumerated() {
                    let position = point(sample)
                    if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                    area.addLine(to: position)
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(.accentColor.opacity(0.18)))
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let fraction = min(max(value.location.x / max(1, geometry.size.width), 0), 1)
                let duration = curve.sampledDuration
                guard duration > 0, let first = curve.samples.first else { return }
                onSeek(first.time + duration * Double(fraction))
            })
        }
        .frame(height: 64)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// 阶段条：横轴是时间，颜色是这一类运动 —— 哪一段是静止、哪一段在加速，一眼看出。
private struct BrollPhaseBar: View {
    let curve: BrollMotionCurve

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(curve.phases) { phase in
                    let ratio = curve.sampledDuration > 0 ? phase.duration / curve.sampledDuration : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BrollMotionStyle.tint(phase.kind).opacity(0.85))
                        .frame(width: max(3, geometry.size.width * CGFloat(ratio)))
                        .help("\(phase.kind.rawValue) · \(BrollProductPick.timecode(phase.start))–\(BrollProductPick.timecode(phase.end))")
                }
            }
        }
        .frame(height: 9)
    }
}

/// 卡片上的速度缩略曲线：不用点开详情就能看出这条是“一直很稳”还是“中间动了一下”。
private struct BrollSpeedSparkline: View {
    let curve: BrollMotionCurve

    var body: some View {
        Canvas { context, size in
            guard curve.samples.count >= 2 else { return }
            let peak = max(curve.peakSpeed, 0.05)
            let duration = max(curve.sampledDuration, 0.01)
            let startTime = curve.samples.first?.time ?? 0
            var line = Path()
            for (index, sample) in curve.samples.enumerated() {
                let position = CGPoint(
                    x: CGFloat((sample.time - startTime) / duration) * size.width,
                    y: size.height - CGFloat(min(1, sample.speed / peak)) * (size.height - 3) - 1.5
                )
                if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
            }
            context.stroke(line, with: .color(.accentColor.opacity(0.85)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
        .help("速度曲线：越高表示镜头动得越快")
    }
}

/// 自适应换行的标签排布：标签宽度不一，HStack 会溢出，Grid 又太规整。
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x = 0.0, y = 0.0, rowHeight = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private func brollClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    return String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}
