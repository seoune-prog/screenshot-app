import AppKit
import QuickLook
import SwiftUI

/// 기록 목록 썸네일. 원본 대신 작은 미리보기만 디코딩해 메모리에 둔다.
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "snapstack.thumbs", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 800 }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        return await withCheckedContinuation { done in
            queue.async { [cache] in
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                    return done.resume(returning: nil)
                }
                let image = NSImage(cgImage: cg, size: .zero)
                cache.setObject(image, forKey: url as NSURL)
                done.resume(returning: image)
            }
        }
    }

    func invalidate(_ url: URL?) {
        if let url { cache.removeObject(forKey: url as NSURL) } else { cache.removeAllObjects() }
    }
}

struct HourGroup: Identifiable {
    let id: String
    let items: [URL]

    /// 오늘은 "14시", 어제는 "어제 14시", 그 전은 "10월 13일 14시"
    var title: String {
        let parts = id.split(separator: "/")
        guard parts.count == 2 else { return id }
        let day = String(parts[0]), hour = "\(Int(parts[1]) ?? 0)시"
        let today = CaptureStore.dayString(Date())
        let yesterday = CaptureStore.dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        if day == today { return hour }
        if day == yesterday { return "어제 \(hour)" }
        let md = day.split(separator: "-")
        guard md.count == 3 else { return "\(day) \(hour)" }
        return "\(Int(md[1]) ?? 0)월 \(Int(md[2]) ?? 0)일 \(hour)"
    }
}

final class HistoryModel: ObservableObject {
    @Published var groups: [HourGroup] = []
    @Published var count = 0
    @Published var clipboardURL: URL?
    @Published var todayCount = 0
    /// 편집된 캡처마다 올라가는 번호. 같은 주소라도 썸네일을 다시 읽게 한다
    @Published var editStamp: [URL: Int] = [:]

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: CaptureStore.didChange, object: nil, queue: .main) { [weak self] note in
            ThumbCache.shared.invalidate(note.object as? URL)
            if let url = note.object as? URL { self?.editStamp[url, default: 0] += 1 }
            self?.reload()
        }
        nc.addObserver(forName: Clipboard.didChange, object: nil, queue: .main) { [weak self] note in
            self?.clipboardURL = note.object as? URL
        }
        reload()
    }

    func reload() {
        var result: [HourGroup] = []
        var bucket: [URL] = []
        var hour = ""
        for url in CaptureStore.shared.items.reversed() {
            let h = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent.prefix(2)
            if h != hour, !bucket.isEmpty {
                result.append(HourGroup(id: hour, items: bucket))
                bucket = []
            }
            hour = h
            bucket.append(url)
        }
        if !bucket.isEmpty { result.append(HourGroup(id: hour, items: bucket)) }
        groups = result
        count = CaptureStore.shared.items.count
        todayCount = CaptureStore.shared.todayItems.count
    }

    var allItems: [URL] { groups.flatMap(\.items) }
}

struct HistoryActions {
    var captureRegion: () -> Void
    var captureScreen: () -> Void
    var markup: (URL) -> Void
    var clearToday: () -> Void
    var openFolder: () -> Void
    var isLoginItem: () -> Bool
    var setLoginItem: (Bool) -> Void
    var openSettings: () -> Void
    var pin: (URL) -> Void
}

/// 메뉴바 팝오버에 들어가는 기록 창.
final class HistoryHost: NSHostingController<HistoryView> {
    let model: HistoryModel
    let preview: HoverPreview

