import 'package:flutter/foundation.dart';

/// Local-only AI card actions. These never call Bilibili's dislike/blacklist
/// endpoints; they only update the local profile.
@immutable
class AiCardActions {
  const AiCardActions({
    required this.reason,
    required this.onMore,
    required this.onLess,
    required this.onUndo,
  });

  final String reason;
  final VoidCallback onMore;
  final VoidCallback onLess;
  final VoidCallback onUndo;
}
