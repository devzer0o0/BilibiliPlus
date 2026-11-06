import Flutter
import UIKit

/// Factory for the native glass bar. Each platform view owns one channel keyed
/// by its own viewId, so two bars (before and after a rebuild) can never
/// receive each other's state or taps.
final class LiquidGlassNavigationViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        LiquidGlassNavigationPlatformView(
            frame: frame,
            viewId: viewId,
            arguments: args,
            messenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class LiquidGlassNavigationPlatformView: NSObject, FlutterPlatformView {
    private let container: NativeLiquidGlassNavigationView
    private let channel: FlutterMethodChannel

    init(frame: CGRect, viewId: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
        container = NativeLiquidGlassNavigationView(frame: frame)
        channel = FlutterMethodChannel(
            name: LiquidGlassNavigationPlugin.instanceChannelPrefix + String(viewId),
            binaryMessenger: messenger
        )
        super.init()
        container.onSelect = { [weak self] destinationId in
            self?.channel.invokeMethod("onTap", arguments: ["id": destinationId])
        }
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented)
                return
            }
            switch call.method {
            case "updateState":
                self.container.apply(state: call.arguments as? [String: Any] ?? [:])
                result(nil)
            case "describe":
                result(self.container.describe())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        if let args = arguments as? [String: Any] {
            container.apply(state: args)
        }
    }

    func view() -> UIView {
        container
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}

/// The capsule itself: one glass shell, three custom buttons, one selection
/// pill. Everything transparent outside the capsule, so the list behind it
/// keeps scrolling and tapping.
final class NativeLiquidGlassNavigationView: UIView {
    private enum Metrics {
        static let indicatorHeight: CGFloat = 36
        static let indicatorWidth: CGFloat = 82
        static let iconSize: CGFloat = 23
        static let avatarSize: CGFloat = 24
        static let badgeTop: CGFloat = 10
        static let badgeHeight: CGFloat = 14
        static let badgeRightOffset: CGFloat = 13.5
        static let selectionDuration: CFTimeInterval = 0.28
    }

    var onSelect: ((String) -> Void)?

    private let glassView = UIVisualEffectView()
    private let selectionView = UIView()
    private var itemViews: [NativeGlassItemView] = []
    private var itemIds: [String] = []
    private var iconCache: [String: UIImage] = [:]
    private var avatarImage: UIImage?
    private var avatarToken: String?
    private var selectedId: String?
    private var revision = -1
    private var theme = "dark"
    private var appliedStyle = "clear"
    private var pixelRatio: CGFloat = 3
    private var isVisible = true
    private var isInteractive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        glassView.frame = bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glassView.alpha = 1
        glassView.backgroundColor = .clear
        addSubview(glassView)
        selectionView.isUserInteractionEnabled = false
        selectionView.layer.cornerRadius = Metrics.indicatorHeight / 2
        glassView.contentView.addSubview(selectionView)
        installGlass(style: appliedStyle)
        applyAccessibilityOverrides()
        updateColors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Material

    private func installGlass(style: String) {
        appliedStyle = style
        guard #available(iOS 26.0, *) else {
            glassView.effect = UIBlurEffect(style: .systemThinMaterial)
            glassView.layer.cornerRadius = bounds.height / 2
            glassView.clipsToBounds = true
            return
        }
        let effect = UIGlassEffect(style: style == "regular" ? .regular : .clear)
        effect.isInteractive = true
        glassView.effect = effect
        glassView.cornerConfiguration = .capsule()
        glassView.backgroundColor = .clear
        glassView.alpha = 1
        // One line per material install: it is the only way to tell a native
        // glass bar apart from the Flutter fallback on a device, and it also
        // records what the process inherited from the system settings.
        print(
            "[native-glass] material=" + materialName()
                + " os=" + UIDevice.current.systemVersion
                + " reduceTransparency=" + String(UIAccessibility.isReduceTransparencyEnabled)
                + " reduceMotion=" + String(UIAccessibility.isReduceMotionEnabled)
        )
    }

    private func materialName() -> String {
        if #available(iOS 26.0, *) {
            if glassView.effect is UIGlassEffect {
                return appliedStyle == "regular" ? "UIGlassEffect.regular" : "UIGlassEffect.clear"
            }
        } else if glassView.effect is UIBlurEffect {
            return "UIBlurEffect.systemThinMaterial"
        }
        return "none"
    }

    /// Reduce Transparency replaces the material with an opaque surface, which
    /// is what the system itself does. Increase Contrast tightens the selection
    /// and the glyph alpha instead of adding a second tint.
    private func applyAccessibilityOverrides() {
        if UIAccessibility.isReduceTransparencyEnabled {
            if glassView.effect != nil {
                glassView.effect = nil
            }
            glassView.backgroundColor = theme == "dark"
                ? UIColor(white: 0.12, alpha: 1)
                : UIColor(white: 0.96, alpha: 1)
            glassView.layer.cornerRadius = bounds.height / 2
            glassView.clipsToBounds = true
        } else if glassView.effect == nil {
            glassView.clipsToBounds = false
            glassView.layer.cornerRadius = 0
            installGlass(style: appliedStyle)
        }
    }

    @objc private func systemAppearanceChanged() {
        applyAccessibilityOverrides()
        updateColors()
        setNeedsLayout()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds
        let count = max(itemViews.count, 1)
        let cellWidth = bounds.width / CGFloat(count)
        for (index, item) in itemViews.enumerated() {
            item.frame = CGRect(
                x: CGFloat(index) * cellWidth,
                y: 0,
                width: cellWidth,
                height: bounds.height
            )
        }
        if glassView.effect == nil {
            glassView.layer.cornerRadius = bounds.height / 2
        }
        layoutSelection(animated: false)
    }

    private func selectionFrame(for index: Int) -> CGRect {
        let count = max(itemViews.count, 1)
        let cellWidth = bounds.width / CGFloat(count)
        let width = min(Metrics.indicatorWidth, max(0, cellWidth - 16))
        return CGRect(
            x: CGFloat(index) * cellWidth + (cellWidth - width) / 2,
            y: (bounds.height - Metrics.indicatorHeight) / 2,
            width: width,
            height: Metrics.indicatorHeight
        )
    }

    /// Moves the selection pill from wherever it currently is on screen.
    ///
    /// The model frame is set immediately and the visual transition is a single
    /// position.x animation whose start is read from the presentation layer, so
    /// a fast sequence of taps retargets instead of jumping back.
    private func layoutSelection(animated: Bool) {
        guard let selectedId, let index = itemIds.firstIndex(of: selectedId) else {
            selectionView.isHidden = true
            selectionView.layer.removeAnimation(forKey: "liquid.selection")
            return
        }
        selectionView.isHidden = !isVisible
        let target = selectionFrame(for: index)
        let presentationX = selectionView.layer.presentation()?.position.x
        let currentX = presentationX ?? selectionView.layer.position.x
        selectionView.frame = target
        let canAnimate = animated
            && isVisible
            && !UIAccessibility.isReduceMotionEnabled
            && !bounds.isEmpty
            && abs(currentX - target.midX) > 0.5
        if canAnimate {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = currentX
            animation.toValue = target.midX
            animation.duration = Metrics.selectionDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.9, 0.24, 1.0)
            selectionView.layer.add(animation, forKey: "liquid.selection")
        } else {
            selectionView.layer.removeAnimation(forKey: "liquid.selection")
        }
    }

    private func updateColors() {
        let dark = theme == "dark"
        let contrast = UIAccessibility.isDarkerSystemColorsEnabled
        selectionView.backgroundColor = dark
            ? UIColor(white: 1, alpha: contrast ? 0.2 : 0.12)
            : UIColor(white: 0, alpha: contrast ? 0.14 : 0.08)
        selectionView.layer.borderWidth = contrast ? 1 : 0
        selectionView.layer.borderColor = (dark ? UIColor.white : UIColor.black)
            .withAlphaComponent(contrast ? 0.25 : 0)
            .cgColor
        for item in itemViews {
            item.applyAppearance(theme: theme)
        }
    }

    // MARK: - State

    func apply(state: [String: Any]) {
        let incoming = state["revision"] as? Int ?? 0
        guard incoming >= revision else { return }
        revision = incoming

        if let ratio = state["pixelRatio"] as? Double {
            pixelRatio = CGFloat(ratio)
        }
        if let style = state["style"] as? String, style != appliedStyle,
           !UIAccessibility.isReduceTransparencyEnabled {
            installGlass(style: style)
        }
        if let incomingTheme = state["theme"] as? String {
            theme = incomingTheme
        }
        if let icons = state["icons"] as? [String: FlutterStandardTypedData] {
            for (key, typed) in icons {
                if let image = UIImage(data: typed.data, scale: pixelRatio) {
                    iconCache[key] = image.withRenderingMode(.alwaysTemplate)
                }
            }
        }

        let incomingToken = state["avatarToken"] as? String
        if let incomingToken, incomingToken != avatarToken {
            avatarToken = incomingToken
            avatarImage = nil
        }
        if avatarImage == nil,
           let typed = state["avatar"] as? FlutterStandardTypedData,
           let image = UIImage(data: typed.data) {
            avatarImage = image
        }

        let items = state["items"] as? [[String: Any]] ?? []
        let ids = items.compactMap { $0["id"] as? String }
        if ids != itemIds {
            rebuildItems(ids: ids)
        }

        let previousSelected = selectedId
        selectedId = state["selectedId"] as? String

        for (index, payload) in items.enumerated() where index < itemViews.count {
            let item = itemViews[index]
            item.isSelected = (payload["id"] as? String) == selectedId
            item.apply(
                payload: payload,
                icons: iconCache,
                avatar: avatarImage,
                theme: theme
            )
        }

        if let visible = state["visible"] as? Bool {
            setVisible(visible)
        }
        if let interactive = state["interactive"] as? Bool {
            isInteractive = interactive
            isUserInteractionEnabled = isVisible && interactive
        }

        updateColors()
        applyAccessibilityOverrides()
        setNeedsLayout()
        layoutIfNeeded()
        layoutSelection(
            animated: previousSelected != nil
                && previousSelected != selectedId
                && (state["animate"] as? Bool ?? true)
        )
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        glassView.isHidden = !visible
        accessibilityElementsHidden = !visible
        isUserInteractionEnabled = visible && isInteractive
        if !visible {
            selectionView.layer.removeAnimation(forKey: "liquid.selection")
        }
    }

    private func rebuildItems(ids: [String]) {
        for item in itemViews {
            item.removeFromSuperview()
        }
        itemViews = []
        itemIds = ids
        for id in ids {
            let item = NativeGlassItemView()
            item.destinationId = id
            item.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
            glassView.contentView.addSubview(item)
            itemViews.append(item)
        }
        glassView.contentView.sendSubviewToBack(selectionView)
    }

    @objc private func itemTapped(_ sender: NativeGlassItemView) {
        guard isVisible, isInteractive else { return }
        // Even a tap on the already selected entry is forwarded: the controller
        // owns "scroll to top / refresh on repeated tap" and the haptic.
        onSelect?(sender.destinationId)
    }

    // MARK: - Hit testing

    /// The platform view is exactly the capsule, but its bounding box also
    /// covers the four transparent corners. Those must stay with the page.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isVisible, isInteractive, !isHidden, alpha > 0.01 else { return nil }
        guard bounds.contains(point) else { return nil }
        let capsule = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2)
        guard capsule.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - Diagnostics

    func describe() -> [String: Any] {
        var material = materialName()
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        if reduceTransparency {
            material += "+reduceTransparency"
        }
        return [
            "material": material,
            "osVersion": UIDevice.current.systemVersion,
            "items": itemViews.count,
            "selectedId": selectedId ?? "",
            "revision": revision,
            "reduceTransparency": reduceTransparency,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "increaseContrast": UIAccessibility.isDarkerSystemColorsEnabled,
            "bounds": NSCoder.string(for: bounds),
        ]
    }
}

