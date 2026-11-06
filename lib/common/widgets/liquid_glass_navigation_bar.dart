import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/liquid_glass_surface.dart';
import 'package:material_ui/material_ui.dart';

/// Height of the capsule itself.
const double kLiquidNavBarHeight = 52;

/// The reference capsule is 360 wide on a 420 pt screen, centred.
const double kLiquidNavBarMaxWidth = 360;
const double kLiquidNavBarSideMargin = 30;

/// Anything above the home indicator is wasted white space; the reference
/// sits 1 pt above it.
const double kLiquidNavMinBottomGap = 12;

/// Measured on the recording: 108 px at 3x, i.e. 36 pt, inside a 52 pt bar.
const double kLiquidNavIndicatorHeight = 36;

/// Kept at the reference size instead of stretching to a third of the bar, so
/// the three-entry version keeps the four-entry proportions.
const double kLiquidNavIndicatorWidth = 82;

const double kLiquidNavIconSize = 23;
const double kLiquidNavAvatarSize = 24;
const int kLiquidNavAnimationMs = 280;

/// One entry of the bar. The caller owns the icon widget so a destination can
/// be an outline glyph, a filled glyph or the signed-in avatar.
class LiquidGlassDestination {
  const LiquidGlassDestination({
    required this.label,
    required this.icon,
    Widget? selectedIcon,
    this.badge,
    this.isAvatar = false,
  }) : selectedIcon = selectedIcon ?? icon;

  final String label;
  final Widget icon;
  final Widget selectedIcon;

  /// Painted at the top-right of the icon, outside the capsule clip, so a
  /// badge is never cut by the rounded corner.
  final Widget? badge;

  /// The icon is a circular avatar: keep it round and do not tint it.
  final bool isAvatar;
}

/// Floating liquid-glass bar for the mobile main pages.
///
/// The widget is controlled: [selectedIndex] comes from [MainController] and
/// taps go straight back to its `setIndex`, which already fires the haptic
/// feedback. Only the indicator animation lives here.
class LiquidGlassNavigationBar extends StatefulWidget {
  const LiquidGlassNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.bottomInset = 0,
    this.animationDuration = const Duration(
      milliseconds: kLiquidNavAnimationMs,
    ),
    this.mode,
    this.blurSigma = 8,
    this.debugBounds = false,
  });

  final List<LiquidGlassDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// Real bottom safe-area inset, measured by [MainApp] before it strips the
  /// ambient padding. Never read MediaQuery.padding inside this subtree: it
  /// has already been zeroed by `MediaQuery.removePadding`.
  final double bottomInset;

  final Duration animationDuration;

  /// Forces a material mode; tests and the lab screen use it.
  final LiquidGlassMode? mode;

  /// Backdrop blur of the refracting material, logical pixels of sigma.
  final double blurSigma;

  final bool debugBounds;

  /// Total height the bar reports to [MainLayout] for a given inset.
  static double heightFor({required double bottomInset}) =>
      math.max(bottomInset, kLiquidNavMinBottomGap) + kLiquidNavBarHeight;

  /// Capsule width for the available screen width.
  static double shellWidthFor(double screenWidth) => math.min(
    kLiquidNavBarMaxWidth,
    math.max(180.0, screenWidth - 2 * kLiquidNavBarSideMargin),
  );

  @override
  State<LiquidGlassNavigationBar> createState() =>
      _LiquidGlassNavigationBarState();
}

