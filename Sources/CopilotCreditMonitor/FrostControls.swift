import AppKit
import QuartzCore

@MainActor
enum FrostPalette {
    static let accent = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.58, green: 0.84, blue: 0.75, alpha: 1)
        }
        return NSColor(calibratedRed: 0.12, green: 0.43, blue: 0.39, alpha: 1)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

@MainActor
enum FrostMotion {
    static func spring(_ layer: CALayer, keyPath: String, to value: Any) {
        let previous = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = 420
        animation.damping = 36
        animation.fromValue = previous
        animation.toValue = value
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: keyPath)
    }
}

@MainActor
final class FrostMaterialView: NSVisualEffectView {
    private let edge = CAShapeLayer()
    private let glow = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.95, y: 1)
        glow.endPoint = CGPoint(x: 0.1, y: 0.1)
        layer?.addSublayer(glow)
        edge.fillColor = NSColor.clear.cgColor
        edge.lineWidth = 0.5
        layer?.addSublayer(edge)
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        edge.frame = bounds
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: 18, cornerHeight: 18, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = FrostPalette.isDark(effectiveAppearance)
            edge.strokeColor = NSColor.white.withAlphaComponent(dark ? 0.12 : 0.5).cgColor
            glow.colors = [
                FrostPalette.accent.withAlphaComponent(dark ? 0.10 : 0.06).cgColor,
                NSColor.clear.cgColor,
            ]
        }
    }
}

@MainActor
final class FrostCardView: NSView {
    var isFocused = false { didSet { updateColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = FrostPalette.isDark(effectiveAppearance)
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.045 : 0.28).cgColor
            layer?.borderColor = isFocused ? FrostPalette.accent.withAlphaComponent(0.75).cgColor
                : (highContrast ? NSColor.separatorColor : NSColor.white.withAlphaComponent(dark ? 0.1 : 0.55)).cgColor
            layer?.borderWidth = isFocused || highContrast ? 1 : 0.5
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = isFocused ? 0.06 : 0.025
            layer?.shadowRadius = isFocused ? 9 : 5
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
    }
}

@MainActor
final class FrostButton: NSButton {
    enum Style { case quiet, primary }
    private let style: Style
    private var hovered = false
    private var pressed = false
    private var hoverArea: NSTrackingArea?

    init(title: String, symbol: String? = nil, style: Style = .quiet) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 8
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: style == .primary ? 34 : 30).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant: 30).isActive = true }
        updateStyle()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet { updateStyle() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateStyle(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateStyle(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        updateStyle(animated: true)
        super.mouseDown(with: event)
        pressed = false
        updateStyle(animated: true)
    }

    private func updateStyle(animated: Bool = false) {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = FrostPalette.isDark(effectiveAppearance)
            let active = isEnabled && (hovered || pressed)
            let ink: NSColor = style == .primary
                ? (dark ? NSColor(calibratedWhite: 0.1, alpha: 1) : .white)
                : NSColor.labelColor.withAlphaComponent(active ? 1 : 0.78)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: ink.withAlphaComponent(isEnabled ? 1 : 0.4),
                .paragraphStyle: paragraph,
            ])
            contentTintColor = ink
            layer.backgroundColor = (style == .primary
                ? FrostPalette.accent.withAlphaComponent(isEnabled ? 1 : 0.3)
                : NSColor.labelColor.withAlphaComponent(active ? 0.06 : 0)).cgColor
            layer.borderWidth = style == .primary ? 0.5 : 0
            layer.borderColor = NSColor.white.withAlphaComponent(dark ? 0.13 : 0.25).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: -2)
            let scale = isEnabled ? (pressed ? 0.97 : hovered ? 1.025 : 1) : 1
            if animated {
                FrostMotion.spring(layer, keyPath: "transform.scale", to: scale)
                FrostMotion.spring(layer, keyPath: "shadowOpacity", to: active ? 0.08 : 0)
            } else {
                layer.setValue(scale, forKeyPath: "transform.scale")
                layer.shadowOpacity = 0
            }
        }
    }
}

@MainActor
final class FrostProgressView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.cornerRadius = 2
        fill.cornerRadius = 2
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.anchorPoint = .zero
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("剩余额度")
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: Double?, description: String) {
        let next = min(1, max(0, value ?? 0))
        let changed = next != fraction
        fraction = next
        setAccessibilityValue(description)
        if changed, bounds.width > 0 {
            FrostMotion.spring(fill, keyPath: "bounds.size.width", to: bounds.width * fraction)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.position = .zero
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            fill.colors = [
                FrostPalette.accent.withAlphaComponent(0.72).cgColor,
                FrostPalette.accent.cgColor,
            ]
        }
    }
}
