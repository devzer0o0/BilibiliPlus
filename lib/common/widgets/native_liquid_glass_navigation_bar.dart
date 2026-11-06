import 'dart:async';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/widgets/liquid_glass_navigation_bar.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Which system material the native bar asks for.
///
/// The reference recording is a translucent capsule over a busy list, so the
/// first pass used clear. --dart-define=GLASS_STYLE=regular switches to the
/// standard glass for a side-by-side comparison without touching Swift.
const String kNativeLiquidGlassStyle = String.fromEnvironment(
  'GLASS_STYLE',
  defaultValue: 'clear',
);

/// What this build can actually do, asked of the native side once per process.
///
/// The answer is cached before the first frame, so the first frame never paints
/// the Flutter fallback and then flips to the native material.
class NativeLiquidGlassCapabilities {
  const NativeLiquidGlassCapabilities({
    required this.supported,
    required this.effect,
    required this.osVersion,
    this.deviceModel = '',
    this.unsupportedReason,
  });

  final bool supported;
  final String effect;
  final String osVersion;
  final String deviceModel;
  final String? unsupportedReason;

  bool get usesUIGlassEffect => supported && effect == 'UIGlassEffect';

  @override
  String toString() =>
      'NativeLiquidGlassCapabilities(supported: $supported, effect: $effect, '
      'os: $osVersion, reason: ${unsupportedReason ?? '-'})';
}

/// Bridge to the native capsule.
///
/// One capability channel, then one instance channel per platform view:
/// piliplus/native_liquid_glass_nav with the view id appended. State travels Dart to
/// native; the only native to Dart message is onTap with a stable destination
/// id. No Flutter widget ever crosses the channel.
abstract final class NativeLiquidGlassNavigation {
  static const String viewType = 'piliplus/native_liquid_glass_nav';
  static const String capabilitiesChannelName =
      'piliplus/native_liquid_glass_nav/capabilities';
  static const String instanceChannelPrefix =
      'piliplus/native_liquid_glass_nav/';

  static const MethodChannel _capabilities = MethodChannel(
    capabilitiesChannelName,
  );

  static NativeLiquidGlassCapabilities? _cached;
  static Future<NativeLiquidGlassCapabilities>? _pending;

  static NativeLiquidGlassCapabilities? get cachedCapabilities => _cached;

  /// Resolved before the first frame by main, so the widget can decide
  /// synchronously and never flashes the shader fallback on a capable device.
  static Future<NativeLiquidGlassCapabilities> prefetchCapabilities() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _load();
  }

  static Future<NativeLiquidGlassCapabilities> _load() async {
    try {
      final map = await _capabilities.invokeMapMethod<String, Object?>(
        'getCapabilities',
      );
      final caps = NativeLiquidGlassCapabilities(
        supported: map?['supported'] == true,
        effect: map?['effect'] as String? ?? 'none',
        osVersion: map?['osVersion'] as String? ?? '',
        deviceModel: map?['deviceModel'] as String? ?? '',
        unsupportedReason: map?['unsupportedReason'] as String?,
      );
      _cached = caps;
      if (kDebugMode) {
        debugPrint('[native-glass] capabilities: $caps');
      }
      return caps;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[native-glass] capability query failed: $error');
      }
      return _cached = const NativeLiquidGlassCapabilities(
        supported: false,
        effect: 'none',
        osVersion: '',
        unsupportedReason: 'channel-error',
      );
    }
  }

  @visibleForTesting
  static void debugResetCapabilities() {
    _cached = null;
    _pending = null;
  }
}

/// One entry of the native bar. Icons are existing [IconData] glyphs, not new
/// artwork: the bridge rasterises the same font glyph Flutter would paint.
class NativeLiquidGlassDestination {
  const NativeLiquidGlassDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.isAvatar = false,
    this.badgeVisible = false,
    this.badgeText,
    this.badgeIsDot = false,
    this.accessibilityValue,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// The entry shows the signed-in avatar; [icon] is the placeholder glyph.
  final bool isAvatar;

  final bool badgeVisible;
  final String? badgeText;
  final bool badgeIsDot;

