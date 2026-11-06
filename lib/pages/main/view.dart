import 'dart:io';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/floating_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/liquid_glass_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:PiliPlus/common/widgets/native_liquid_glass_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends PopScopeState<MainApp>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver {
  final _mainController = Get.put(MainController());
  late EdgeInsets _padding;
  late ColorScheme _colorScheme;
  Brightness? _brightness;

  /// Set when the native platform view could not be created. The bar then uses
  /// the Flutter material, and this session is never reported as a native pass.
  bool _nativeGlassFailed = false;
  bool _loggedGlassFallback = false;

  @override
  bool get initCanPop => false;

  @override
  void initState() {
    super.initState();
    addObserverMobile(this);
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.init();
      TrayController.instance.init();
    }
    if (!Platform.isMacOS) {
      PiliScheme.init();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _padding = MediaQuery.viewPaddingOf(context);
    _colorScheme = ColorScheme.of(context);
    final brightness = _colorScheme.brightness;
    NetworkImgLayer.reduce =
        NetworkImgLayer.reduceLuxColor != null && brightness.isDark;
    if (PlatformUtils.isDesktop) {
      if (_brightness != brightness) {
        _brightness = brightness;
        nativeapi.Application.instance.setBrightness(
          brightness == .dark ? .dark : .light,
        );
      }
    }
    if (!_mainController.useSideBar) {
      _mainController.useBottomNav = MediaQuery.sizeOf(context).isPortrait;
    }
  }

  @override
  void didPopNext() {
    addObserverMobile(this);
    _mainController
      ..checkUnreadDynamic()
      ..checkDefaultSearch(true)
      ..checkUnread(_mainController.useBottomNav);
    super.didPopNext();
  }

  @override
  void didPushNext() {
    removeObserverMobile(this);
    super.didPushNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.dispose();
      TrayController.instance.dispose();
    }
    removeObserverMobile(this);
    PiliScheme.listener?.cancel();
    GStorage.close();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyR &&
        HardwareKeyboard.instance.isMetaPressed &&
        _mainController.refreshRecommendations();
  }

  @pragma('vm:prefer-inline')
  static void _onBack() {
    if (Platform.isAndroid) {
      AndroidHelper.back();
    }
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (_mainController.directExitOnBack) {
      _onBack();
    } else {
      if (_mainController.selectedIndex.value != 0) {
        _mainController
          ..setIndex(0)
          ..barOffset?.value = 0.0
          ..showBottomBar?.value = true
          ..setSearchBar();
      } else {
        _onBack();
      }
    }
  }

  Widget? get _bottomNav {
    Widget? bottomNav;
    if (_mainController.navigationBars.length > 1) {
      if (_mainController.liquidGlassNavBar) {
        // The capability answer is fetched before the first frame, so this is
        // synchronous and the shader never appears on a device that can render
        // UIGlassEffect.
        final capabilities = NativeLiquidGlassNavigation.cachedCapabilities;
        final useNative =
            !_nativeGlassFailed && (capabilities?.usesUIGlassEffect ?? false);
        if (!useNative && !_loggedGlassFallback) {
          _loggedGlassFallback = true;
          if (kDebugMode) {
            debugPrint(
              '[native-glass] Flutter fallback: '
              '${capabilities?.unsupportedReason ?? 'unsupported'}',
            );
          }
        }
        if (useNative) {
          bottomNav = Obx(_nativeGlassBar);
        } else {
          bottomNav = Obx(
            () => LiquidGlassNavigationBar(
              selectedIndex: _mainController.selectedIndex.value,
              onDestinationSelected: _mainController.setIndex,
              // MainApp removed the ambient padding for the bar subtree; the
              // real inset is handed over explicitly so it is counted once.
              bottomInset: _padding.bottom,
              destinations: _mainController.navigationBars
                  .map(_buildLiquidDestination)
                  .toList(),
            ),
          );
        }
      } else if (_mainController.floatingNavBar) {
        bottomNav = Obx(
          () => FloatingNavigationBar(
            onDestinationSelected: _mainController.setIndex,
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => FloatingNavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else if (_mainController.enableMYBar) {
        bottomNav = Obx(
          () => NavigationBar(
            maintainBottomViewPadding: true,
            onDestinationSelected: _mainController.setIndex,
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => NavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else {
        bottomNav = Obx(
          () => BottomNavigationBar(
            currentIndex: _mainController.selectedIndex.value,
            onTap: _mainController.setIndex,
            iconSize: 16,
            selectedFontSize: 12,
            unselectedFontSize: 12,
            type: .fixed,
            items: _mainController.navigationBars
                .map(
                  (e) => BottomNavigationBarItem(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    activeIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      }

      if (_mainController.hideBottomBar) {
        if (_mainController.barOffset case final barOffset?) {
          return Obx(
            () {
              // Off-screen bars must not eat taps or keep a semantics node.
              final hidden = barOffset.value >= Style.topBarHeight - 0.5;
              return ExcludeSemantics(
                excluding: hidden,
                child: IgnorePointer(
                  ignoring: hidden,
                  child: FractionalTranslation(
                    translation: Offset(
                      0.0,
                      barOffset.value / Style.topBarHeight,
                    ),
                    child: bottomNav,
                  ),
                ),
              );
            },
          );
        }
        if (_mainController.showBottomBar case final showBottomBar?) {
          return Obx(
            () => ExcludeSemantics(
              excluding: !showBottomBar.value,
              child: IgnorePointer(
                ignoring: !showBottomBar.value,
                child: AnimatedSlide(
                  curve: Curves.easeInOutCubicEmphasized,
                  duration: const Duration(milliseconds: 500),
                  offset: Offset(0, showBottomBar.value ? 0 : 1),
                  child: bottomNav,
                ),
              ),
            ),
          );
        }
      }
    }

    return bottomNav;
  }

  /// Native capsule, controlled by [MainController] exactly like the Flutter
  /// bar: ids are the enum names, the index is resolved against the ordering
  /// that is on screen when the tap arrives, and the haptic stays in setIndex.
  Widget _nativeGlassBar() {
    final controller = _mainController;
    final bars = controller.navigationBars;
    final selected = controller.selectedIndex.value.clamp(0, bars.length - 1);
    final account = controller.accountService;
    // A platform view always sits above Flutter content, so a dialog, a bottom
    // sheet or a pushed page would otherwise be covered by the capsule. The
    // main route stops being current the moment anything is pushed on top.
    final route = ModalRoute.of(context);
    final obscured = route != null && !route.isCurrent;
    return NativeLiquidGlassNavigationBar(
      selectedId: bars[selected].name,
      destinations: bars.map(_buildNativeDestination).toList(),
      avatarUrl: account.isLogin.value ? account.face.value : '',
      visible: !_barHidden() && !obscured,
      bottomInset: _padding.bottom,
      onDestinationSelected: (index) {
        final current = controller.navigationBars;
        if (index < 0 || index >= current.length) return;
        controller.setIndex(index);
      },
      onUnavailable: () {
        if (!mounted) return;
        debugPrint(
          '[native-glass] platform view unavailable; using the Flutter '
          'material for this session',
        );
        setState(() => _nativeGlassFailed = true);
      },
    );
  }

  /// Mirrors the hide logic applied to every bottom bar, so the native view can
  /// drop accessibility and interaction while it is off screen.
  bool _barHidden() {
    if (!_mainController.hideBottomBar) return false;
    if (_mainController.barOffset case final offset?) {
      return offset.value >= Style.topBarHeight - 0.5;
    }
    if (_mainController.showBottomBar case final show?) {
      return !show.value;
    }
    return false;
  }

  NativeLiquidGlassDestination _buildNativeDestination(NavigationBarType type) {
    final badge = _nativeBadge(type);
    return NativeLiquidGlassDestination(
      id: type.name,
      label: type.label,
      // Only the 动态 glyph comes from the shared navigation config: 首页 and
      // 我的 keep the designs that were already approved for the glass bar.
      icon: switch (type) {
        .home => Icons.home_outlined,
        .dynamics => type.icon.icon!,
        .mine => Icons.person_rounded,
      },
      selectedIcon: switch (type) {
        .home => Icons.home_rounded,
        .dynamics => type.selectIcon.icon!,
        .mine => Icons.person_rounded,
      },
      isAvatar: type == .mine,
      badgeVisible: badge.visible,
      badgeText: badge.text,
      badgeIsDot: badge.isDot,
      accessibilityValue: badge.accessibilityValue,
    );
  }

  ({bool visible, String? text, bool isDot, String? accessibilityValue})
  _nativeBadge(NavigationBarType type) {
    const hidden = (
      visible: false,
      text: null,
      isDot: false,
      accessibilityValue: null,
    );
    if (type != .dynamics) return hidden;
    final count = _mainController.dynCount.value;
    final mode = _mainController.dynamicBadgeMode;
    if (count <= 0 || mode == DynamicBadgeMode.hidden) return hidden;
    final isDot = mode != DynamicBadgeMode.number;
    return (
      visible: true,
      text: isDot ? null : (count > 99 ? '99+' : '$count'),
      isDot: isDot,
      accessibilityValue: '$count 条未读',
    );
  }

  Widget _sideBar() {
    if (_mainController.navigationBars.length > 1) {
      if (context.isTablet && _mainController.optTabletNav) {
        return Padding(
          padding: const .only(top: 25),
          child: MediaQuery.removePadding(
            context: context,
            removeRight: true,
            child: Obx(
              () => DrawerTheme(
                data: DrawerThemeData(
                  width:
                      (_mainController.hideSideBarLabel ? 80 : 130) +
                      _padding.left,
                ),
                child: NavigationDrawer(
                  /// apply `lib/scripts/navigation_drawer.patch`
                  flex: 5,
                  backgroundColor: Colors.transparent,
                  onDestinationSelected: _mainController.setIndex,
                  selectedIndex: _mainController.selectedIndex.value,
                  header: Expanded(flex: 4, child: userAndSearchVertical()),
                  tilePadding: const .symmetric(vertical: 5, horizontal: 12),
                  indicatorShape: _mainController.hideSideBarLabel
                      ? const RoundedRectangleBorder(
                          borderRadius: .all(.circular(12)),
                        )
                      : const RoundedRectangleBorder(
                          borderRadius: .all(.circular(16)),
                        ),
                  children: _mainController.navigationBars
                      .map(
                        (e) => NavigationDrawerDestination(
                          label: _mainController.hideSideBarLabel
                              ? Semantics(
                                  label: e.label,
                                  child: const SizedBox.shrink(),
                                )
                              : Text(e.label),
                          icon: _buildIcon(type: e),
                          selectedIcon: _buildIcon(
                            type: e,
                            selected: true,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        );
      }
      return Obx(
        () => NavigationRail(
          groupAlignment: 0.5,
          labelType: _mainController.hideSideBarLabel ? .none : .selected,
          leading: userAndSearchVertical(),
          backgroundColor: Colors.transparent,
          onDestinationSelected: _mainController.setIndex,
          selectedIndex: _mainController.selectedIndex.value,
          destinations: _mainController.navigationBars
              .map(
                (e) => NavigationRailDestination(
                  label: Text(e.label),
                  icon: _buildIcon(type: e),
                  selectedIcon: _buildIcon(type: e, selected: true),
                ),
              )
              .toList(),
        ),
      );
    }
    return Container(
      width: 80,
      margin: .only(top: 12 + _padding.top, left: _padding.left),
      child: userAndSearchVertical(),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_mainController.mainTabBarView) {
      child = TabBarView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        scrollDirection: _mainController.useBottomNav ? .horizontal : .vertical,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    } else {
      child = PageView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    }

    Widget? sideBar;
    Widget? bottomNav;
    final EdgeInsets padding;
    if (_mainController.useBottomNav) {
      bottomNav = _bottomNav;
      if (bottomNav != null) {
        // MainLayout pins the bar to the bottom edge and the bar widgets apply
        // their own SafeArea, so the ambient insets must not be inherited here.
        // Only removing the top inset left the bottom 34 pt double-counted on
        // iPhone Air: the bar drew its labels above an empty strip the height
        // of the home-indicator inset.
        bottomNav = MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: bottomNav,
        );
      }
      padding = _padding.copyWith(bottom: 0);
    } else {
      sideBar = DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: _colorScheme.outline.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: _sideBar(),
      );
      padding = .only(top: _padding.top, right: _padding.right);
    }

    child = Material(
      child: MainLayout(
        sideBar: sideBar,
        bottomNav: bottomNav,
        body: Padding(padding: padding, child: child),
      ),
    );

    if (PlatformUtils.isMobile) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: _colorScheme.brightness,
          statusBarIconBrightness: _colorScheme.brightness.reverse,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: _colorScheme.brightness.reverse,
        ),
        child: child,
      );
    }

    return child;
  }

  /// One entry of the liquid-glass bar. Icons are built here, not inside the
  /// bar, so the bar stays a pure material/layout widget.
  LiquidGlassDestination _buildLiquidDestination(NavigationBarType type) {
    switch (type) {
      case .home:
        return LiquidGlassDestination(
          label: type.label,
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
        );
      case .dynamics:
        return LiquidGlassDestination(
          label: type.label,
          icon: type.icon,
          selectedIcon: type.selectIcon,
          badge: _liquidDynamicsBadge(),
        );
      case .mine:
        return LiquidGlassDestination(
          label: type.label,
          icon: _liquidAvatar(),
          selectedIcon: _liquidAvatar(),
          isAvatar: true,
        );
    }
  }

  /// Unread marker for 动态. Replaces the Material [Badge] because that one
  /// changes the icon's layout box, and the glass bar needs the glyph centred.
  Widget _liquidDynamicsBadge() {
    return Obx(() {
      final count = _mainController.dynCount.value;
      if (count <= 0 ||
          _mainController.dynamicBadgeMode == DynamicBadgeMode.hidden) {
        return const SizedBox.shrink();
      }
      const color = Color(0xFFFB7299);
      if (_mainController.dynamicBadgeMode == DynamicBadgeMode.number) {
        return Container(
          constraints: const BoxConstraints(minWidth: 14),
          height: 14,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0x66000000), width: 0.5),
          ),
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(
              fontSize: 9,
              height: 1.1,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x66000000), width: 0.5),
        ),
      );
    });
  }

  /// Signed-in avatar, or a stable placeholder when logged out / no face URL /
  /// image error. [NetworkImgLayer] falls back to its placeholder itself.
  Widget _liquidAvatar() {
    return Obx(
      () {
        final account = _mainController.accountService;
        return LiquidGlassAvatar(
          isLoggedIn: account.isLogin.value,
          face: account.face.value,
        );
      },
    );
  }

  Widget _buildIcon({required NavigationBarType type, bool selected = false}) {
    final icon = selected ? type.selectIcon : type.icon;
    return type == .dynamics
        ? Obx(
            () {
              final dynCount = _mainController.dynCount.value;
              return Badge(
                isLabelVisible: dynCount > 0,
                label: _mainController.dynamicBadgeMode == .number
                    ? Text(dynCount.toString())
                    : null,
                padding: const .symmetric(horizontal: 6),
                child: icon,
              );
            },
          )
        : icon;
  }

  Widget userAndSearchVertical() {
    return Column(
      children: [
        userAvatar(colorScheme: _colorScheme, mainController: _mainController),
        const SizedBox(height: 8),
        msgBadge(_mainController),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(
            Icons.search_outlined,
            semanticLabel: '搜索',
          ),
          onPressed: () => Get.toNamed('/search'),
        ),
      ],
    );
  }
}
