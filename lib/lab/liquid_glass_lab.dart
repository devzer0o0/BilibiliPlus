// A deliberately small, deletable screen used to verify the liquid-glass
// material on a real renderer before it is trusted inside the app shell.
//
//   flutter run -d <device> -t lib/lab/liquid_glass_lab.dart
//
// It is not part of any route and nothing imports it.
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/liquid_glass_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/liquid_glass_surface.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:material_ui/material_ui.dart';

const double _labBlur =
    int.fromEnvironment('GLASS_BLUR', defaultValue: 8) * 1.0;

void main() => runApp(const GlassLabApp());

class GlassLabApp extends StatelessWidget {
  const GlassLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const GlassLab(),
    );
  }
}

class GlassLab extends StatefulWidget {
  const GlassLab({super.key});

  @override
  State<GlassLab> createState() => _GlassLabState();
}

class _GlassLabState extends State<GlassLab> {
  int _index = 0;
  LiquidGlassMode? _mode = switch (const String.fromEnvironment('GLASS_MODE')) {
    'refraction' => LiquidGlassMode.refraction,
    'blur' => LiquidGlassMode.blur,
    'solid' => LiquidGlassMode.solid,
    _ => null,
  };
  bool _debug = const bool.fromEnvironment('GLASS_DEBUG');
  bool _light = const bool.fromEnvironment('GLASS_LIGHT');
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Park the list on the dark reference-like panel so the capsule sits over
    // the same kind of background the recording shows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Theme(
      data: _light
          ? ThemeData(
              brightness: Brightness.light,
              scaffoldBackgroundColor: Colors.white,
            )
          : ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: Colors.black,
            ),
      child: MediaQuery(
        data: media.copyWith(
          size: const Size(420, 912),
          padding: const EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Material(
            child: Stack(
              children: [
                MainLayout(
                  sideBar: null,
                  body: _content(context),
                  bottomNav: LiquidGlassNavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    bottomInset: media.viewPadding.bottom,
                    mode: _mode,
                    blurSigma: _labBlur,
                    debugBounds: _debug,
                    destinations: const [
                      LiquidGlassDestination(
                        label: '首页',
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                      ),
                      LiquidGlassDestination(
                        label: '动态',
                        icon: Icon(Icons.smart_display_outlined),
                        selectedIcon: Icon(Icons.smart_display),
                      ),
                      LiquidGlassDestination(
                        label: '我的',
                        icon: Icon(Icons.person_rounded),
                        selectedIcon: Icon(Icons.person_rounded),
                        isAvatar: true,
                      ),
                    ],
                  ),
                ),
                Positioned(top: 56, left: 8, right: 8, child: _controls()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final label = _mode?.name ?? 'auto';
    return Wrap(
      spacing: 6,
      children: [
        for (final mode in [
          null,
          LiquidGlassMode.refraction,
          LiquidGlassMode.blur,
          LiquidGlassMode.solid,
        ])
          FilledButton.tonal(
            onPressed: () => setState(() => _mode = mode),
            child: Text(
              mode?.name ?? 'auto',
              style: const TextStyle(fontSize: 11),
            ),
          ),
        const SizedBox(width: 8),
        FilledButton.tonal(
          onPressed: () => setState(() => _debug = !_debug),
          child: Text('debug:$_debug', style: const TextStyle(fontSize: 11)),
        ),
        FilledButton.tonal(
          onPressed: () => setState(() => _light = !_light),
          child: Text(
            _light ? 'light' : 'dark',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 1, color: Colors.transparent),
        ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemCount: 16,
      itemBuilder: (context, i) {
        if (i == 15) return _darkPanel();
        switch (i % 5) {
          case 0:
            return _row(
              '高对比文字 HIGH CONTRAST $i — the quick brown fox jumps over the lazy dog 0123456789',
              Colors.black,
              Colors.white,
            );
          case 1:
            return _row(
              '浅色背景 light row $i — THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG',
              Colors.white,
              Colors.black,
            );
          case 2:
            return const SizedBox(
              height: 150,
              child: CustomPaint(painter: _CheckerPainter(cell: 14)),
            );
          case 3:
            return Container(
              height: 130,
              color: Colors.black,
              child: const Row(
                children: [
                  Expanded(child: ColoredBox(color: Color(0xFF2E5BFF))),
                  Expanded(child: ColoredBox(color: Color(0xFFFF4D67))),
                  Expanded(child: ColoredBox(color: Color(0xFF19C37D))),
                  Expanded(child: ColoredBox(color: Color(0xFFFFC53D))),
                ],
              ),
            );
          default:
            return _strip(i);
        }
      },
    );
  }

  /// Near-black panel with light text and a photo strip: the reference's own
  /// situation (bar over a dark list row) at the same logical size.
  Widget _darkPanel() {
    return Container(
      height: 640,
      color: const Color(0xFF050505),
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Buying and Selling AI Glasses: Why This Pair Stood the Test of Time | A Memo',
            style: TextStyle(
              color: Color(0xFFE8E8E8),
              fontSize: 22,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '神烦老狗  ▷ 4.5K  1d ago   ·   19:49',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: const CustomPaint(
                painter: _StripPainter(seed: 3),
                child: SizedBox.expand(),
              ),
            ),
          ),
          const Spacer(),
          const Text(
            '内容从玻璃下方滚过 · content scrolls under the glass',
            style: TextStyle(color: Color(0xFFBFBFBF), fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _row(String text, Color bg, Color fg) {
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _strip(int seed) {
    return SizedBox(
      height: 190,
      child: CustomPaint(painter: _StripPainter(seed: seed)),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.cell});

  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0xFFEDEDED);
    final dark = Paint()..color = const Color(0xFF1B1B1B);
    canvas.drawRect(Offset.zero & size, light);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isEven) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => oldDelegate.cell != cell;
}

/// Poster-like colour ramp so the capsule passes over saturated and dark
/// material, the way the reference passes over cover art.
class _StripPainter extends CustomPainter {
  const _StripPainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ramp = [
      const Color(0xFF0E1A2B),
      const Color(0xFF1F7A8C),
      const Color(0xFFE4B363),
      const Color(0xFFE8E9EB),
    ];
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: ramp,
        ).createShader(rect),
    );
    for (var i = 0; i < 7; i++) {
      final t = (i + 1) / 8;
      canvas.drawCircle(
        Offset(size.width * t, size.height * (0.3 + 0.4 * math.sin(seed + i))),
        14 + 10 * (i % 3),
        Paint()..color = Colors.white.withValues(alpha: 0.22),
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 26, size.width, 26),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
  }

  @override
  bool shouldRepaint(_StripPainter oldDelegate) => oldDelegate.seed != seed;
}
