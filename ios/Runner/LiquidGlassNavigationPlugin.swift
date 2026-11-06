import Flutter
import UIKit

/// Native liquid-glass bottom bar for the main pages.
///
/// The Flutter side owns the page list, ordering, labels, unread badge and the
/// avatar; this plugin only owns the material: one `UIGlassEffect` capsule on
/// iOS 26+, with custom buttons inside `effectView.contentView`.
///
/// It is deliberately not a `UITabBar`: the bar has no text labels, three
/// equal cells, a round account avatar and a fixed capsule size. Turning the
/// whole Flutter navigation into a `UITabBarController` to get the material
/// would have changed the layout the user already approved.
final class LiquidGlassNavigationPlugin: NSObject, FlutterPlugin {
    static let viewType = "piliplus/native_liquid_glass_nav"
    static let capabilitiesChannelName = "piliplus/native_liquid_glass_nav/capabilities"
    static let instanceChannelPrefix = "piliplus/native_liquid_glass_nav/"

    static func register(with registrar: FlutterPluginRegistrar) {
        registrar.register(
            LiquidGlassNavigationViewFactory(messenger: registrar.messenger()),
            withId: viewType
        )
        let channel = FlutterMethodChannel(
            name: capabilitiesChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(LiquidGlassNavigationPlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getCapabilities":
            result(LiquidGlassNavigationPlugin.capabilities())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Whether this process can render the system material, and which effect it
    /// would be. Dart never guesses this from the OS version: the answer has to
    /// come from the same build that would create the view, otherwise a device
    /// that supports the glass quietly ends up on the Flutter fallback.
    static func capabilities() -> [String: Any] {
        var info: [String: Any] = [
            "platform": "ios",
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "increaseContrast": UIAccessibility.isDarkerSystemColorsEnabled,
        ]
        if #available(iOS 26.0, *) {
            info["supported"] = true
            info["effect"] = "UIGlassEffect"
            info["styles"] = ["clear", "regular"]
        } else {
            info["supported"] = false
            info["effect"] = "none"
            info["unsupportedReason"] = "ios<26"
        }
        return info
    }
}