  /// Spoken unread count, e.g. "3 条未读". Kept out of the label so VoiceOver
  /// reads the name, the selection state and the count in that order.
  final String? accessibilityValue;
}

/// The native capsule. Layout, spacing and safe area stay in Flutter; only the
/// material and the three hit areas live in UIKit.
class NativeLiquidGlassNavigationBar extends StatefulWidget {
  const NativeLiquidGlassNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedId,
    required this.onDestinationSelected,
    required this.onUnavailable,
    this.avatarUrl = '',
    this.bottomInset = 0,
    this.visible = true,
    this.glassStyle = kNativeLiquidGlassStyle,
    this.avatarLoader,
    this.iconRasterizer,
  });

  final List<NativeLiquidGlassDestination> destinations;
  final String selectedId;

  /// Receives the index inside [destinations] at tap time, already resolved
  /// against the current ordering. Same contract as the Flutter bar.
  final ValueChanged<int> onDestinationSelected;

  /// The platform view never came up. The caller must fall back and must not
  /// report a native pass.
  final VoidCallback onUnavailable;

  final String avatarUrl;
  final double bottomInset;

  /// The bar can be slid off screen by the existing hide behaviour.
  final bool visible;

  final String glassStyle;

  /// Test seam: replaces the cached network avatar load. Production keeps using
  /// the same provider and cache the Flutter avatar uses.
  final Future<Uint8List?> Function(String url)? avatarLoader;

  /// Test seam: replaces the offscreen glyph rasterisation. Widget tests have
  /// no real font backend, so they inject bytes; the device path is unchanged.
  final Future<Uint8List?> Function(
    IconData icon,
    double size,
    double pixelRatio,
  )?
  iconRasterizer;

  @override
  State<NativeLiquidGlassNavigationBar> createState() =>
      _NativeLiquidGlassNavigationBarState();
}

