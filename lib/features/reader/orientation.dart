import 'dart:async';
import 'dart:io' show Platform;

// The pinned Android plugin is already registered via super_native_extensions.
// ignore: depend_on_referenced_packages
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

Future<int?>? _androidSdkInt;

Future<int?> get readerAndroidSdkInt {
  return Platform.isAndroid
      ? (_androidSdkInt ??= _readAndroidSdkInt())
      : Future.value();
}

Future<int?> _readAndroidSdkInt() async {
  try {
    return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  } catch (_) {
    return null;
  }
}

bool readerRequiresEdgeToEdge(int? sdkInt) => (sdkInt ?? 0) >= 36;

enum ReaderOrientation {
  system([]),
  portrait([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]),
  landscape([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  const ReaderOrientation(this.orientations);

  final List<DeviceOrientation> orientations;
}

mixin ReaderOrientationState<T extends StatefulWidget> on State<T> {
  // Route transitions can keep an old reader alive after a new one opens.
  static final _activeReaders = <ReaderOrientationState>[];

  ReaderOrientation _readerOrientation = ReaderOrientation.system;

  ReaderOrientation get readerOrientation => _readerOrientation;

  late final bool _orientationEnabled;
  bool _orientationRestricted = false;
  _ReaderDisplayObserver? _displayObserver;

  bool get readerOrientationRestricted => _orientationRestricted;
  bool get readerOrientationLockEnabled =>
      _orientationEnabled && !_orientationRestricted;

  @override
  void initState() {
    super.initState();
    _orientationEnabled = defaultTargetPlatform == TargetPlatform.android;
    if (_orientationEnabled) {
      _activeReaders.add(this);
      _applyOrientation(ReaderOrientation.system);
      if (Platform.isAndroid) unawaited(_checkOrientationRestriction());
    }
  }

  Future<void> _checkOrientationRestriction() async {
    final sdkInt = await readerAndroidSdkInt;
    if (!mounted || !readerRequiresEdgeToEdge(sdkInt)) return;
    final observer = _ReaderDisplayObserver(_updateOrientationRestriction);
    _displayObserver = observer;
    WidgetsBinding.instance.addObserver(observer);
    _updateOrientationRestriction();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_displayObserver != null) _updateOrientationRestriction();
  }

  void _updateOrientationRestriction() {
    final display = View.of(context).display;
    final restricted =
        (display.size / display.devicePixelRatio).shortestSide >= 600;
    if (restricted == _orientationRestricted) return;
    final releaseLock =
        restricted && _readerOrientation != ReaderOrientation.system;
    setState(() {
      _orientationRestricted = restricted;
      if (restricted) _readerOrientation = ReaderOrientation.system;
    });
    if (releaseLock && identical(_activeReaders.lastOrNull, this)) {
      _applyOrientation(ReaderOrientation.system);
    }
  }

  void cycleReaderOrientation() {
    if (!readerOrientationLockEnabled ||
        !identical(_activeReaders.lastOrNull, this)) {
      return;
    }
    setState(() {
      _readerOrientation = switch (_readerOrientation) {
        ReaderOrientation.system => ReaderOrientation.portrait,
        ReaderOrientation.portrait => ReaderOrientation.landscape,
        ReaderOrientation.landscape => ReaderOrientation.system,
      };
    });
    _applyOrientation(_readerOrientation);
  }

  void _applyOrientation(ReaderOrientation orientation) {
    unawaited(SystemChrome.setPreferredOrientations(orientation.orientations));
  }

  @override
  void dispose() {
    if (_displayObserver case final observer?) {
      WidgetsBinding.instance.removeObserver(observer);
    }
    if (_orientationEnabled) {
      final wasActive = identical(_activeReaders.lastOrNull, this);
      _activeReaders.remove(this);
      if (wasActive) {
        // An empty list releases the last reader's lock to the operating system.
        _applyOrientation(
          _activeReaders.lastOrNull?.readerOrientation ??
              ReaderOrientation.system,
        );
      }
    }
    super.dispose();
  }
}

class _ReaderDisplayObserver with WidgetsBindingObserver {
  _ReaderDisplayObserver(this.onMetricsChanged);

  final VoidCallback onMetricsChanged;

  @override
  void didChangeMetrics() => onMetricsChanged();
}
