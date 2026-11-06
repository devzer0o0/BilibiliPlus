import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart'
    show BackdropFilterLayer, PaintingContext, RenderProxyBox;
import 'package:material_ui/material_ui.dart';

/// How the capsule gets its glass.
///
/// - [refraction]: real per-pixel background sampling through
///   `ImageFilter.shader`. Only available with Impeller.
/// - [blur]: plain backdrop blur with the same tint and highlight. Same
///   geometry, same hit testing, no refraction.
/// - [solid]: opaque-ish fill for high contrast / reduce transparency.
enum LiquidGlassMode { refraction, blur, solid }

/// Cached [ui.FragmentProgram]. The program is compiled once per process and
/// shared by every [LiquidGlassSurface]; each surface owns one
/// [ui.FragmentShader] instance so uniforms never race between bars.
abstract final class LiquidGlassShaderCache {
  static const String asset = 'assets/liquid_glass/liquid_nav.frag';

  static Future<ui.FragmentProgram?>? _program;
  static bool _failed = false;

  /// Loads the program, or returns null when the asset is missing or the
  /// backend cannot compile it. Never throws: the bar has to keep working.
  static Future<ui.FragmentProgram?> load() {
    if (_failed) return Future<ui.FragmentProgram?>.value();
    return _program ??= _load();
  }

  static Future<ui.FragmentProgram?> _load() async {
    try {
      return await ui.FragmentProgram.fromAsset(asset);
    } catch (error, stack) {
      _failed = true;
      if (kDebugMode) {
        debugPrint('[liquid-glass] shader load failed: $error');
        debugPrintStack(stackTrace: stack);
      }
      return null;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _program = null;
    _failed = false;
  }
}

/// The glass capsule: backdrop sample, tint, hairline highlight.
///
/// The widget paints the whole material and then [child] on top. Icons are
/// therefore never displaced or blurred by the shader.
class LiquidGlassSurface extends StatefulWidget {
  const LiquidGlassSurface({
    super.key,
    required this.width,
    required this.height,
    required this.radius,
    required this.child,
    this.mode,
    this.blurSigma = 8,
    this.edgeWidth = 13,
    this.refraction = 9,
    this.zoom = 0.015,
    this.debugBounds = false,
  });

  final double width;
  final double height;
  final double radius;
  final Widget child;

  /// Forces a rendering mode. `null` picks the best mode the device supports.
  final LiquidGlassMode? mode;

  final double blurSigma;

  /// Width of the refracting rim, logical pixels.
  final double edgeWidth;

  /// Peak outward displacement at the rim, logical pixels.
  final double refraction;

  /// Magnification of the centre, 0..1.
  final double zoom;

  /// Paints the area the shader believes is outside the capsule. Lab only.
  final bool debugBounds;

  @override
  State<LiquidGlassSurface> createState() => _LiquidGlassSurfaceState();
}

class _LiquidGlassSurfaceState extends State<LiquidGlassSurface> {
  ui.FragmentShader? _shader;
  LiquidGlassMode? _lastLoggedMode;

  bool get _needsShader =>
      widget.mode == null || widget.mode == LiquidGlassMode.refraction;

  @override
  void initState() {
    super.initState();
    if (_needsShader && ui.ImageFilter.isShaderFilterSupported) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    final program = await LiquidGlassShaderCache.load();
    if (!mounted || program == null) return;
    setState(() {
      _shader = program.fragmentShader();
    });
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  LiquidGlassMode _resolveMode(BuildContext context) {
    final forced = widget.mode;
    if (forced != null) return forced;
    // High contrast needs readable, predictable pixels; refraction is not.
    if (MediaQuery.highContrastOf(context)) return LiquidGlassMode.solid;
    if (!ui.ImageFilter.isShaderFilterSupported) return LiquidGlassMode.blur;
    // The asset loads asynchronously; the first frames fall back to blur.
    if (_shader == null) return LiquidGlassMode.blur;
    return LiquidGlassMode.refraction;
  }

  @override
  Widget build(BuildContext context) {
    final mode = _resolveMode(context);
    if (kDebugMode && mode != _lastLoggedMode) {
      _lastLoggedMode = mode;
      debugPrint('[liquid-glass] render mode: ${mode.name}');
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipPath(
            clipper: _CapsuleClipper(widget.radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildBackdrop(context, mode, isDark),
                CustomPaint(
                  painter: _GlassPaint(
                    radius: widget.radius,
                    isDark: isDark,
                    mode: mode,
                  ),
                ),
              ],
            ),
          ),
          widget.child,
        ],
      ),
    );
  }

  Widget _buildBackdrop(
    BuildContext context,
    LiquidGlassMode mode,
    bool isDark,
  ) {
    switch (mode) {
      case LiquidGlassMode.refraction:
        return _ShaderBackdropFilter(
          shader: _shader!,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          radius: widget.radius,
          edgeWidth: widget.edgeWidth,
          refraction: widget.refraction,
          zoom: widget.zoom,
          blurSigma: widget.blurSigma,
          debugBounds: widget.debugBounds,
        );
      case LiquidGlassMode.blur:
        return BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: widget.blurSigma,
            sigmaY: widget.blurSigma,
            tileMode: TileMode.decal,
          ),
          child: const SizedBox.expand(),
        );
      case LiquidGlassMode.solid:
        return ColoredBox(
          color: isDark ? const Color(0xFF1A1A1C) : const Color(0xFFF1F1F4),
        );
    }
  }
}

