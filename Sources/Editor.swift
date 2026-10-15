import AppKit

enum Tool: Int, CaseIterable {
    case rect, arrow, pen, text, highlight, counter, spotlight, mosaic, ocr

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .counter: return "1.circle"
        case .spotlight: return "flashlight.on.fill"
        case .mosaic: return "checkerboard.rectangle"
        case .ocr: return "text.viewfinder"
        }
    }

    var label: String {
        switch self {
        case .rect: return "박스 (R)"
        case .arrow: return "화살표 (A)"
        case .pen: return "펜 (P)"
        case .text: return "텍스트 (T)"
        case .highlight: return "형광펜 (H)"
        case .counter: return "번호 (N)"
        case .spotlight: return "스포트라이트 (F)"
        case .mosaic: return "모자이크 (M)"
        case .ocr: return "영역 텍스트 복사 (O)"
        }
    }

    /// 색을 쓰는 도구인지. 아니면 색 선택을 흐리게 한다
    var usesColor: Bool { Tool.drawing.contains(self) }

    static let drawing: [Tool] = [.rect, .arrow, .pen, .text, .highlight, .counter]
    static let masking: [Tool] = [.spotlight, .mosaic]
    static let reading: [Tool] = [.ocr]

    var key: String {
        switch self {
        case .rect: return "r"
        case .arrow: return "a"
        case .pen: return "p"
        case .text: return "t"
        case .highlight: return "h"
        case .counter: return "n"
        case .spotlight: return "f"
        case .mosaic: return "m"
        case .ocr: return "o"
        }
    }
}

struct Mark {
    enum Kind {
        case rect(CGRect)
        case arrow(CGPoint, CGPoint)
        case pen([CGPoint])
        case text(CGPoint, String)
        case highlight(CGRect)
        case mosaic(CGRect)
        case counter(CGPoint, Int)
        case spotlight(CGRect)
        // 글자를 뽑을 영역. 끄는 동안에만 보이고 결과물에는 남지 않는다
        case ocrSelect(CGRect)
    }
    var kind: Kind
    var color: NSColor
}

/// 원본 이미지 위에 주석을 그린다. 좌표는 모두 이미지 포인트 기준이다.
enum Renderer {
    static let lineWidth: CGFloat = 4
    static let fontSize: CGFloat = 22

