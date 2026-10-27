import 'log.dart';

/// Timings are relative to the Dart entry point and contain no user data.
abstract final class StartupTiming {
  static final _clock = Stopwatch();
  static String? failedStage;

  static void start() => _clock
    ..reset()
    ..start();

  static void mark(String name) {
    if (_clock.isRunning) {
      Log.info('Startup', '$name: ${_clock.elapsedMilliseconds} ms');
    }
  }

  static Future<void> measure(
    String name,
    Future<void> Function() initialize,
  ) async {
    final watch = Stopwatch()..start();
    try {
      await initialize();
    } catch (error, stack) {
      failedStage = name;
      Log.error('Startup', '$name failed: $error', stack);
      rethrow;
    } finally {
      if (_clock.isRunning) {
        Log.info('Startup', '$name took ${watch.elapsedMilliseconds} ms');
      }
    }
  }
}
