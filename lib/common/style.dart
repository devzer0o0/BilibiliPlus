import 'dart:math' as math;

import 'package:flutter/widgets.dart' show BuildContext, MediaQuery;
import 'package:material_ui/material_ui.dart'
    show BorderRadius, Radius, BoxConstraints, ButtonStyle, VisualDensity;

abstract final class Style {
  static const cardSpace = 8.0;
  static const safeSpace = 12.0;
  static const mdRadius = BorderRadius.all(imgRadius);
  static const imgRadius = Radius.circular(10);
  static const borderRadius6 = BorderRadius.all(.circular(6));
  static const aspectRatio = 16 / 10;
  static const aspectRatio16x9 = 16 / 9;
  static const aspectRatio3x4 = 3 / 4;
  static const imgMaxRatio = 2.6;
  static const bottomSheetRadius = BorderRadius.vertical(top: .circular(18));

  /// Keep dialogs inside narrow phones such as the 420 pt iPhone Air.
  static BoxConstraints dialogFixedConstraintsFor(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return BoxConstraints.tightFor(
      width: math.max(0, math.min(420, width - 32)),
    );
  }

  static const topBarHeight = 52.0;
  static const buttonStyle = ButtonStyle(
    visualDensity: VisualDensity(horizontal: -2, vertical: -1.25),
    tapTargetSize: .shrinkWrap,
  );
  static const placeHolder = '\uFFFC';
}