    static func textAttributes(_ color: NSColor, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = (color.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        return [
            .font: NSFont.systemFont(ofSize: fontSize * scale, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    static func draw(base: CGImage, size: NSSize, marks: [Mark], in ctx: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = previous }

        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(origin: .zero, size: size))
        // 모자이크는 이미지의 일부라 스포트라이트보다 먼저 깔아야 같이 어두워진다
        for mark in marks {
            if case .mosaic(let r) = mark.kind { drawMosaic(base: base, size: size, rect: r.standardized, in: ctx) }
        }
        drawSpotlights(marks, size: size, in: ctx)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for mark in marks {
            ctx.saveGState()
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setFillColor(mark.color.cgColor)
            ctx.setLineWidth(lineWidth)
            switch mark.kind {
            case .rect(let r):
                ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.strokePath()
            case .arrow(let a, let b):
                drawArrow(from: a, to: b, in: ctx)
            case .pen(let points):
                guard let first = points.first else { break }
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            case .text(let p, let string):
                (string as NSString).draw(at: p, withAttributes: textAttributes(mark.color))
            case .highlight(let r):
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(mark.color.withAlphaComponent(0.4).cgColor)
                ctx.fill(r.standardized)
            case .mosaic:
                break
            case .counter(let p, let n):
                drawCounter(n, at: p, color: mark.color, in: ctx)
            case .spotlight:
                break
            case .ocrSelect(let r):
                let box = r.standardized
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                ctx.fill(box)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(box)
            }
            ctx.restoreGState()
        }
    }

    /// 스포트라이트 영역 전부를 구멍으로 남기고 나머지를 한 번에 어둡게 한다
    private static func drawSpotlights(_ marks: [Mark], size: NSSize, in ctx: CGContext) {
        let holes = marks.compactMap { mark -> CGRect? in
            if case .spotlight(let r) = mark.kind { return r.standardized } else { return nil }
        }
        guard !holes.isEmpty else { return }
        // 어둡게 깐 층에서 구멍만 지워 내야 겹친 스포트라이트도 밝게 남는다
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.clear)
        for r in holes {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static let counterRadius: CGFloat = 15

    private static func drawCounter(_ n: Int, at p: CGPoint, color: NSColor, in ctx: CGContext) {
        let r = counterRadius
        let circle = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        let text = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: n > 9 ? 13 : 15, weight: .bold),
            .foregroundColor: color.isDark ? NSColor.white : NSColor.black,
        ]
        let s = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: p.x - s.width / 2, y: p.y - s.height / 2), withAttributes: attrs)
    }

    private static func drawArrow(from a: CGPoint, to b: CGPoint, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = hypot(b.x - a.x, b.y - a.y)
        let head = min(lineWidth * 5, length * 0.6)
        let spread: CGFloat = .pi / 7
        let neck = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
        ctx.move(to: a)
        ctx.addLine(to: neck)
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - cos(angle - spread) * head, y: b.y - sin(angle - spread) * head))
        ctx.addLine(to: CGPoint(x: b.x - cos(angle + spread) * head, y: b.y - sin(angle + spread) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawMosaic(base: CGImage, size: NSSize, rect: CGRect, in ctx: CGContext) {
        let sx = CGFloat(base.width) / size.width
        let sy = CGFloat(base.height) / size.height
        // CGImage 자르기는 왼쪽 위가 원점이라 y를 뒤집는다
        let crop = CGRect(
            x: rect.minX * sx, y: CGFloat(base.height) - rect.maxY * sy,
            width: rect.width * sx, height: rect.height * sy
        ).integral
        guard crop.width >= 1, crop.height >= 1, let piece = base.cropping(to: crop) else { return }
        let block: CGFloat = 10
        let w = max(1, Int(rect.width / block)), h = max(1, Int(rect.height / block))
        guard let small = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        small.interpolationQuality = .medium
        small.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixelated = small.makeImage() else { return }
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: CGRect(
            x: rect.minX, y: rect.minY,
            width: crop.width / sx, height: crop.height / sy
        ))
    }
}

extension NSColor {
    var isDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
}

