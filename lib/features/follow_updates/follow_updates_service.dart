import 'dart:async';

import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/follow_updates/follow_updates_manager.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/log.dart';

/// Automatic tracking always resolves the same persisted role as the home view.
abstract class FollowUpdatesService {
  static bool _isChecking = false;
  static bool get isChecking => _isChecking;
  static Timer? _timer;
  static int _generation = 0;

  static Future<void> _check() async {
    if (_isChecking) return;
    final generation = _generation;
    _isChecking = true;
    try {
      await DataSync().waitForDownload();
      if (generation != _generation) return;
      final manager = LocalFavoritesManager();
      await manager.reconcileReadingFolderBinding();
      if (generation != _generation) return;
      final folder = manager.readingFolder;
      if (folder == null) return;
      // updateFolder coalesces equivalent work and refreshComic coalesces manual
      // checks of overlapping folders. Canceling this listener doesn't cancel
      // another caller's refresh.
      await for (final progress in updateFolder(folder, false)) {
        if (generation != _generation || manager.readingFolder != folder) {
          return;
        }
        if (progress.errorMessage != null) {
          Log.error('FollowUpdatesService', progress.errorMessage!);
        }
      }
    } catch (e, s) {
      Log.error('FollowUpdatesService', e, s);
    } finally {
      _isChecking = false;
    }
  }

  static void cancel() {
    _generation++;
  }

  static void initChecker() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _check());
    unawaited(_check());
  }

  static void dispose() {
    cancel();
    _timer?.cancel();
    _timer = null;
  }
}
