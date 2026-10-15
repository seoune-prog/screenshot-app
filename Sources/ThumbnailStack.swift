import AppKit

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    // 살짝 튀었다 자리 잡는 스프링 곡선
    static let spring = CAMediaTimingFunction(controlPoints: 0.32, 1.25, 0.5, 1)
    static let smooth = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
}

/// 화면 왼쪽 아래에 캡처 썸네일을 쌓아 보여준다. 최신 캡처가 가장 아래에 온다.
final class ThumbnailStack {
    var onOpen: ((URL) -> Void)?

    private let panel: NSPanel
    private var views: [ThumbnailView] = []
    private let width: CGFloat = 220
    private let gap: CGFloat = 10
    private let pad: CGFloat = 28
    private let margin: CGFloat = 4
    private var maxVisible: Int { Prefs.maxThumbnails }
    private var onRight: Bool { Prefs.thumbnailCorner == .bottomRight }
    private var screen: NSScreen?

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSView()

        let nc = NotificationCenter.default
        nc.addObserver(forName: Clipboard.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSelection()
        }
        nc.addObserver(forName: CaptureStore.didChange, object: nil, queue: .main) { [weak self] note in
            self?.storeChanged(note.object as? URL)
        }
        nc.addObserver(forName: Prefs.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == "thumbnails", !self.views.isEmpty else { return }
            while self.views.count > self.maxVisible { self.remove(self.views[0], animated: false) }
            guard !self.views.isEmpty else { return }
            self.panel.setFrame(.zero, display: false)
            self.animateLayout(except: nil)
        }
    }

    /// 화면 가장자리 바깥 자리 (썸네일이 들어오고 나가는 곳)
    private func offscreenX(_ view: NSView) -> CGFloat {
        onRight ? width + pad * 2 + 10 : -view.frame.width - pad
    }

    /// flyFrom 을 주면 그 화면 영역에서 썸네일 자리로 캡처가 줄어들며 날아온다.
    func push(_ url: URL, flyFrom source: NSRect? = nil) {
        if views.isEmpty {
            screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
        }
        guard let view = ThumbnailView(url: url, width: width) else { return }
        view.onOpen = { [weak self] in self?.onOpen?(url) }
        view.onCopy = { Clipboard.copy(url) }
        view.onDismiss = { [weak self, weak view] in
            if let view { self?.remove(view) }
        }
        view.onSwipeAway = { [weak self, weak view] in
            if let view { self?.remove(view, slideOut: true) }
        }
        views.append(view)
        while views.count > maxVisible { remove(views[0], animated: false) }
        panel.contentView?.addSubview(view)
        animateLayout(except: view)
        panel.orderFrontRegardless()
        refreshSelection()
        view.startCountdown()

        let target = view.frame.origin
        if let source, !Motion.reduced, let image = NSImage(contentsOf: url) {
            view.alphaValue = 0
            let landing = panel.convertToScreen(view.frame)
            FlyIn.run(image: image, from: source, to: landing) { view.alphaValue = 1 }
        } else if Motion.reduced {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                view.animator().alphaValue = 1
            }
        } else {
            // 화면 가장자리 밖에서 밀려 들어온다
            view.setFrameOrigin(NSPoint(x: offscreenX(view), y: target.y))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = Motion.spring
                view.animator().setFrameOrigin(target)
            }
        }
    }

    private func remove(_ view: ThumbnailView, animated: Bool = true, slideOut: Bool = false) {
        guard let index = views.firstIndex(where: { $0 === view }) else { return }
        views.remove(at: index)
        view.stopCountdown()
        let finish = { [weak self] in
            view.removeFromSuperview()
            guard let self else { return }
            if self.views.isEmpty { self.panel.orderOut(nil) } else { self.animateLayout(except: nil) }
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduced ? 0.15 : 0.3
            ctx.timingFunction = Motion.smooth
            view.animator().alphaValue = 0
            if !Motion.reduced || slideOut {
                view.animator().setFrameOrigin(NSPoint(x: offscreenX(view), y: view.frame.minY))
            }
        }, completionHandler: finish)
    }

    /// 위쪽 썸네일들이 새 자리로 부드럽게 밀려난다. 패널은 아래 기준이라 바로 키운다.
    private func animateLayout(except fresh: ThumbnailView?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let contentHeight = views.reduce(0) { $0 + $1.frame.height } + gap * CGFloat(max(views.count - 1, 0))
        let visible = screen.visibleFrame
        let oldFrame = panel.frame
        let newFrame = NSRect(
            x: onRight ? visible.maxX - margin - width - pad * 2 : visible.minX + margin, y: visible.minY + margin,
            width: width + pad * 2, height: contentHeight + pad * 2
        )
        // 패널 크기가 바뀌면 안의 좌표가 위아래로 튀므로, 화면상 위치를 유지한 채 옮긴다
        let shift = oldFrame.isEmpty ? 0 : oldFrame.minY - newFrame.minY
        panel.setFrame(newFrame, display: false)
        var y = pad
        var targets: [(ThumbnailView, NSPoint)] = []
        for view in views.reversed() {
            targets.append((view, NSPoint(x: pad, y: y)))
            y += view.frame.height + gap
        }
        for (view, point) in targets where view !== fresh {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + shift))
        }
        fresh?.setFrameOrigin(targets.first { $0.0 === fresh }?.1 ?? .zero)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0 : 0.35
            ctx.timingFunction = Motion.smooth
            for (view, point) in targets where view !== fresh {
                view.animator().setFrameOrigin(point)
            }
        }
    }

    private func refreshSelection() {
        for view in views { view.isSelected = Clipboard.isCurrent(view.url) }
    }

    private func storeChanged(_ url: URL?) {
        for view in views {
            if !FileManager.default.fileExists(atPath: view.url.path) {
                remove(view)
            } else if view.url == url {
                view.reloadImage()
            }
        }
    }
}

