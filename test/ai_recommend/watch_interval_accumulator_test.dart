import 'package:PiliPlus/utils/ai_recommend/watch_interval_accumulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal playback credits wall time and media coverage', () {
    final a = WatchIntervalAccumulator();
    for (var i = 0; i <= 6; i++) {
      a.onTick(
        WatchTick(
          positionMs: i * 1000,
          durationMs: 60000,
          playing: true,
          buffering: false,
          ready: true,
          generation: 1,
        ),
        i * 1000,
      );
    }
    expect(a.effectiveMs, closeTo(6000, 50));
    expect(a.mediaCoveredMs, closeTo(6000, 50));
    expect(a.coverage(60000), closeTo(0.1, 0.01));
  });

  test('pause and buffering credit nothing', () {
    final a = WatchIntervalAccumulator();
    a.onTick(
      const WatchTick(
        positionMs: 0,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      0,
    );
    a.onTick(
      const WatchTick(
        positionMs: 10000,
        durationMs: 60000,
        playing: false,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      10000,
    );
    a.onTick(
      const WatchTick(
        positionMs: 20000,
        durationMs: 60000,
        playing: true,
        buffering: true,
        ready: true,
        generation: 1,
      ),
      20000,
    );
    expect(a.effectiveMs, 0);
  });

  test('a forward seek is not watching', () {
    final a = WatchIntervalAccumulator();
    a.onTick(
      const WatchTick(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      0,
    );
    // One second of wall time cannot explain a 60-second jump.
    a.onTick(
      const WatchTick(
        positionMs: 60000,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      1000,
    );
    expect(a.effectiveMs, 0);
    expect(a.mediaCoveredMs, 0);
  });

  test('a backward seek is not watching', () {
    final a = WatchIntervalAccumulator();
    a.onTick(
      const WatchTick(
        positionMs: 30000,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      0,
    );
    a.onTick(
      const WatchTick(
        positionMs: 1000,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      1000,
    );
    expect(a.effectiveMs, 0);
  });

  test('2x playback counts wall time, not the doubled position delta', () {
    final a = WatchIntervalAccumulator(maxWallGapMs: 60000);
    a.onTick(
      const WatchTick(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
        rate: 2,
      ),
      0,
    );
    a.onTick(
      const WatchTick(
        positionMs: 20000,
        durationMs: 600000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
        rate: 2,
      ),
      10000,
    );
    expect(a.effectiveMs, 10000);
    expect(a.mediaCoveredMs, 20000);
  });

  test('replaying the same minute does not double coverage', () {
    final a = WatchIntervalAccumulator();
    var wall = 0;
    void tick(int position) {
      a.onTick(
        WatchTick(
          positionMs: position,
          durationMs: 60000,
          playing: true,
          buffering: false,
          ready: true,
          generation: 1,
        ),
        wall,
      );
      wall += 1000;
    }

    for (var i = 0; i <= 5; i++) {
      tick(i * 1000);
    }
    // Seek back and replay the same five seconds.
    tick(5000);
    tick(0);
    for (var i = 0; i <= 5; i++) {
      tick(i * 1000);
    }
    expect(a.mediaCoveredMs, closeTo(5000, 600));
    expect(a.effectiveMs, lessThanOrEqualTo(11000));
  });

  test('generation change resets the clock but keeps credited intervals', () {
    final a = WatchIntervalAccumulator();
    a.onTick(
      const WatchTick(
        positionMs: 0,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      0,
    );
    a.onTick(
      const WatchTick(
        positionMs: 3000,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 2,
      ),
      3000,
    );
    expect(a.effectiveMs, 0);
    a.onTick(
      const WatchTick(
        positionMs: 4000,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 2,
      ),
      4000,
    );
    expect(a.effectiveMs, 1000);
  });

  test('completed is recorded without crediting the jump to the end', () {
    final a = WatchIntervalAccumulator();
    a.onTick(
      const WatchTick(
        positionMs: 0,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
      ),
      0,
    );
    a.onTick(
      const WatchTick(
        positionMs: 60000,
        durationMs: 60000,
        playing: true,
        buffering: false,
        ready: true,
        generation: 1,
        completed: true,
      ),
      1000,
    );
    expect(a.completed, isTrue);
    expect(a.effectiveMs, 0);
  });
}
