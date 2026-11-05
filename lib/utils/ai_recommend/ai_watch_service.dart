// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_initializing_formals
import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/ai_recommend/watch_interval_accumulator.dart';

/// Bridges the player's unified snapshot stream to local watch learning.
///
/// It is attached only when the AI feature is enabled. Both mpv and the native
/// HDR path publish through [PlPlayerController.applySnapshot], so neither
/// backend needs its own recorder. Writes happen at most every two minutes and
/// on pause/completion/context change, never per frame.
class AiWatchService {
  AiWatchService._();

  static final AiWatchService instance = AiWatchService._();

  final WatchIntervalAccumulator _accumulator = WatchIntervalAccumulator();
  final Stopwatch _wall = Stopwatch()..start();
  PlPlayerController? _player;
  String? _bvid;
  int? _cid;
  String _title = '';
  int? _ownerMid;
  String _backend = 'unknown';
  String _scope = AccountScope.anonymous;
  int _durationMs = 0;
  int _lastPersistMs = 0;
  bool _persisting = false;

  void attach(PlPlayerController player) {
    if (_player == player) return;
    if (_player != null) {
      _player!.removeSnapshotListener(_onSnapshot);
    }
    _player = player..addSnapshotListener(_onSnapshot);
  }

  void detach() {
    _player?.removeSnapshotListener(_onSnapshot);
    _player = null;
  }

  /// Called by the video page once it knows which item is playing.
  void setContext({
    required String bvid,
    required int? cid,
    String? title,
    int? ownerMid,
  }) {
    if (bvid.isEmpty) return;
    final sameItem = _bvid == bvid && _cid == cid;
    if (!sameItem) {
      _persist();
      _accumulator.reset();
      _durationMs = 0;
      _lastPersistMs = 0;
    }
    _bvid = bvid;
    _cid = cid;
    if (title != null && title.trim().isNotEmpty) {
      _title = title.trim();
    }
    if (ownerMid != null && ownerMid > 0) _ownerMid = ownerMid;
    _scope = AiRecommendationService.instance.recommendScope;
  }

  void clearContext() {
    _persist();
    _accumulator.reset();
    _bvid = null;
    _cid = null;
    _title = '';
    _ownerMid = null;
    _durationMs = 0;
    _lastPersistMs = 0;
  }

  Future<void> finish() async {
    _persist();
    _accumulator.reset();
    _lastPersistMs = 0;
  }

  void _onSnapshot(PlaybackSnapshot snapshot) {
    final settings = AiRecommendationService.instance.settings;
    if (!settings.enabled ||
        !settings.useWatchHistory ||
        settings.pausedLearning) {
      return;
    }
    if (_bvid == null || _scope == AccountScope.anonymous) return;
    if (snapshot.hasError) return;
    if (snapshot.duration > Duration.zero) {
      _durationMs = snapshot.duration.inMilliseconds;
    }
    _backend = snapshot.backend.name;

    _accumulator.onTick(
      WatchTick(
        positionMs: snapshot.position.inMilliseconds,
        durationMs: _durationMs,
        playing: snapshot.playing,
        buffering: snapshot.buffering,
        ready: snapshot.ready,
        generation: snapshot.generation,
        completed: snapshot.completed,
        rate: snapshot.rate,
        backend: _backend,
      ),
      _wall.elapsedMilliseconds,
    );

    final now = _wall.elapsedMilliseconds;
    final earned = _accumulator.effectiveMs >= 30000;
    final pausedLongEnough = !snapshot.playing && now - _lastPersistMs > 30000;
    final periodic = now - _lastPersistMs > 120000;
    if (earned && (snapshot.completed || pausedLongEnough || periodic)) {
      _persist();
    }
  }

  void _persist() {
    if (_persisting) return;
    if (_bvid == null || _title.isEmpty || _durationMs <= 0) return;
    if (_accumulator.effectiveMs < 30000) return;
    final signal = _accumulator.buildSignal(
      bvid: _bvid!,
      cid: _cid,
      title: _title,
      ownerMid: _ownerMid,
      durationMs: _durationMs,
      at: DateTime.now(),
      backend: _backend,
      accountScope: _scope,
    );
    if (signal == null) return;
    _lastPersistMs = _wall.elapsedMilliseconds;
    _persisting = true;
    unawaited(
      AiRecommendationService.instance
          .recordWatch(signal)
          .catchError((Object _) => false)
          .whenComplete(() => _persisting = false),
    );
  }
}