/// 찍힌 화면이 썸네일 자리로 줄어들며 날아가는 연출
enum FlyIn {
    private static var panels: [NSPanel] = []

    static func run(image: NSImage, from source: NSRect, to landing: NSRect, completion: @escaping () -> Void) {
        let bounds = source.union(landing)
        let panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        view.wantsLayer = true
        panel.contentView = view

        func local(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX - bounds.minX, y: r.minY - bounds.minY, width: r.width, height: r.height)
        }
        let start = local(source), end = local(landing)

        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.3
        shadow.shadowRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        let card = CALayer()
        card.contents = image
        card.contentsGravity = .resizeAspectFill
        card.masksToBounds = true
        card.cornerCurve = .continuous
        card.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        shadow.addSublayer(card)
        view.layer?.addSublayer(shadow)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = end
        card.frame = CGRect(origin: .zero, size: end.size)
        card.cornerRadius = 12
        card.borderWidth = 1
        shadow.shadowPath = CGPath(roundedRect: card.frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()

        panel.orderFrontRegardless()
        panels.append(panel)

        let duration: CFTimeInterval = 0.55
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = Motion.spring
            layer.add(a, forKey: key)
        }
        animate(shadow, "position", from: NSValue(point: NSPoint(x: start.midX, y: start.midY)), to: NSValue(point: NSPoint(x: end.midX, y: end.midY)))
        animate(shadow, "bounds.size", from: NSValue(size: start.size), to: NSValue(size: end.size))
        animate(shadow, "shadowOpacity", from: 0, to: 0.3)
        animate(card, "bounds.size", from: NSValue(size: start.size), to: NSValue(size: end.size))
        animate(card, "position", from: NSValue(point: NSPoint(x: start.width / 2, y: start.height / 2)), to: NSValue(point: NSPoint(x: end.width / 2, y: end.height / 2)))
        animate(card, "cornerRadius", from: 0, to: 12)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            completion()
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }
}

final class ThumbnailView: NSView, NSDraggingSource {
    let url: URL
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSwipeAway: (() -> Void)?

    var isSelected = false { didSet { updateBorder() } }

    private var lifetime: TimeInterval { Prefs.thumbnailSeconds }
    private var remaining: TimeInterval = 10
    private var timer: Timer?
    private var hovering = false { didSet { hoverChanged() } }
    private var mouseDownPoint: NSPoint?
    private var swipeOffset: CGFloat = 0
    private var restX: CGFloat = 0
    private let imageLayer = CALayer()
    private let overlay = PassthroughView()
    private let badge = GlassBox(cornerRadius: 12, overDesktop: true)
    private var copyButton: NSButton?

