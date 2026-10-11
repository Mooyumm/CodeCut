import AppKit
import PDFKit
import SwiftUI

/// 文稿工作区：口播之前该先有的东西都放这里。
///
/// 一个项目三份文稿——产品 brief（给本机模型认产品用）、要读的文字稿、分镜稿——
/// 这一页只有文稿本身：不放视频预览，也不放分镜表和时间轴。
/// 分镜制作表和时间轴在「分镜」工作区，画面在「口播」。
struct DocumentsWorkspace: View {
    @Binding var projectSidebarCollapsed: Bool

    var body: some View {
        HSplitView {
            if !projectSidebarCollapsed {
                ProjectSidebar(onCollapse: { projectSidebarCollapsed = true }).frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            }
            DocumentsPanel().frame(minWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 文稿

private enum ScriptTab: String, CaseIterable {
    case brief = "产品 brief"
    case manuscript = "文字稿"
    case storyboard = "分镜稿"

    var icon: String {
        switch self {
        case .brief: "shippingbox"
        case .manuscript: "text.quote"
        case .storyboard: "rectangle.3.group"
        }
    }
}

private struct DocumentsPanel: View {
    @Environment(EditorModel.self) private var model
    @State private var tab = ScriptTab.brief
    /// 左栏 PDF 的缩放指令：每次点按钮换一个 token，让预览知道要动一下。
    @State private var pdfCommand = PDFPreviewCommand(kind: .fitWidth, token: 0)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .brief: briefTab
            case .manuscript: manuscriptTab
            case .storyboard: storyboardTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.082, green: 0.09, blue: 0.098))
        .task { await model.refreshLocalModel() }
        .overlay(alignment: .bottom) {
            if model.projectURL == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("这些文稿是跟着项目走的，先建一个项目再写。")
                    Spacer()
                    Button("新建项目") { model.promptNewProject() }
                }
                .font(.caption).padding(.horizontal, 12).frame(height: 32).background(Color.orange.opacity(0.14))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("文稿", systemImage: "doc.text").font(.headline.weight(.semibold))
            Text(model.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Picker("文稿", selection: $tab) {
                ForEach(ScriptTab.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 288)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(Color(red: 0.105, green: 0.115, blue: 0.125))
    }

    // MARK: - 产品 brief

    private var briefTab: some View {
        HSplitView {
            briefFilePane.frame(minWidth: 300, idealWidth: 540)
            briefReadPane.frame(minWidth: 320, idealWidth: 430)
        }
    }

    // MARK: 左栏：原文件

    /// 左栏放 brief 的原文件本身：PDF 直接看，Word / PPT / 图片是本机排出来的预览。
    /// 能上下滚、能放大 —— 想核哪一句原文就在这一栏核。
    private var briefFilePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: briefFormat.symbol).font(.caption).foregroundStyle(.secondary)
                Text(briefFileName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if model.productProfile.briefPath != nil {
                    Text(briefFormat.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                Spacer(minLength: 4)
                if model.briefPreviewURL != nil {
                    Button { zoom(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                    Button { zoom(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                    Button { zoom(.fitWidth) } label: { Image(systemName: "arrow.left.and.right") }.help("适应宽度")
                    Button {
                        if let url = model.briefPreviewURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: { Image(systemName: "folder") }.help("在访达里显示")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).frame(height: 40)
            .background(Color(red: 0.105, green: 0.115, blue: 0.125))
            Divider()
            if let url = model.briefPreviewURL {
                BriefPDFPreview(url: url, command: pdfCommand)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("这一栏看 brief 的原文件").font(.callout)
                    Text("PDF、Word、PPT、图片、纯文本都能读。原文件就摆在这里，上下滚、放大看。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                    Button("读 brief", systemImage: "doc.text.magnifyingglass") { model.promptProductBrief() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isAnalyzingBrollProduct || model.isPreparingLocalModel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.22))
    }

    // MARK: 右栏：本机模型的阅读

    /// 右栏放本机模型的阅读结果：这是什么产品、长什么样、从 brief 里提出来的产品照片。
    private var briefReadPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("本机的阅读").font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Label(model.localModelState.label, systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("读 brief", systemImage: "doc.text.magnifyingglass") { model.promptProductBrief() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isAnalyzingBrollProduct || model.isPreparingLocalModel)
                    if model.productProfile.briefPath != nil {
                        Button("重新读", systemImage: "arrow.clockwise") { model.promptProductBrief() }
                            .disabled(model.isAnalyzingBrollProduct || model.isPreparingLocalModel)
                    }
                    Button("加照片", systemImage: "photo.badge.plus") { model.promptProductReferenceImages() }
                    Spacer(minLength: 0)
                }
                if let progress = model.brollProductProgress, !model.brollProductNotice.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        Text(model.brollProductNotice).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                if model.productProfile.isConfigured {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这是什么产品").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(model.productProfile.name).font(.title3.weight(.semibold))
                        if !model.productProfile.summary.isEmpty {
                            Text(model.productProfile.summary).font(.callout)
                        }
                        if !model.productProfile.features.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("要认出来的特征").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ChipFlow(spacing: 6) { ForEach(model.productProfile.features, id: \.self) { Chip(text: $0) } }
                            }
                        }
                        if !model.productProfile.avoid.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("不要误判成").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ChipFlow(spacing: 6) { ForEach(model.productProfile.avoid, id: \.self) { Chip(text: $0, tint: .orange) } }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有产品档案").font(.callout.weight(.semibold))
                        Text("点“读 brief”，选品牌方给的那份文件 —— PDF、Word、PPT、图片、纯文本都行。本机会读完它，在这一栏写清产品是什么、长什么样，并把里边的产品照片提出来。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !model.productProfile.referenceImages.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("从 brief 里提出来的产品照片 \(model.productProfile.referenceImages.count) 张")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(model.productProfile.referenceImages) { reference in
                                ProductPhotoCard(reference: reference)
                            }
                        }
                        Text("点照片看原图。这些照片也会作为参考图，给挑 B-roll 的本地模型看。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if let path = model.productProfile.briefPath {
                    Divider()
                    Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var briefFormat: BriefFormat {
        guard let path = model.productProfile.briefPath else { return .pdf }
        return BriefFormat(url: URL(fileURLWithPath: path))
    }

    private var briefFileName: String {
        guard let path = model.productProfile.briefPath else { return "还没有 brief" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func zoom(_ kind: PDFPreviewCommand.Kind) {
        pdfCommand = PDFPreviewCommand(kind: kind, token: pdfCommand.token + 1)
    }

    // MARK: - 文字稿

    private var manuscriptTab: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("要读的文字稿").font(.callout.weight(.semibold))
                Text("\(model.manuscript.count) 字").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("粘贴") { if let text = NSPasteboard.general.string(forType: .string) { model.updateManuscript(text) } }
                Button("清空", role: .destructive) { model.updateManuscript("") }
                    .disabled(model.manuscript.isEmpty)
                Button("审阅") { Task { await model.reviewManuscript() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.words.isEmpty || model.isWorking)
                    .help(model.words.isEmpty ? "先导入素材、识别出文字稿之后再审阅。" : "拿这份文字稿去校对识别出来的字幕。")
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            TextEditor(text: $model.manuscript)
                .font(.system(size: 16)).scrollContentBackground(.hidden).padding(10)
                .overlay(alignment: .topLeading) {
                    if model.manuscript.isEmpty {
                        Text("把这次要读的文字稿贴在这里。识别完之后点“审阅”，本机会拿它校对字幕，标出念错、念漏的地方。")
                            .foregroundStyle(.tertiary).padding(16).frame(maxWidth: 420, alignment: .leading).allowsHitTesting(false)
                    }
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
        }
    }

    // MARK: - 分镜稿

    private var storyboardTab: some View {
        ScriptTablePanel()
    }
}

// MARK: - 分镜稿表格

/// 分镜稿表格：导入 CSV，直接在格子里改内容，拖表头右侧调列宽、拖行底边调行高。
///
/// 文稿页和分镜页共用这一个视图，读写的都是 `model.scriptTable`，
/// 所以「分镜页的分镜」和「文稿页的分镜稿」是同一份数据，改哪边都同步。
struct ScriptTablePanel: View {
    @Environment(EditorModel.self) private var model
    /// 拖动中的列／行基线：拖动开始记一次基准值，之后按位移改，避免每帧累加漂移。
    @State private var columnDrag: (column: Int, base: Double)?
    @State private var rowDrag: (row: Int, base: Double)?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.scriptTable.isEmpty {
                emptyState
            } else {
                table
            }
        }
        // 口播或剪辑变了就自动补一次时间；用户自己写的时间列不覆盖。
        .task(id: "\(model.scriptVoiceFingerprint)-\(model.scriptTable.rowCount)x\(model.scriptTable.columnCount)") {
            await model.autoMatchScriptTimesIfNeeded()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("分镜稿").font(.callout.weight(.semibold))
            if !model.scriptTable.isEmpty {
                Text("\(model.scriptTable.rowCount) 行 × \(model.scriptTable.columnCount) 列")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("匹配口播时间", systemImage: "clock.badge.checkmark") { Task { await model.matchScriptTableTimes() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.scriptTable.isEmpty || model.words.isEmpty || model.isWorking)
                .help("一键按「文稿」列逐行对口播时间，写进「文稿」右边的「时间」列；口播里没有的行留空。全部在本机完成，不联网。")
            Button("导入 CSV", systemImage: "square.and.arrow.down") { model.promptImportScriptTable() }
            Button("导出 CSV", systemImage: "square.and.arrow.up") { model.exportScriptTable() }
                .disabled(model.scriptTable.isEmpty)
            Menu {
                Button("在末尾加一行", systemImage: "plus") { model.addScriptRow() }
                Button("加一列", systemImage: "plus.rectangle.on.rectangle") { model.addScriptColumn() }
            } label: {
                Label("编辑表格", systemImage: "tablecells")
            }
            .disabled(model.scriptTable.isEmpty)
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Color(red: 0.105, green: 0.115, blue: 0.125))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有分镜稿", systemImage: "tablecells")
        } description: {
            Text("导入分镜稿的 CSV（第一行当表头）。导入后点「匹配口播时间」，就能按「文稿」这一列把口播时间逐行对出来；口播里没有的行留空。也可以直接在表格里改内容、拖表头调列宽、拖行底边调行高，改完还能导出成 CSV。")
        } actions: {
            Button("导入分镜稿 CSV") { model.promptImportScriptTable() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(model.scriptTable.rows.indices, id: \.self) { row in
                    dataRow(row)
                }
                addRowButton
            }
            .padding(10)
        }
        .background(Color(red: 0.075, green: 0.085, blue: 0.098))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 34, height: ScriptTable.defaultRowHeight, alignment: .center)
            ForEach(0..<model.scriptTable.columnCount, id: \.self) { column in
                headerCell(column)
            }
        }
    }

    private func headerCell(_ column: Int) -> some View {
        let width = model.scriptTable.width(column)
        return TextField("列名", text: Binding(
            get: { model.scriptTable.header(column) },
            set: { model.updateScriptHeader(column: column, text: $0) }
        ))
        .textFieldStyle(.plain)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .frame(width: width, height: ScriptTable.defaultRowHeight, alignment: .leading)
        .background(Color.white.opacity(0.07))
        .overlay(Rectangle().fill(.white.opacity(0.12)).frame(width: 1).frame(maxWidth: .infinity, alignment: .leading))
        .overlay(alignment: .trailing) { columnHandle(column, width: width) }
        .contextMenu {
            Button("在这列右侧加一列", systemImage: "plus.rectangle.on.rectangle") { model.insertScriptColumn(after: column) }
            Button("删除这一列", systemImage: "trash", role: .destructive) { model.removeScriptColumn(column) }
                .disabled(model.scriptTable.columnCount <= 1)
        }
    }

    /// 列宽拖动手柄：贴在本列右边缘上。
    private func columnHandle(_ column: Int, width: Double) -> some View {
        Rectangle()
            .fill(columnDrag?.column == column ? Color.accentColor : Color.white.opacity(0.14))
            .frame(width: 5)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = columnDrag?.column == column ? (columnDrag?.base ?? width) : width
                        if columnDrag?.column != column { columnDrag = (column, base) }
                        model.setScriptColumnWidth(base + value.translation.width, at: column)
                    }
                    .onEnded { _ in columnDrag = nil; model.commitScriptTable() }
            )
            .help("拖动调整这一列的宽度")
    }

    private func dataRow(_ row: Int) -> some View {
        let height = model.scriptTable.height(row)
        return HStack(spacing: 0) {
            Text("\(row + 1)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, height: height, alignment: .center)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("在这一行下面插入一行", systemImage: "plus") { model.addScriptRow(after: row) }
                    Button("删除这一行", systemImage: "trash", role: .destructive) { model.removeScriptRow(row) }
                }
            ForEach(0..<model.scriptTable.columnCount, id: \.self) { column in
                cell(row: row, column: column, height: height)
            }
        }
        .overlay(alignment: .bottom) { rowHandle(row, height: height) }
    }

    private func cell(row: Int, column: Int, height: Double) -> some View {
        TextField("", text: Binding(
            get: { model.scriptTable.cell(row, column) },
            set: { model.updateScriptCell(row: row, column: column, text: $0) }
        ), axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .lineLimit(1...20)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(width: model.scriptTable.width(column), height: height, alignment: .topLeading)
        .background(row % 2 == 0 ? Color.white.opacity(0.02) : Color.clear)
        .overlay(Rectangle().fill(.white.opacity(0.07)).frame(width: 1).frame(maxWidth: .infinity, alignment: .leading))
        .overlay(Rectangle().fill(.white.opacity(0.07)).frame(height: 1).frame(maxHeight: .infinity, alignment: .top))
        .contextMenu {
            Button("在这一行下面插入一行", systemImage: "plus") { model.addScriptRow(after: row) }
            Button("删除这一行", systemImage: "trash", role: .destructive) { model.removeScriptRow(row) }
        }
    }

    /// 行高拖动手柄：贴在整行底边上。
    private func rowHandle(_ row: Int, height: Double) -> some View {
        Rectangle()
            .fill(rowDrag?.row == row ? Color.accentColor : Color.clear)
            .frame(height: 5)
            .contentShape(Rectangle().inset(by: -2))
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = rowDrag?.row == row ? (rowDrag?.base ?? height) : height
                        if rowDrag?.row != row { rowDrag = (row, base) }
                        model.setScriptRowHeight(base + value.translation.height, at: row)
                    }
                    .onEnded { _ in rowDrag = nil; model.commitScriptTable() }
            )
            .help("拖动调整这一行的高度")
    }

    private var addRowButton: some View {
        Button {
            model.addScriptRow()
        } label: {
            Label("加一行", systemImage: "plus")
                .font(.caption)
                .frame(width: 160, height: 30, alignment: .center)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.leading, 34).padding(.top, 6)
    }
}

/// 左栏 PDF 预览的缩放指令。带 token 是为了连点两次“放大”也能生效。
struct PDFPreviewCommand: Equatable {
    enum Kind: Equatable {
        case zoomIn
        case zoomOut
        case fitWidth
    }

    var kind: Kind = .fitWidth
    var token: Int = 0
}

/// 左栏的 PDF 预览：纵向连续翻页，滚动条上下拖动，缩放按钮单独控制。
private struct BriefPDFPreview: NSViewRepresentable {
    let url: URL
    var command: PDFPreviewCommand

    final class Coordinator {
        var url: URL?
        var command = PDFPreviewCommand()
        var didFit = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = false
        view.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.066, blue: 0.072, alpha: 1)
        view.document = PDFDocument(url: url)
        context.coordinator.url = url
        context.coordinator.command = command
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.url != url {
            view.document = PDFDocument(url: url)
            coordinator.url = url
            coordinator.didFit = false
        }
        // 首次拿到真实宽度后再铺满，makeNSView 那会儿 bounds 还是 0。
        if !coordinator.didFit, view.bounds.width > 40 {
            Self.fitWidth(view)
            coordinator.didFit = true
        }
        guard coordinator.command.token != command.token else { return }
        coordinator.command = command
        switch command.kind {
        case .zoomIn:
            // autoScales 会在每次布局时把缩放比压回去，所以手动缩放前先关掉它。
            view.autoScales = false
            view.scaleFactor = min(view.scaleFactor * 1.25, 8)
        case .zoomOut:
            view.autoScales = false
            view.scaleFactor = max(view.scaleFactor / 1.25, 0.1)
        case .fitWidth:
            Self.fitWidth(view)
        }
    }

    /// 按栏宽铺满页面宽度 —— 读 brief 的文字时比「整页塞进来」清楚得多。
    private static func fitWidth(_ view: PDFView) {
        view.autoScales = false
        guard let page = view.currentPage ?? view.document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: view.displayBox).width
        let available = view.bounds.width - 20
        guard pageWidth > 0, available > 0 else { return }
        view.scaleFactor = max(0.1, min(available / pageWidth, 8))
    }
}

/// 右栏里的一张产品照片：点开看原图，也可以从档案里删掉。
private struct ProductPhotoCard: View {
    @Environment(EditorModel.self) private var model
    let reference: ProductReferenceImage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.productReferenceThumbnails[reference.id] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black.opacity(0.35).overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: reference.path)) }
                Button { model.removeProductReference(reference.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(3)
            }
            Text(reference.caption.isEmpty ? URL(fileURLWithPath: reference.path).lastPathComponent : reference.caption)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(reference.path)
        .task(id: reference.id) { await model.ensureReferenceThumbnail(reference.id) }
    }
}

/// 产品参考图缩略图：文稿页和 B-roll 页共用。
struct ProductReferenceThumb: View {
    @Environment(EditorModel.self) private var model
    let reference: ProductReferenceImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = model.productReferenceThumbnails[reference.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 96, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Button { model.removeProductReference(reference.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain).padding(2)
        }
        .help(reference.caption.isEmpty ? reference.path : reference.caption)
        .task(id: reference.id) { await model.ensureReferenceThumbnail(reference.id) }
    }
}