class _LiquidGlassNavigationBarState extends State<LiquidGlassNavigationBar> {
  @override
  Widget build(BuildContext context) {
    // A keyboard is on screen: the capsule would sit on top of the input. Hide
    // it and drop hit testing and semantics with it.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final count = widget.destinations.length;
    if (count == 0) return const SizedBox.shrink();

    final bottomGap = math.max(widget.bottomInset, kLiquidNavMinBottomGap);

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final width = LiquidGlassNavigationBar.shellWidthFor(screenWidth);
        final cellWidth = width / count;
        final indicatorWidth = math.min(
          kLiquidNavIndicatorWidth,
          math.max(0.0, cellWidth - 16.0),
        );

        return SizedBox(
          width: screenWidth,
          height: bottomGap + kLiquidNavBarHeight,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomGap),
            child: Center(
              child: LiquidGlassSurface(
                width: width,
                height: kLiquidNavBarHeight,
                radius: kLiquidNavBarHeight / 2,
                mode: widget.mode,
                blurSigma: widget.blurSigma,
                debugBounds: widget.debugBounds,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _Indicator(
                      selectedIndex: widget.selectedIndex,
                      count: count,
                      cellWidth: cellWidth,
                      indicatorWidth: indicatorWidth,
                      width: width,
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : widget.animationDuration,
                    ),
                    for (var i = 0; i < count; i++)
                      Positioned(
                        left: i * cellWidth,
                        top: 0,
                        width: cellWidth,
                        height: kLiquidNavBarHeight,
                        child: _Destination(
                          key: ValueKey('liquid-nav-item-$i'),
                          destination: widget.destinations[i],
                          selected: i == widget.selectedIndex,
                          cellWidth: cellWidth,
                          onTap: () => widget.onDestinationSelected(i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The light pill behind the selected icon. It slides between cells; a fast
/// sequence of taps retargets from wherever it currently is.
class _Indicator extends StatefulWidget {
  const _Indicator({
    required this.selectedIndex,
    required this.count,
    required this.cellWidth,
    required this.indicatorWidth,
    required this.width,
    required this.duration,
  });

  final int selectedIndex;
  final int count;
  final double cellWidth;
  final double indicatorWidth;
  final double width;
  final Duration duration;

  @override
  State<_Indicator> createState() => _IndicatorState();
}

class _IndicatorState extends State<_Indicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late Animation<double> _left = AlwaysStoppedAnimation(_targetLeft);

  double get _targetLeft =>
      widget.cellWidth * widget.selectedIndex +
      (widget.cellWidth - widget.indicatorWidth) / 2;

  double get _currentLeft =>
      _controller.isAnimating ? _left.value : _targetLeft;

  @override
  void didUpdateWidget(_Indicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    final geometryChanged =
        oldWidget.cellWidth != widget.cellWidth ||
        oldWidget.indicatorWidth != widget.indicatorWidth ||
        oldWidget.count != widget.count;
    final target = _targetLeft;
    if (geometryChanged) {
      // Rotation or a width change: snap, the physics of a slide across a
      // resized bar would look wrong.
      _controller.stop();
      _left = AlwaysStoppedAnimation(target);
      return;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      final from = _currentLeft;
      if (widget.duration == Duration.zero || from == target) {
        _controller.stop();
        _left = AlwaysStoppedAnimation(target);
      } else {
        _left = Tween<double>(begin: from, end: target).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        );
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final left = _controller.isAnimating ? _left.value : _targetLeft;
        return Positioned(
          left: left,
          top: (kLiquidNavBarHeight - kLiquidNavIndicatorHeight) / 2,
          width: widget.indicatorWidth,
          height: kLiquidNavIndicatorHeight,
          child: IgnorePointer(child: child),
        );
      },
      child: DecoratedBox(
        key: const Key('liquid-nav-indicator'),
        decoration: BoxDecoration(
          color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
          borderRadius: BorderRadius.circular(kLiquidNavIndicatorHeight / 2),
        ),
      ),
    );
  }
}

class _Destination extends StatefulWidget {
  const _Destination({
    super.key,
    required this.destination,
    required this.selected,
    required this.cellWidth,
    required this.onTap,
  });

  final LiquidGlassDestination destination;
  final bool selected;
  final double cellWidth;
  final VoidCallback onTap;

  @override
  State<_Destination> createState() => _DestinationState();
}

class _DestinationState extends State<_Destination> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final destination = widget.destination;
    final selected = widget.selected;
    final color = destination.isAvatar
        ? null
        : isDark
        ? (selected ? const Color(0xF2FFFFFF) : const Color(0xB3FFFFFF))
        : (selected ? const Color(0xF2000000) : const Color(0x99000000));

    Widget icon = selected ? destination.selectedIcon : destination.icon;
    if (!destination.isAvatar) {
      icon = IconTheme.merge(
        data: IconThemeData(size: kLiquidNavIconSize, color: color),
        child: icon,
      );
    }

    Widget body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          AnimatedScale(
            scale: _pressed ? 0.9 : 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: icon,
          ),
          if (destination.badge != null)
            Positioned(
              top: 10,
              right: widget.cellWidth / 2 - 13.5,
              child: destination.badge!,
            ),
        ],
      ),
    );
    // Tooltips need an Overlay; the app always has one, a bare widget test may
    // not. The semantics label still carries the name either way.
    if (Overlay.maybeOf(context) != null) {
      body = Tooltip(
        message: destination.label,
        excludeFromSemantics: true,
        preferBelow: false,
        verticalOffset: 40,
        waitDuration: const Duration(milliseconds: 600),
        child: body,
      );
    }
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: destination.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: body,
    );
  }
}

/// Circular avatar for the bar's third entry.
///
/// Split out of the page so the fallback rules are testable without a login:
/// signed out, empty face URL and image errors all end on the same stable
/// glyph instead of an empty hole in the glass.
class LiquidGlassAvatar extends StatelessWidget {
  const LiquidGlassAvatar({
    super.key,
    required this.isLoggedIn,
    required this.face,
    this.size = kLiquidNavAvatarSize,
    this.imageBuilder,
  });

  final bool isLoggedIn;
  final String face;
  final double size;

  /// Test seam: replaces the network image so a widget test never touches the
  /// network stack.
  final Widget Function(BuildContext context, String url)? imageBuilder;

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn || face.isEmpty) {
      return _placeholder(context);
    }
    final image = imageBuilder?.call(context, face);
    if (image != null) {
      return ClipOval(
        child: SizedBox(width: size, height: size, child: image),
      );
    }
    return NetworkImgLayer(
      type: .avatar,
      width: size,
      height: size,
      src: face,
      getPlaceHolder: () => _placeholder(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Icon(
      Icons.person_rounded,
      size: size,
      color: isDark ? const Color(0xCCFFFFFF) : const Color(0xCC000000),
    );
  }
}