    init?(url: URL, width: CGFloat) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        self.url = url
        let height = min(max(width * image.size.height / image.size.width, 60), 170)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // 맥 기본 스크린샷 썸네일처럼 이미지 자체를 얇은 테두리와 그림자로 띄운다
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)

        imageLayer.frame = bounds
        imageLayer.cornerRadius = 12
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageLayer.borderWidth = 1
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        imageLayer.contents = image
        layer?.addSublayer(imageLayer)

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: "클립보드")!)
        check.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        check.contentTintColor = .controlAccentColor
        badge.frame = NSRect(x: 8, y: bounds.height - 34, width: 28, height: 28)
        badge.contentView = check
        badge.toolTip = "지금 클립보드"
        addSubview(badge)
        updateBorder()

        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.alphaValue = 0
        addSubview(overlay)

        let copy = makeButton(symbol: "doc.on.doc", tip: "복사", action: #selector(copyClicked))
        let text = makeButton(symbol: "text.viewfinder", tip: "텍스트 복사", action: #selector(textClicked))
        let pin = makeButton(symbol: "pin", tip: "화면에 고정", action: #selector(pinClicked))
        let close = makeButton(symbol: "xmark", tip: "닫기", action: #selector(closeClicked))
        copyButton = copy
        copy.frame = badge.frame
        copy.isHidden = isSelected
        overlay.addSubview(copy)
        for (i, button) in [text, pin, close].enumerated() {
            button.frame.origin = NSPoint(x: bounds.width - 100 + CGFloat(i) * 32, y: bounds.height - 34)
            overlay.addSubview(button)
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        setAccessibilityLabel("캡처 \(EditorWindowController.timeLabel(url))")
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func reloadImage() {
        imageLayer.contents = NSImage(contentsOf: url)
    }

    func startCountdown() {
        remaining = lifetime
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !self.hovering, self.swipeOffset == 0 else { return }
            self.remaining -= 0.25
            if self.remaining <= 0 { self.onDismiss?() }
        }
    }

    func stopCountdown() {
        timer?.invalidate()
        timer = nil
    }

    private func makeButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = FirstMouseButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.applyGlassStyle(circle: true)
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.target = self
        button.action = action
        return button
    }

    private func updateBorder() {
        copyButton?.isHidden = isSelected
        guard isSelected != !badge.isHidden else { return }
        badge.isHidden = !isSelected
        guard isSelected, !Motion.reduced, let layer = badge.layer else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.12, 1]
        pop.keyTimes = [0, 0.6, 1]
        pop.duration = 0.3
        layer.add(pop, forKey: "pop")
    }

    /// 마우스를 올리면 살짝 떠오르고 버튼이 나타난다
    private func hoverChanged() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            overlay.animator().alphaValue = hovering ? 1 : 0
        }
        guard !Motion.reduced, let layer else { return }
        let scale: CGFloat = hovering ? 1.03 : 1
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let a = CABasicAnimation(keyPath: "sublayerTransform")
        a.fromValue = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        a.toValue = t
        a.duration = 0.22
        a.timingFunction = Motion.smooth
        layer.sublayerTransform = t
        layer.add(a, forKey: "hover")
        layer.shadowRadius = hovering ? 18 : 14
        layer.shadowOpacity = hovering ? 0.34 : 0.28
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func textClicked() { TextRecognizer.copyText(from: url) }
    @objc private func pinClicked() {
        PinWindow.pin(url)
        onDismiss?()
    }
    @objc private func closeClicked() { onDismiss?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        remaining = max(remaining, 3)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: ExportName.dragURL(for: url) as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: url))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        onOpen?()
    }

    /// 트랙패드로 왼쪽으로 쓸면 화면 밖으로 치운다 (맥 기본 썸네일과 같은 제스처)
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return super.scrollWheel(with: event) }
        if event.phase == .began {
            restX = frame.minX
            swipeOffset = 0
        }
        if event.phase == .changed || event.phase == .began {
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            // 썸네일이 붙은 쪽 가장자리로만 밀려 나간다
            let edge: CGFloat = Prefs.thumbnailCorner == .bottomRight ? 1 : -1
            swipeOffset = edge < 0 ? min(swipeOffset + dx, 12) : max(swipeOffset + dx, -12)
            setFrameOrigin(NSPoint(x: restX + swipeOffset, y: frame.minY))
            alphaValue = 1 - min(max(swipeOffset * edge, 0) / 200, 0.6)
        }
        if event.phase == .ended || event.phase == .cancelled {
            if swipeOffset * (Prefs.thumbnailCorner == .bottomRight ? 1 : -1) > 50 {
                onSwipeAway?()
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = Motion.spring
                    animator().setFrameOrigin(NSPoint(x: restX, y: frame.minY))
                    animator().alphaValue = 1
                }
            }
            swipeOffset = 0
        }
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
}

/// 끌어다 놓을 때 맥 기본 스크린샷과 같은 이름으로 나가게 한다
enum ExportName {
    static func displayName(for url: URL) -> String {
        let day = url.deletingLastPathComponent().lastPathComponent
        let raw = Array(url.deletingPathExtension().lastPathComponent)
        guard raw.count >= 6, let hour = Int(String(raw[0...1])) else { return "스크린샷 \(day)" }
        let ampm = hour < 12 ? "오전" : "오후"
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "스크린샷 \(day) \(ampm) \(h12).\(String(raw[2...3])).\(String(raw[4...5]))"
    }

    static func dragURL(for url: URL) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapStack/drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(displayName(for: url) + ".png")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.linkItem(at: url, to: dest)
        } catch {
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return url }
        }
        return dest
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