final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    let base: CGImage
    let size: NSSize
    var tool: Tool = .rect { didSet { onToolChange?(tool) } }
    var color: NSColor = .systemRed
    var onToolChange: ((Tool) -> Void)?
    private(set) var marks: [Mark] = []
    private(set) var isDirty = false
    private var draft: Mark?
    private var start: CGPoint = .zero
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero

    init(base: CGImage, size: NSSize) {
        self.base = base
        self.size = size
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 그림을 그리는 영역을 끌어도 창이 따라 움직이지 않게 한다
    override var mouseDownCanMoveWindow: Bool { false }

    private var area: CGRect { bounds.insetBy(dx: 24, dy: 20) }

    private var scale: CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(area.width / size.width, area.height / size.height, 1)
    }

    private var imageRect: CGRect {
        let s = scale
        let w = size.width * s, h = size.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    private func toImage(_ p: NSPoint) -> CGPoint {
        let r = imageRect, s = scale
        let x = min(max((p.x - r.minX) / s, 0), size.width)
        let y = min(max((p.y - r.minY) / s, 0), size.height)
        return CGPoint(x: x, y: y)
    }

    private func toView(_ p: CGPoint) -> NSPoint {
        let r = imageRect, s = scale
        return NSPoint(x: r.minX + p.x * s, y: r.minY + p.y * s)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        let rounded = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(rounded)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        Renderer.draw(base: base, size: size, marks: marks + (draft.map { [$0] } ?? []), in: ctx)
        ctx.restoreGState()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        commitText()
    }

    // MARK: 마우스

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = toImage(convert(event.locationInWindow, from: nil))
        start = p
        switch tool {
        case .text: beginText(at: p)
        case .rect: draft = Mark(kind: .rect(CGRect(origin: p, size: .zero)), color: color)
        case .arrow: draft = Mark(kind: .arrow(p, p), color: color)
        case .pen: draft = Mark(kind: .pen([p]), color: color)
        case .highlight: draft = Mark(kind: .highlight(CGRect(origin: p, size: .zero)), color: color)
        case .mosaic: draft = Mark(kind: .mosaic(CGRect(origin: p, size: .zero)), color: color)
        case .spotlight: draft = Mark(kind: .spotlight(CGRect(origin: p, size: .zero)), color: color)
        case .ocr: draft = Mark(kind: .ocrSelect(CGRect(origin: p, size: .zero)), color: color)
        case .counter:
            let next = marks.filter { if case .counter = $0.kind { return true } else { return false } }.count + 1
            append(Mark(kind: .counter(p, next), color: color))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var mark = draft else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        let box = CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y)
        switch mark.kind {
        case .rect: mark.kind = .rect(box)
        case .highlight: mark.kind = .highlight(box)
        case .mosaic: mark.kind = .mosaic(box)
        case .spotlight: mark.kind = .spotlight(box)
        case .ocrSelect: mark.kind = .ocrSelect(box)
        case .counter: break
        case .arrow: mark.kind = .arrow(start, p)
        case .pen(let points): mark.kind = .pen(points + [p])
        case .text: break
        }
        draft = mark
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let mark = draft else { return }
        draft = nil
        if case .ocrSelect(let r) = mark.kind {
            needsDisplay = true
            if abs(r.width) > 3, abs(r.height) > 3 { copyText(in: r.standardized) }
            return
        }
        if isMeaningful(mark) { append(mark) } else { needsDisplay = true }
    }

    private func isMeaningful(_ mark: Mark) -> Bool {
        switch mark.kind {
        case .rect(let r), .highlight(let r), .mosaic(let r), .spotlight(let r):
            return abs(r.width) > 3 && abs(r.height) > 3
        case .counter: return true
        case .ocrSelect: return false
        case .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) > 6
        case .pen(let points): return points.count > 1
        case .text(_, let s): return !s.isEmpty
        }
    }

    /// 고른 영역만 잘라 글자를 뽑아 클립보드에 넣는다 (좌표는 이미지 포인트)
    func copyText(in rect: CGRect, deliver: Bool = true, completion: ((String) -> Void)? = nil) {
        let sx = CGFloat(base.width) / size.width, sy = CGFloat(base.height) / size.height
        // CGImage 자르기는 왼쪽 위가 원점이라 y를 뒤집는다
        let crop = CGRect(x: rect.minX * sx, y: CGFloat(base.height) - rect.maxY * sy,
                          width: rect.width * sx, height: rect.height * sy).integral
        guard let piece = base.cropping(to: crop) else { return }
        TextRecognizer.recognize(piece) { text in
            completion?(text)
            if deliver { TextRecognizer.deliver(text, in: self.window) }
        }
    }

    // MARK: 실행 취소

    func append(_ mark: Mark) {
        marks.append(mark)
        undoManager?.registerUndo(withTarget: self) { $0.removeLastMark() }
        changed()
    }

    func removeLastMark() {
        guard let mark = marks.popLast() else { return }
        undoManager?.registerUndo(withTarget: self) { $0.append(mark) }
        changed()
    }

    func markSaved() { isDirty = false }

    private func changed() {
        isDirty = true
        needsDisplay = true
    }

    // MARK: 텍스트

    private func beginText(at p: CGPoint) {
        let s = scale
        let font = NSFont.systemFont(ofSize: Renderer.fontSize * s, weight: .bold)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let field = NSTextField(frame: .zero)
        field.font = font
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "텍스트"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        // 클릭한 지점을 글자 줄 가운데에 맞춘다
        textOrigin = CGPoint(x: p.x, y: p.y - (lineHeight / s) / 2)
        let v = toView(textOrigin)
        field.frame = NSRect(x: v.x - 2, y: v.y, width: max(200, bounds.width - v.x), height: lineHeight + 2)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue
        let fieldColor = field.textColor ?? color
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !string.isEmpty { append(Mark(kind: .text(textOrigin, string), color: fieldColor)) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) || selector == #selector(cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    // MARK: 키보드

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.performClose(nil)
            return
        }
        // Caps Lock·한글 입력 상태와 상관없이 키 위치로 도구를 고른다
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, let t = Tool.allCases.first(where: { Shortcut.keyName(Int(event.keyCode)) == $0.key.uppercased() }) {
            tool = t
            return
        }
        super.keyDown(with: event)
    }

    // MARK: 내보내기

    func renderPNG() -> Data? {
        commitText()
        let space = base.colorSpace?.supportsOutput == true ? base.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: CGFloat(base.width) / size.width, y: CGFloat(base.height) / size.height)
        Renderer.draw(base: base, size: size, marks: marks, in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [URL: EditorWindowController] = [:]

    static func open(_ url: URL) {
        let controller = openEditors[url] ?? EditorWindowController(url: url)
        guard let controller else { return }
        openEditors[url] = controller
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        // 비활성 메뉴바 앱이라 창을 강제로 앞에 띄워야 다른 앱 뒤에 숨지 않는다
        controller.window?.orderFrontRegardless()
        controller.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func qaSetTool(_ url: URL, key: String) {
        openEditors[url]?.canvas.tool = Tool.allCases.first { $0.key == key } ?? .rect
        if ProcessInfo.processInfo.environment["SNAPSTACK_QA_TOAST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Toast.show("텍스트 복사됨 · Total cost: $1,234.56", symbol: "text.viewfinder", in: openEditors[url]?.window)
            }
        }
    }

    /// 개발용 점검: 시험 이미지의 가운데 줄 영역만 글자를 뽑는다
    static func qaCropOCR(_ url: URL) {
        guard let c = openEditors[url]?.canvas else { return }
        c.copyText(in: CGRect(x: 20, y: 95, width: 600, height: 60), deliver: false) { Log.write("QA ocrcrop: \($0)") }
    }

    /// 개발용 점검: 새 도구를 포함해 주석을 그리고 내보낸 결과를 파일로 남긴다
    static func qaAnnotate(_ url: URL, out: URL) {
        open(url)
        guard let c = openEditors[url]?.canvas else { return }
        c.append(Mark(kind: .spotlight(CGRect(x: 40, y: 260, width: 360, height: 140)), color: .systemRed))
        c.append(Mark(kind: .spotlight(CGRect(x: 300, y: 300, width: 260, height: 160)), color: .systemRed))
        for (i, p) in [CGPoint(x: 60, y: 420), CGPoint(x: 300, y: 330), CGPoint(x: 520, y: 200)].enumerated() {
            c.append(Mark(kind: .counter(p, i + 1), color: i == 1 ? .systemYellow : .systemRed))
        }
        c.append(Mark(kind: .mosaic(CGRect(x: 600, y: 60, width: 220, height: 100)), color: .black))
        c.append(Mark(kind: .rect(CGRect(x: 40, y: 260, width: 360, height: 140)), color: .systemRed))
        try? c.renderPNG()?.write(to: out)
        Log.write("QA editor: marks=\(c.marks.count) exported=\(FileManager.default.fileExists(atPath: out.path))")
    }

    /// 테스트용: 박스 하나를 그리고 실제 ⌘S 키 이벤트를 메뉴로 보내 저장 경로를 확인한다
    static func demoSave(_ url: URL) {
        guard let controller = openEditors[url], let window = controller.window else { return }
        controller.canvas.append(Mark(kind: .rect(CGRect(x: 20, y: 20, width: 200, height: 80)), color: .systemRed))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "s",
                                           charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) else { return }
            Log.write("demo ⌘S handled=\(NSApp.mainMenu?.performKeyEquivalent(with: e) == true)")
        }
    }

    /// 앱을 끄기 전에 저장하지 않은 편집 창마다 저장 여부를 묻는다. 하나라도 취소하면 false
    static func confirmCloseAll() -> Bool {
        for controller in Array(openEditors.values) {
            guard let window = controller.window else { continue }
            guard controller.windowShouldClose(window) else { return false }
            controller.canvas.markSaved()
        }
        return true
    }

    let url: URL
    let canvas: AnnotationCanvas
    // 도구를 쓰임새별로 세 묶음에 나눠 담는다. 한 묶음을 고르면 나머지 묶음은 선택이 풀린다
    private let toolGroups: [(picker: NSSegmentedControl, tools: [Tool])] = [
        (NSSegmentedControl(), Tool.drawing), (NSSegmentedControl(), Tool.masking), (NSSegmentedControl(), Tool.reading),
    ]
    private let colorPicker = NSSegmentedControl()
    static let palette: [(String, NSColor)] = [
        ("빨강", .systemRed), ("노랑", .systemYellow), ("초록", .systemGreen),
        ("파랑", .systemBlue), ("검정", .black), ("흰색", .white),
    ]

    private init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage else { return nil }
        self.url = url
        canvas = AnnotationCanvas(base: cg, size: rep.size)

        let toolbarHeight: CGFloat = 60
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let fit = min(1, (visible.width * 0.85 - 48) / rep.size.width, (visible.height * 0.85 - toolbarHeight - 40) / rep.size.height)
        let contentSize = NSSize(
            width: max(rep.size.width * fit + 48, 920),
            height: max(rep.size.height * fit, 200) + toolbarHeight + 40
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = ExportName.displayName(for: url)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 300)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window, toolbarHeight: toolbarHeight)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func timeLabel(_ url: URL) -> String {
        let n = url.deletingPathExtension().lastPathComponent
        guard n.count >= 6 else { return n }
        let c = Array(n)
        return "\(c[0])\(c[1]):\(c[2])\(c[3]):\(c[4])\(c[5])"
    }

    private func buildContent(in window: NSWindow, toolbarHeight: CGFloat) {
        for (picker, tools) in toolGroups {
            picker.segmentCount = tools.count
            picker.trackingMode = .selectOne
            picker.segmentStyle = .separated
            for (i, t) in tools.enumerated() {
                picker.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.label), forSegment: i)
                picker.setToolTip(t.label, forSegment: i)
                picker.setWidth(32, forSegment: i)
            }
            picker.target = self
            picker.action = #selector(toolChanged(_:))
        }
        canvas.onToolChange = { [weak self] t in self?.showTool(t) }

        colorPicker.segmentCount = Self.palette.count
        colorPicker.trackingMode = .selectOne
        for (i, (name, color)) in Self.palette.enumerated() {
            colorPicker.setImage(Self.swatch(color), forSegment: i)
            colorPicker.setToolTip(name, forSegment: i)
            colorPicker.setWidth(28, forSegment: i)
        }
        colorPicker.selectedSegment = min(Prefs.defaultColor, Self.palette.count - 1)
        canvas.color = Self.palette[colorPicker.selectedSegment].1
        colorPicker.target = self
        colorPicker.action = #selector(colorChanged)
        colorPicker.segmentStyle = .separated
        showTool(canvas.tool)

        let undo = iconButton("arrow.uturn.backward", tip: "실행 취소 (⌘Z)", action: #selector(undoClicked))
        let ocr = iconButton("doc.text.viewfinder", tip: "전체 텍스트 복사 (⌘⇧C)", action: #selector(copyText(_:)))
        let saveAs = iconButton("square.and.arrow.down", tip: "다른 이름으로 저장 (⌘⇧S)", action: #selector(saveDocumentAs(_:)))
        let copy = NSButton(title: "복사", target: self, action: #selector(copy(_:)))
        copy.toolTip = "복사 (⌘C)"
        copy.applyGlassStyle()
        copy.controlSize = .large
        let done = NSButton(title: "완료", target: self, action: #selector(finishEditing(_:)))
        done.applyGlassStyle()
        done.controlSize = .large
        done.bezelColor = .controlAccentColor
        done.contentTintColor = .white
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        done.toolTip = "저장하고 복사한 뒤 닫기 (⌘↩, ⌘S)"

        func capsule(_ views: [NSView]) -> NSView {
            let stack = NSStackView(views: views)
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            let glass = GlassBox(cornerRadius: 19)
            glass.contentView = stack
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.heightAnchor.constraint(equalToConstant: 38).isActive = true
            return glass
        }
        // 그리기 도구와 색을 한 캡슐에 넣어 색이 이 도구들에만 쓰인다는 걸 보여 준다
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let drawCapsule = capsule([toolGroups[0].picker, divider, colorPicker])
        let maskCapsule = capsule([toolGroups[1].picker])
        let readCapsule = capsule([toolGroups[2].picker, ocr])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [drawCapsule, maskCapsule, readCapsule, spacer, capsule([undo, saveAs]), copy, done])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.alignment = .centerY

        let root = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            // 왼쪽 신호등 단추 자리를 비우고 제목 막대 높이에 도구 막대를 띄운다
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 84),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: root.topAnchor, constant: toolbarHeight),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
            target: self, action: action
        )
        b.isBordered = false
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            color.setFill()
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        canvas.commitText()
        guard let group = toolGroups.first(where: { $0.picker === sender }),
              group.tools.indices.contains(sender.selectedSegment) else { return }
        canvas.tool = group.tools[sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    /// 고른 도구가 든 묶음만 선택해 보이고, 색을 안 쓰는 도구면 색 선택을 흐리게 한다
    private func showTool(_ tool: Tool) {
        // 칸이 하나뿐인 막대는 selectedSegment = -1 이 안 먹어서 칸마다 직접 끈다
        for (picker, tools) in toolGroups {
            for i in tools.indices { picker.setSelected(tools[i] == tool, forSegment: i) }
        }
        colorPicker.isEnabled = tool.usesColor
        colorPicker.alphaValue = tool.usesColor ? 1 : 0.35
    }

    @objc private func colorChanged() {
        canvas.color = Self.palette[colorPicker.selectedSegment].1
        window?.makeFirstResponder(canvas)
    }

    @objc private func undoClicked() {
        canvas.commitText()
        window?.undoManager?.undo()
    }

    @discardableResult
    private func save() -> Bool {
        if canvas.isDirty || !canvas.marks.isEmpty {
            guard let data = canvas.renderPNG() else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
            canvas.markSaved()
            CaptureStore.shared.didEdit(url)
        }
        Clipboard.copy(url)
        return true
    }

    /// 원본 캡처의 글자를 뽑아 클립보드에 넣는다 (주석은 글자 인식에서 뺀다)
    @objc func copyText(_ sender: Any?) {
        canvas.commitText()
        TextRecognizer.copyText(from: url, in: window)
    }

    @objc func saveDocument(_ sender: Any?) { finishEditing(sender) }

    @objc func copy(_ sender: Any?) {
        if save() { Toast.show("복사됨", symbol: "doc.on.doc", in: window) }
    }

    @objc func finishEditing(_ sender: Any?) {
        guard save() else { return }
        window?.close()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window, let data = canvas.renderPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = ExportName.displayName(for: url) + ".png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            do { try data.write(to: dest, options: .atomic) } catch { NSAlert(error: error).runModal() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitText()
        guard canvas.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "변경 사항 저장"
        alert.informativeText = "저장하면 SnapStack 기록과 클립보드에 수정본이 들어갑니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "저장 안 함")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.openEditors.removeValue(forKey: url)
    }
}
