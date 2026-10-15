import AppKit
import SwiftUI

// macOS 26 은 Liquid Glass 를 쓰고, 15(세쿼이아)는 반투명 재질과 기본 버튼으로 대신한다.

enum Compat {
    /// SNAPSTACK_LEGACY_UI 를 주면 26 에서도 15 화면으로 그려 눈으로 확인할 수 있다
    static let legacy = ProcessInfo.processInfo.environment["SNAPSTACK_LEGACY_UI"] != nil
}

/// 유리 상자. 26 은 NSGlassEffectView, 15 는 NSVisualEffectView 로 그린다
final class GlassBox: NSView {
    private let surface: NSView

    init(cornerRadius: CGFloat, overDesktop: Bool = false) {
        if #available(macOS 26.0, *), !Compat.legacy {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            surface = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = overDesktop ? .hudWindow : .popover
            blur.blendingMode = overDesktop ? .behindWindow : .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            surface = blur
        }
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        pin(surface, to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    var contentView: NSView? {
        didSet {
            if #available(macOS 26.0, *), !Compat.legacy, let glass = surface as? NSGlassEffectView {
                glass.contentView = contentView
            } else {
                oldValue?.removeFromSuperview()
                guard let contentView else { return }
                contentView.translatesAutoresizingMaskIntoConstraints = false
                surface.addSubview(contentView)
                pin(contentView, to: surface)
            }
        }
    }

    private func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

extension NSButton {
    /// 26 은 유리 버튼, 15 는 원형·둥근 기본 버튼
    func applyGlassStyle(circle: Bool = false) {
        if #available(macOS 26.0, *), !Compat.legacy {
            bezelStyle = .glass
            if circle { borderShape = .circle }
        } else {
            bezelStyle = circle ? .circular : .rounded
        }
    }
}

/// 26 은 GlassEffectContainer 로 묶고, 15 는 그대로 둔다
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *), !Compat.legacy {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), !Compat.legacy {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// 알림용 어두운 캡슐. 흰 화면 위에서도 글자가 묻히지 않는다
    /// 유리는 흰 화면 위에서 흰 글자가 묻혀서, 알림은 OS 와 상관없이 어두운 캡슐로 그린다
    func hudCapsule() -> some View {
        background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *), !Compat.legacy {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }
}