/// One cell: glyph (or circular avatar) plus the unread badge. The cell is the
/// accessibility element; the bar itself is not, so VoiceOver sees three
/// buttons and never a duplicate node from Flutter.
final class NativeGlassItemView: UIControl {
    private enum Metrics {
        static let iconSize: CGFloat = 23
        static let avatarSize: CGFloat = 24
        static let badgeTop: CGFloat = 10
        static let badgeHeight: CGFloat = 14
        static let badgeRightOffset: CGFloat = 13.5
    }

    var destinationId = ""

    private let imageView = UIImageView()
    private let numberBadge = UILabel()
    private let dotBadge = UIView()
    private var normalImage: UIImage?
    private var selectedImage: UIImage?
    private var avatarImage: UIImage?
    private var isAvatar = false
    private var theme = "dark"
    private var accessibilityValueText: String?

    private static let badgeColor = UIColor(
        red: 0xFB / 255,
        green: 0x72 / 255,
        blue: 0x99 / 255,
        alpha: 1
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .center
        addSubview(imageView)

        numberBadge.isHidden = true
        numberBadge.textAlignment = .center
        numberBadge.textColor = .white
        numberBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        numberBadge.backgroundColor = NativeGlassItemView.badgeColor
        numberBadge.layer.cornerRadius = Metrics.badgeHeight / 2
        numberBadge.layer.masksToBounds = true
        numberBadge.layer.borderWidth = 0.5
        numberBadge.layer.borderColor = UIColor(white: 0, alpha: 0.4).cgColor
        addSubview(numberBadge)

        dotBadge.isHidden = true
        dotBadge.backgroundColor = NativeGlassItemView.badgeColor
        dotBadge.layer.cornerRadius = 4
        dotBadge.layer.borderWidth = 0.5
        dotBadge.layer.borderColor = UIColor(white: 0, alpha: 0.4).cgColor
        addSubview(dotBadge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            updateAccessibility()
            refreshImage()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            let scale: CGFloat = isHighlighted ? 0.9 : 1
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.imageView.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }

    func apply(
        payload: [String: Any],
        icons: [String: UIImage],
        avatar: UIImage?,
        theme: String
    ) {
        self.theme = theme
        isAvatar = payload["isAvatar"] as? Bool ?? false
        avatarImage = avatar
        normalImage = (payload["iconKey"] as? String).flatMap { icons[$0] }
        selectedImage = (payload["selectedIconKey"] as? String).flatMap { icons[$0] }
        accessibilityLabel = payload["label"] as? String
        accessibilityValueText = payload["accessibilityValue"] as? String

        let badge = payload["badge"] as? [String: Any]
        let badgeVisible = badge?["visible"] as? Bool ?? false
        let isDot = badge?["isDot"] as? Bool ?? false
        numberBadge.text = badge?["text"] as? String
        numberBadge.isHidden = !(badgeVisible && !isDot)
        dotBadge.isHidden = !(badgeVisible && isDot)

        updateAccessibility()
        refreshImage()
        setNeedsLayout()
    }

    func applyAppearance(theme: String) {
        self.theme = theme
        refreshImage()
    }

    private func refreshImage() {
        if isAvatar, let avatarImage {
            imageView.image = avatarImage.withRenderingMode(.alwaysOriginal)
            imageView.contentMode = .scaleAspectFill
            imageView.layer.cornerRadius = Metrics.avatarSize / 2
            imageView.clipsToBounds = true
        } else {
            let base = isSelected ? (selectedImage ?? normalImage) : (normalImage ?? selectedImage)
            imageView.image = base?.withRenderingMode(.alwaysTemplate)
            imageView.contentMode = .center
            imageView.layer.cornerRadius = 0
            imageView.clipsToBounds = false
        }
        imageView.tintColor = foregroundColor()
    }

    private func foregroundColor() -> UIColor {
        let dark = theme == "dark"
        let alpha: CGFloat
        if UIAccessibility.isDarkerSystemColorsEnabled {
            alpha = 1
        } else {
            alpha = isSelected ? 0.95 : (dark ? 0.7 : 0.6)
        }
        return dark
            ? UIColor(white: 1, alpha: alpha)
            : UIColor(white: 0, alpha: alpha)
    }

    private func updateAccessibility() {
        var traits: UIAccessibilityTraits = .button
        if isSelected {
            traits.insert(.selected)
        }
        accessibilityTraits = traits
        accessibilityValue = accessibilityValueText
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = isAvatar ? Metrics.avatarSize : Metrics.iconSize
        imageView.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        let right = bounds.midX + Metrics.badgeRightOffset
        if !numberBadge.isHidden {
            let textWidth = (numberBadge.text as NSString?)?
                .size(withAttributes: [.font: numberBadge.font as Any]).width ?? 0
            let width = max(Metrics.badgeHeight, ceil(textWidth) + 6)
            numberBadge.frame = CGRect(
                x: right - width,
                y: Metrics.badgeTop,
                width: width,
                height: Metrics.badgeHeight
            )
        }
        dotBadge.frame = CGRect(
            x: right - 8,
            y: Metrics.badgeTop,
            width: 8,
            height: 8
        )
    }
}