    init(actions: HistoryActions) {
        let model = HistoryModel()
        let preview = HoverPreview()
        self.model = model
        self.preview = preview
        super.init(rootView: HistoryView(model: model, actions: actions, preview: preview))
        sizingOptions = [.preferredContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    func willShow() {
        CaptureStore.shared.rollIfNeeded()
        model.clipboardURL = CaptureStore.shared.items.last(where: Clipboard.isCurrent)
    }

    func didClose() { preview.hide() }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let actions: HistoryActions
    let preview: HoverPreview

    @State private var selection = Set<URL>()
    @State private var quickLook: URL?
    @State private var toast: String?
    @State private var pendingDelete: [URL] = []
    @State private var loginItem = false
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.count == 0 {
                ContentUnavailableView {
                    Label("캡처 없음", systemImage: "camera.viewfinder")
                } description: {
                    Text(shortcutHint)
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(width: 300, height: 470)
        .quickLookPreview($quickLook, in: orderedSelection.isEmpty ? model.allItems : orderedSelection)
        .confirmationDialog(
            "\(pendingDelete.count)장 삭제",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("삭제", role: .destructive) { commitDelete(pendingDelete) }
        }
        .onAppear { loginItem = actions.isLoginItem() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Prefs.retentionDays > 1 ? "기록" : "오늘").font(.headline)
                Text(toast ?? "\(model.count.formatted())장")
                    .font(.caption)
                    .foregroundStyle(toast == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .contentTransition(.opacity)
            }
            Spacer()
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: actions.captureRegion) {
                        Image(systemName: "rectangle.dashed")
                    }
                    .help("영역 캡처 \(Prefs.regionShortcut?.display ?? "")")

                    Button(action: actions.captureScreen) {
                        Image(systemName: "macwindow")
                    }
                    .help("전체화면 캡처 \(Prefs.screenShortcut?.display ?? "")")

                    Menu {
                        Button("오늘 기록 비우기", role: .destructive, action: actions.clearToday)
                            .disabled(model.todayCount == 0)
                        Button("보관 폴더 열기", action: actions.openFolder)
                        Toggle("로그인 시 실행", isOn: Binding(
                            get: { loginItem },
                            set: { loginItem = $0; actions.setLoginItem($0) }
                        ))
                        Divider()
                        Button("설정…") { actions.openSettings() }
                            .keyboardShortcut(",")
                        Button("SnapStack 종료") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("설정")
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items, id: \.self) { url in
                        CaptureRow(
                            url: url,
                            isCurrent: model.clipboardURL == url,
                            stamp: model.editStamp[url, default: 0],
                            preview: preview,
                            onCopy: { copy(url) },
                            onEdit: { actions.markup(url) },
                            onDelete: { requestDelete([url]) }
                        )
                        .tag(url)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text("\(group.items.count.formatted())장").foregroundStyle(.tertiary)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let first = orderedFirst(urls) {
                Button("복사") { copy(first) }
                Button("편집") { actions.markup(first) }
                Button("텍스트 복사") { TextRecognizer.copyText(from: first, in: NSApp.keyWindow) }
                Button("화면에 고정") { actions.pin(first) }
                Button("미리보기") { quickLook = first }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Divider()
                Button(urls.count > 1 ? "\(urls.count)장 삭제" : "삭제", role: .destructive) {
                    requestDelete(Array(urls))
                }
            }
        } primaryAction: { urls in
            if let first = orderedFirst(urls) { actions.markup(first) }
        }
        .onChange(of: selection) { _, new in
            guard !deleting else { return }
            if new.count == 1, let url = new.first, model.clipboardURL != url { copy(url) }
        }
        .onDeleteCommand { requestDelete(orderedSelection) }
        .onKeyPress(.space) {
            quickLook = quickLook == nil ? orderedSelection.first : nil
            return .handled
        }
    }

    private var shortcutHint: String {
        [Prefs.regionShortcut.map { "\($0.display) 영역" }, Prefs.screenShortcut.map { "\($0.display) 전체화면" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var orderedSelection: [URL] { model.allItems.filter(selection.contains) }

    private func orderedFirst(_ urls: Set<URL>) -> URL? { model.allItems.first(where: urls.contains) }

    private func copy(_ url: URL) {
        Clipboard.copy(url)
        flash("복사됨")
    }

    private func requestDelete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 { commitDelete(urls) } else { pendingDelete = urls }
    }

    private func commitDelete(_ urls: [URL]) {
        preview.hide()
        // 지우고 남은 선택이 클립보드를 덮어쓰지 않게 한다
        deleting = true
        selection.subtract(urls)
        DispatchQueue.main.async { deleting = false }
        pendingDelete = []
        withAnimation(.smooth(duration: 0.25)) { CaptureStore.shared.delete(urls) }
        flash(urls.count > 1 ? "\(urls.count)장 삭제됨" : "삭제됨")
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if toast == text { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
    }
}

struct CaptureRow: View {
    let url: URL
    let isCurrent: Bool
    let stamp: Int
    let preview: HoverPreview
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var anchor = AnchorBox()

    var body: some View {
        HStack(spacing: 10) {
            Thumb(url: url, stamp: stamp)
                .frame(width: 54, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            Text(EditorWindowController.timeLabel(url))
                .font(.body.monospacedDigit())
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("지금 클립보드")
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if hovering {
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                            .help("복사")
                        Button(action: onDelete) { Image(systemName: "trash") }
                            .help("삭제")
                    }
                    .glassButtonStyle()
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(AnchorReader(box: anchor))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            if inside, let rect = anchor.screenRect, let window = anchor.view?.window {
                preview.show(url, beside: window.frame, alignedTo: rect)
            } else if !inside {
                preview.hide()
            }
        }
        .animation(.spring(duration: 0.25), value: isCurrent)
        .onDrag { NSItemProvider(contentsOf: ExportName.dragURL(for: url)) ?? NSItemProvider() }
        // 끌어서 내보내기가 목록 기본 더블클릭을 가로채서, 더블클릭은 줄에서 직접 받는다
        .simultaneousGesture(TapGesture(count: 2).onEnded { onEdit() })
    }
}

struct Thumb: View {
    let url: URL
    var stamp = 0

    private struct Key: Equatable {
        let url: URL
        let stamp: Int
    }
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: Key(url: url, stamp: stamp)) {
            let loaded = await ThumbCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.12)) { image = loaded }
        }
    }
}

/// SwiftUI 줄의 화면 좌표를 얻기 위한 빈 AppKit 뷰
final class AnchorBox {
    weak var view: NSView?
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// 목록 줄에 마우스를 올리면 기록 창 옆에 캡처를 크게 띄운다.
final class HoverPreview {
    private let panel: NSPanel
    private let host = NSHostingView(rootView: PreviewCard(image: nil, size: .zero))
    // 그림자가 잘리지 않도록 패널을 이미지보다 이만큼 크게 잡는다
    private let pad: CGFloat = 30
    private let maxSize = NSSize(width: 440, height: 320)

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
    }

    func show(_ url: URL, beside anchor: NSRect, alignedTo row: NSRect) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return hide() }
        let scale = min(1, maxSize.width / image.size.width, maxSize.height / image.size.height)
        let size = NSSize(width: max(image.size.width * scale, 80), height: max(image.size.height * scale, 60))
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let gap: CGFloat = 10
        var x = anchor.minX - size.width - gap
        if x < screen.minX { x = anchor.maxX + gap }
        let y = min(max(row.midY - size.height / 2, screen.minY + 4), screen.maxY - size.height - 4)
        host.rootView = PreviewCard(image: image, size: size)
        let wasVisible = panel.isVisible
        panel.setFrame(NSRect(x: x - pad, y: y - pad, width: size.width + pad * 2, height: size.height + pad * 2), display: true)
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct PreviewCard: View {
    let image: NSImage?
    let size: NSSize

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