class _CapsuleClipper extends CustomClipper<Path> {
  const _CapsuleClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) {
    final r = radius.clamp(0.0, size.shortestSide / 2);
    return Path()..addRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r)),
    );
  }

  @override
  bool shouldReclip(_CapsuleClipper oldClipper) => oldClipper.radius != radius;
}

/// Backdrop filter that rebuilds its shader uniforms from the paint-time
/// geometry. No GlobalKey, no post-frame callback: the transform used for the
/// sample is the one the layer is about to be painted with.
class _ShaderBackdropFilter extends SingleChildRenderObjectWidget {
  const _ShaderBackdropFilter({
    required this.shader,
    required this.devicePixelRatio,
    required this.radius,
    required this.edgeWidth,
    required this.refraction,
    required this.zoom,
    required this.blurSigma,
    required this.debugBounds,
  });

  final ui.FragmentShader shader;
  final double devicePixelRatio;
  final double radius;
  final double edgeWidth;
  final double refraction;
  final double zoom;
  final double blurSigma;
  final bool debugBounds;

  @override
  _RenderShaderBackdropFilter createRenderObject(BuildContext context) {
    return _RenderShaderBackdropFilter(
      shader: shader,
      devicePixelRatio: devicePixelRatio,
      radius: radius,
      edgeWidth: edgeWidth,
      refraction: refraction,
      zoom: zoom,
      blurSigma: blurSigma,
      debugBounds: debugBounds,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderShaderBackdropFilter)
      ..shader = shader
      ..devicePixelRatio = devicePixelRatio
      ..radius = radius
      ..edgeWidth = edgeWidth
      ..refraction = refraction
      ..zoom = zoom
      ..blurSigma = blurSigma
      ..debugBounds = debugBounds
      ..markNeedsPaint();
  }
}

class _RenderShaderBackdropFilter extends RenderProxyBox {
  _RenderShaderBackdropFilter({
    required this.shader,
    required this.devicePixelRatio,
    required this.radius,
    required this.edgeWidth,
    required this.refraction,
    required this.zoom,
    required this.blurSigma,
    required this.debugBounds,
  });

  ui.FragmentShader shader;
  double devicePixelRatio;
  double radius;
  double edgeWidth;
  double refraction;
  double zoom;
  double blurSigma;
  bool debugBounds;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final dpr = devicePixelRatio;
    // Absolute position of the capsule when this layer is painted: derived from
    // the very transform the layer is about to use, not from a GlobalKey or a
    // post-frame callback.
    final origin = localToGlobal(Offset.zero);
    // Uniform order matches liquid_nav.frag: the engine owns 0/1 (u_size) and
    // the sampler, everything below is ours.
    final shader = this.shader
      ..setFloat(2, origin.dx * dpr)
      ..setFloat(3, origin.dy * dpr)
      ..setFloat(4, size.width * dpr)
      ..setFloat(5, size.height * dpr)
      ..setFloat(6, radius * dpr)
      ..setFloat(7, edgeWidth * dpr)
      ..setFloat(8, refraction * dpr)
      ..setFloat(9, zoom)
      ..setFloat(10, debugBounds ? 1.0 : 0.0);

    // Blur first, then refract: the shader samples a softened backdrop, which is
    // what makes the material read as glass instead of a cut-out.
    final shaderFilter = ui.ImageFilter.shader(shader);
    final filter = blurSigma > 0
        ? ui.ImageFilter.compose(
            outer: shaderFilter,
            inner: ui.ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
              tileMode: TileMode.decal,
            ),
          )
        : shaderFilter;
    final layer = (this.layer ??= BackdropFilterLayer()) as BackdropFilterLayer
      ..filter = filter;
    context.pushLayer(layer, super.paint, offset);
  }
}

/// Tint, inner hairline and the soft top sheen. One painter for the whole
/// material so the capsule stays a single draw call.
class _GlassPaint extends CustomPainter {
  const _GlassPaint({
    required this.radius,
    required this.isDark,
    required this.mode,
  });

  final double radius;
  final bool isDark;
  final LiquidGlassMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // The reference over black reads as pure black inside, so the dark material
    // may only ever subtract light. The tint below is that subtraction; the
    // highlight is a separate 1 pt rim, not a wash.
    final tintTop = isDark ? const Color(0x5E000000) : const Color(0x8AFFFFFF);
    final tintBottom = isDark
        ? const Color(0x45000000)
        : const Color(0x66FFFFFF);
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tintTop, tintBottom],
        ).createShader(rect),
    );

    if (mode == LiquidGlassMode.solid) return;

    // 1 pt rim: peak ~0.17 white on the boundary, fading over ~1.5 px, which is
    // what the recording shows on both the top and bottom edges.
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.15 : 0.6),
          Colors.white.withValues(alpha: isDark ? 0.11 : 0.5),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect.deflate(0.5), rim);

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2)
      ..color = Colors.white.withValues(alpha: isDark ? 0.03 : 0.12);
    canvas.drawRRect(rrect.deflate(0.6), glow);
  }

  @override
  bool shouldRepaint(_GlassPaint oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.isDark != isDark ||
        oldDelegate.mode != mode;
  }
}
