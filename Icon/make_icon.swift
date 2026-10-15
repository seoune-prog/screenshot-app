import AppKit

// 1024 앱 아이콘: 파란 배경 위에 겹친 캡처 카드 3장, 맨 앞 카드에 빨간 박스와 선택 모서리
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(red: 0.24, green: 0.36, blue: 0.95, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1),
        NSColor(red: 0.20, green: 0.27, blue: 0.86, alpha: 1),
    ])!.draw(in: tilePath, angle: -90)

    func card(_ r: NSRect, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.25)
        s.shadowBlurRadius = 18
        s.shadowOffset = NSSize(width: 0, height: -8)
        s.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    card(NSRect(x: 330, y: 470, width: 470, height: 330), alpha: 0.45)
    card(NSRect(x: 280, y: 390, width: 470, height: 330), alpha: 0.7)
    let front = NSRect(x: 225, y: 300, width: 480, height: 340)
    card(front, alpha: 1)

    // 앞 카드 속 화면 내용 줄
    NSColor(red: 0.80, green: 0.84, blue: 0.93, alpha: 1).setFill()
    for (i, w) in [300.0, 380.0, 240.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: front.minX + 50, y: front.maxY - 90 - CGFloat(i) * 62, width: w, height: 26), xRadius: 13, yRadius: 13).fill()
    }
    let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    red.setStroke()
    let box = NSBezierPath(roundedRect: NSRect(x: front.minX + 32, y: front.maxY - 116, width: 330, height: 78), xRadius: 10, yRadius: 10)
    box.lineWidth = 16
    box.stroke()

    // 선택 영역 모서리
    let sel = front.insetBy(dx: -40, dy: -40)
    let arm: CGFloat = 90
    let corners = NSBezierPath()
    corners.lineWidth = 30
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (p, dx, dy) in [
        (NSPoint(x: sel.minX, y: sel.minY), 1.0, 1.0), (NSPoint(x: sel.maxX, y: sel.minY), -1.0, 1.0),
        (NSPoint(x: sel.minX, y: sel.maxY), 1.0, -1.0), (NSPoint(x: sel.maxX, y: sel.maxY), -1.0, -1.0),
    ] {
        corners.move(to: NSPoint(x: p.x, y: p.y + dy * arm))
        corners.line(to: p)
        corners.line(to: NSPoint(x: p.x + dx * arm, y: p.y))
    }
    NSColor.white.setStroke()
    corners.stroke()
    return true
}

let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
