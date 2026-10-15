import AppKit
import SwiftUI
import Vision

/// 맥에 기본으로 들어 있는 Vision 텍스트 인식. 네트워크나 추가 모델 없이 기기 안에서 돈다.
enum TextRecognizer {
    static func recognize(_ url: URL, completion: @escaping (String) -> Void) {
        run(VNImageRequestHandler(url: url), completion: completion)
    }

    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        run(VNImageRequestHandler(cgImage: image), completion: completion)
    }

    private static func run(_ handler: VNImageRequestHandler, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            try? handler.perform([request])
            // 높이가 겹치는 조각끼리 한 줄로 묶고, 줄은 위에서 아래, 줄 안은 왼쪽에서 오른쪽으로 잇는다
            var rows: [[VNRecognizedTextObservation]] = []
            for o in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
                if let last = rows.last?.first, abs(last.boundingBox.midY - o.boundingBox.midY) < last.boundingBox.height / 2 {
                    rows[rows.count - 1].append(o)
                } else {
                    rows.append([o])
                }
            }
            let lines = rows.map { row in
                row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }
            DispatchQueue.main.async { completion(lines.joined(separator: "\n")) }
        }
    }

    /// 글자를 뽑아 클립보드에 넣고 결과를 알림으로 보여 준다
    /// window 를 주면 알림이 그 창 아래쪽에 붙어 뜬다
    static func copyText(from url: URL, in window: NSWindow? = nil) {
        recognize(url) { deliver($0, in: window) }
    }

    /// 뽑은 글자를 클립보드에 넣고 앞부분을 알림으로 보여 준다
    static func deliver(_ text: String, in window: NSWindow? = nil) {
        guard !text.isEmpty else { return Toast.show("글자 없음", symbol: "text.viewfinder", in: window) }
        Clipboard.copyText(text)
        let preview = text.replacingOccurrences(of: "\n", with: " ")
        Toast.show("텍스트 복사됨 · \(preview.prefix(24))\(preview.count > 24 ? "…" : "")", symbol: "text.viewfinder", in: window)
    }
}

// MARK: 알림

/// 썸네일 자리 근처에 잠깐 뜨는 유리 알림
enum Toast {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?
    private static var token = UUID()

    /// 창에서 한 동작이면 그 창 아래쪽 가운데에, 아니면 썸네일이 뜨는 화면 구석에 띄운다
    static func show(_ message: String, symbol: String, in window: NSWindow? = nil) {
        let host = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        let size = host.fittingSize
        let origin: NSPoint
        if let window, window.isVisible {
            origin = NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.minY + 12)
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let x = Prefs.thumbnailCorner == .bottomRight ? visible.maxX - size.width - 20 : visible.minX + 20
            origin = NSPoint(x: x, y: visible.minY + 20)
        }
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        self.panel = panel
        panel.parent?.removeChildWindow(panel)
        panel.contentView = host
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // 창에 붙여 두면 창을 옮겨도 알림이 따라간다
        if let window, window.isVisible { window.addChildWindow(panel, ordered: .above) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        hide?.cancel()
        let current = UUID()
        token = current
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // 사라지는 도중에 새 알림이 떴으면 그 알림은 남겨 둔다
                if token == current {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
            })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .hudCapsule()
            .padding(12)
    }
}

// MARK: 화면에 고정

/// 캡처를 항상 위에 떠 있는 작은 창으로 띄워 두고 참고한다
final class PinWindow: NSPanel {
    private static var pins: [PinWindow] = []
    private let url: URL
    private let imageLayer = CALayer()
    private let closeButton = NSButton()

    static func pin(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let scale = min(1, visible.width * 0.4 / image.size.width, visible.height * 0.4 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let offset = CGFloat(pins.count % 6) * 24
        let frame = NSRect(x: visible.midX - size.width / 2 + offset, y: visible.midY - size.height / 2 - offset,
                           width: size.width, height: size.height)
        let pin = PinWindow(url: url, image: image, frame: frame)
        pins.append(pin)
        pin.alphaValue = 0
        pin.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            pin.animator().alphaValue = 1
        }
    }

    private init(url: URL, image: NSImage, frame: NSRect) {
        self.url = url
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = image.size
        minSize = NSSize(width: 80, height: 80 * image.size.height / image.size.width)

        let view = PinContentView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = view.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        view.onHover = { [weak self] inside in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self?.closeButton.animator().alphaValue = inside ? 1 : 0
            }
        }
        view.menuProvider = { [weak self] in self?.makeMenu() }

        closeButton.applyGlassStyle(circle: true)
        closeButton.controlSize = .small
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기")
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "닫기 (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.alphaValue = 0
        closeButton.frame = NSRect(x: 8, y: frame.height - 34, width: 26, height: 26)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(closeButton)
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { closePin() }

    @objc private func closePin() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            orderOut(nil)
            Self.pins.removeAll { $0 === self }
        })
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "복사") { [url] in Clipboard.copy(url) })
        menu.addItem(ClosureMenuItem(title: "텍스트 복사") { [weak self, url] in TextRecognizer.copyText(from: url, in: self) })
        menu.addItem(ClosureMenuItem(title: "편집") { [url] in EditorWindowController.open(url) })
        menu.addItem(.separator())
        for value in [100, 75, 50, 25] {
            let item = ClosureMenuItem(title: "불투명도 \(value)%") { [weak self] in self?.alphaValue = CGFloat(value) / 100 }
            item.state = Int((alphaValue * 100).rounded()) == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "닫기") { [weak self] in self?.closePin() })
        return menu
    }
}

private final class PinContentView: NSView {
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    /// 트랙패드를 오므리고 벌려 크기를 바꾼다
    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let factor = 1 + event.magnification
        var frame = window.frame
        let newWidth = max(frame.width * factor, window.minSize.width)
        let newHeight = newWidth * frame.height / frame.width
        frame.origin.x -= (newWidth - frame.width) / 2
        frame.origin.y -= (newHeight - frame.height) / 2
        frame.size = NSSize(width: newWidth, height: newHeight)
        window.setFrame(frame, display: true)
    }
}