class _NativeLiquidGlassNavigationBarState
    extends State<NativeLiquidGlassNavigationBar> {
  static const Duration _creationTimeout = Duration(seconds: 3);

  final Map<String, Uint8List> _iconBytes = {};
  final Set<String> _inFlightIcons = {};
  final Set<String> _deliveredIconKeys = {};

  MethodChannel? _channel;
  bool _created = false;
  Timer? _creationTimer;

  Uint8List? _avatarBytes;
  String? _avatarToken;
  int _avatarRequest = 0;

  int _revision = 0;
  String? _lastSignature;
  bool _deliveredInitialState = false;

  @override
  void initState() {
    super.initState();
    _creationTimer = Timer(_creationTimeout, () {
      if (!mounted || _created) return;
      if (kDebugMode) {
        debugPrint('[native-glass] platform view was not created in time');
      }
      widget.onUnavailable();
    });
    // Icons and the avatar need MediaQuery, so they start in
    // didChangeDependencies, not here.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureIcons();
    _ensureAvatar();
  }

  @override
  void didUpdateWidget(NativeLiquidGlassNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureIcons();
    _ensureAvatar();
  }

  @override
  void dispose() {
    _creationTimer?.cancel();
    _creationTimer = null;
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _avatarRequest++;
    super.dispose();
  }

  String _iconKey(IconData icon, double size, double pixelRatio) {
    final family = icon.fontFamily ?? 'default';
    final package = icon.fontPackage ?? '';
    final codePoint = icon.codePoint.toRadixString(16);
    return '$family:$codePoint:$package:${size.toStringAsFixed(1)}:'
        '${pixelRatio.toStringAsFixed(2)}';
  }

  void _ensureIcons() {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    for (final destination in widget.destinations) {
      for (final icon in [destination.icon, destination.selectedIcon]) {
        final key = _iconKey(icon, kLiquidNavIconSize, pixelRatio);
        if (_iconBytes.containsKey(key) || _inFlightIcons.contains(key)) {
          continue;
        }
        _inFlightIcons.add(key);
        (widget.iconRasterizer ?? _rasterizeIcon)(
          icon,
          kLiquidNavIconSize,
          pixelRatio,
        ).then((bytes) {
          _inFlightIcons.remove(key);
          if (!mounted || bytes == null) return;
          _iconBytes[key] = bytes;
          setState(() {});
        });
      }
    }
  }

  /// Rasterises the existing font glyph once, offscreen. Never a page
  /// screenshot: this is the same codepoint Flutter would paint, at the
  /// physical resolution of the screen.
  Future<Uint8List?> _rasterizeIcon(
    IconData icon,
    double size,
    double pixelRatio,
  ) async {
    final pixels = (size * pixelRatio).ceil();
    final fontSize = pixels.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Package fonts are addressed as packages/<package>/<family> when a
    // paragraph is laid out directly; IconData keeps the two parts separate.
    final family = icon.fontFamily == null
        ? null
        : icon.fontPackage == null
        ? icon.fontFamily
        : 'packages/${icon.fontPackage}/${icon.fontFamily}';
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: TextAlign.center,
              fontFamily: family,
              fontSize: fontSize,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: const Color(0xFFFFFFFF),
              fontSize: fontSize,
              height: 1,
              fontFamily: family,
            ),
          )
          ..addText(String.fromCharCode(icon.codePoint));
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: pixels.toDouble()));
    canvas.drawParagraph(paragraph, Offset.zero);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(pixels, pixels);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  void _ensureAvatar() {
    final url = widget.avatarUrl;
    if (url == _avatarToken) return;
    _avatarToken = url;
    _avatarBytes = null;
    final token = url;
    final request = ++_avatarRequest;
    if (url.isEmpty) {
      _invalidate();
      return;
    }
    (widget.avatarLoader ?? _resolveAvatar)(url).then((bytes) {
      // A newer account avatar was requested while this one loaded: the result
      // is stale and must not replace the current one.
      if (!mounted || request != _avatarRequest || token != _avatarToken) {
        return;
      }
      if (bytes == null) {
        _invalidate();
        return;
      }
      _avatarBytes = bytes;
      _invalidate();
    });
  }

  /// Reuses the same provider and cache the Flutter avatar uses, so the native
  /// bar does not introduce a second login or image pipeline.
  Future<Uint8List?> _resolveAvatar(String url) async {
    final provider = CachedNetworkImageProvider(
      ImageUtils.thumbnailUrl(url, 1),
      maxWidth: 128,
      maxHeight: 128,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final completer = Completer<ui.Image?>();
    void finish(ui.Image? image) {
      if (!completer.isCompleted) completer.complete(image);
    }

    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        finish(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        finish(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    if (image == null) return null;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  void _invalidate() {
    if (!mounted) return;
    setState(() {
      _lastSignature = null;
    });
  }

  void _onPlatformViewCreated(int id) {
    _creationTimer?.cancel();
    _creationTimer = null;
    final channel = MethodChannel(
      '${NativeLiquidGlassNavigation.instanceChannelPrefix}$id',
    );
    _channel = channel;
    _created = true;
    channel.setMethodCallHandler(_handleNativeCall);
    // A new native view has an empty icon cache. Changes that happened before
    // creation are not queued event by event; the newest state is sent once.
    _deliveredIconKeys.clear();
    _deliveredInitialState = false;
    _lastSignature = null;
    if (!mounted) return;
    _deliverState(force: true);
    if (kDebugMode) {
      _describe(id);
    }
  }

  Future<void> _describe(int id) async {
    final channel = _channel;
    if (channel == null) return;
    try {
      final describe = await channel.invokeMapMethod<String, Object?>(
        'describe',
      );
      if (!mounted) return;
      debugPrint('[native-glass] view $id: $describe');
    } catch (_) {
      // Diagnostics only.
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onTap') return;
    final arguments = call.arguments;
    final id = arguments is Map ? arguments['id'] as String? : null;
    if (id == null) return;
    final index = widget.destinations.indexWhere((item) => item.id == id);
    if (index < 0) {
      // A late tap from a bar whose entries were reordered or hidden.
      if (kDebugMode) {
        debugPrint('[native-glass] ignoring tap for unknown id: $id');
      }
      return;
    }
    widget.onDestinationSelected(index);
  }

  Map<String, Object?> _statePayload(BuildContext context) {
    final icons = <String, Uint8List>{};
    for (final entry in _iconBytes.entries) {
      if (!_deliveredIconKeys.contains(entry.key)) {
        icons[entry.key] = entry.value;
      }
    }
    _deliveredIconKeys.addAll(icons.keys);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return {
      'revision': ++_revision,
      'pixelRatio': pixelRatio,
      'style': widget.glassStyle,
      'theme': Theme.of(context).brightness == Brightness.dark
          ? 'dark'
          : 'light',
      'selectedId': widget.selectedId,
      'animate': !MediaQuery.disableAnimationsOf(context),
      'visible': widget.visible,
      'interactive': widget.visible,
      'items': [
        for (final destination in widget.destinations)
          {
            'id': destination.id,
            'label': destination.label,
            'iconKey': _iconKey(
              destination.icon,
              kLiquidNavIconSize,
              pixelRatio,
            ),
            'selectedIconKey': _iconKey(
              destination.selectedIcon,
              kLiquidNavIconSize,
              pixelRatio,
            ),
            'isAvatar': destination.isAvatar,
            'accessibilityValue': destination.accessibilityValue,
            'badge': {
              'visible': destination.badgeVisible,
              'text': destination.badgeText,
              'isDot': destination.badgeIsDot,
            },
          },
      ],
      'avatarToken': _avatarToken ?? '',
      'avatar': _avatarBytes,
      'icons': icons,
    };
  }

  String _signature(BuildContext context) {
    final buffer = StringBuffer()
      ..write(widget.selectedId)
      ..write('|')
      ..write(widget.glassStyle)
      ..write('|')
      ..write(Theme.of(context).brightness.name)
      ..write('|')
      ..write(MediaQuery.disableAnimationsOf(context))
      ..write('|')
      ..write(widget.visible)
      ..write('|')
      ..write(_avatarToken ?? '')
      ..write('|')
      ..write(_avatarBytes?.length ?? -1)
      ..write('|');
    for (final destination in widget.destinations) {
      buffer
        ..write(destination.id)
        ..write(':')
        ..write(destination.label)
        ..write(':')
        ..write(destination.icon.codePoint)
        ..write(':')
        ..write(destination.selectedIcon.codePoint)
        ..write(':')
        ..write(destination.isAvatar)
        ..write(':')
        ..write(destination.badgeVisible)
        ..write(':')
        ..write(destination.badgeText ?? '')
        ..write(':')
        ..write(destination.badgeIsDot)
        ..write(':')
        ..write(destination.accessibilityValue ?? '')
        ..write(';');
    }
    for (final key in _iconBytes.keys) {
      buffer
        ..write(key)
        ..write(',');
    }
    return buffer.toString();
  }

  void _deliverState({bool force = false}) {
    final channel = _channel;
    if (!_created || channel == null) return;
    final signature = _signature(context);
    if (!force && _deliveredInitialState && signature == _lastSignature) {
      return;
    }
    _lastSignature = signature;
    _deliveredInitialState = true;
    channel
        .invokeMethod<void>('updateState', _statePayload(context))
        .catchError((Object error) {
          if (kDebugMode) {
            debugPrint('[native-glass] updateState failed: $error');
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    // A keyboard is on screen: no layout, no hit testing, no accessibility.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final count = widget.destinations.length;
    if (count == 0) return const SizedBox.shrink();

    final bottomGap =
        LiquidGlassNavigationBar.heightFor(bottomInset: widget.bottomInset) -
        kLiquidNavBarHeight;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final width = LiquidGlassNavigationBar.shellWidthFor(screenWidth);
        _deliverState();
        return SizedBox(
          width: screenWidth,
          height: bottomGap + kLiquidNavBarHeight,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomGap),
            child: Center(
              child: SizedBox(
                width: width,
                height: kLiquidNavBarHeight,
                child: UiKitView(
                  key: const ValueKey('native-liquid-glass-nav'),
                  viewType: NativeLiquidGlassNavigation.viewType,
                  // The platform view is exactly the capsule. Its transparent
                  // corners must stay with the scrolling page behind it; the
                  // native hitTest drops those points as well.
                  hitTestBehavior: PlatformViewHitTestBehavior.translucent,
                  creationParams: _statePayload(context),
                  creationParamsCodec: const StandardMessageCodec(),
                  onPlatformViewCreated: _onPlatformViewCreated,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
