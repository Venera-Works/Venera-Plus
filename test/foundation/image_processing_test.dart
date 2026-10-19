import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/foundation/image_processing.dart';

const _ciRequireQuickJs = bool.fromEnvironment('CI_REQUIRE_QUICKJS');

class _SpyRef extends JSRef {
  var destroyCount = 0;

  @override
  void destroy() {
    destroyCount++;
  }
}

class _SpyInvokable extends JSInvokable {
  _SpyInvokable(this.callback);

  final Object? Function(List args) callback;
  var destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) => callback(args);

  @override
  void destroy() {
    destroyCount++;
  }
}

class _SpyReceivePort extends Stream<dynamic> implements ReceivePort {
  final _port = ReceivePort();
  var closeCount = 0;

  @override
  SendPort get sendPort => _port.sendPort;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _port.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void close() {
    closeCount++;
    _port.close();
  }
}

enum _FailureStage {
  dispatch,
  setterEvaluation,
  setterInvocation,
  init,
  source,
  result,
}

class _SpyFlutterQjs extends FlutterQjs {
  _SpyFlutterQjs({
    this.failAt,
    Object? failure,
    this.closeError,
    this.result = 0,
    this.selectResult,
  }) : failure = failure ?? StateError('Script failure') {
    port.close();
    port = receivePort;
    setter = _SpyInvokable((args) {
      expect(args.first, 'sendMessage');
      sendMessage = args[1] as Object? Function(dynamic);
      _fail(_FailureStage.setterInvocation);
      return null;
    });
  }

  final _FailureStage? failAt;
  final Object failure;
  final Object? closeError;
  final Object? result;
  final Object? Function(_SpyFlutterQjs runtime)? selectResult;
  final receivePort = _SpyReceivePort();
  final initRef = _SpyRef();
  final sourceRef = _SpyRef();
  final evaluations = <({String code, String? name})>[];
  late final _SpyInvokable setter;
  Object? Function(dynamic)? sendMessage;
  var dispatchCount = 0;
  var closeCount = 0;
  List<int>? refsAtClose;

  void _fail(_FailureStage stage) {
    if (failAt == stage) throw failure;
  }

  @override
  Future<void> dispatch() {
    dispatchCount++;
    _fail(_FailureStage.dispatch);
    return port.drain<void>();
  }

  @override
  dynamic evaluate(String command, {String? name, int? evalFlags}) {
    final index = evaluations.length;
    evaluations.add((code: command, name: name));
    switch (index) {
      case 0:
        _fail(_FailureStage.setterEvaluation);
        return setter;
      case 1:
        _fail(_FailureStage.init);
        // Each spy represents one owned JSRef, so it occurs only once.
        return [initRef];
      case 2:
        _fail(_FailureStage.source);
        return {
          'nested': [sourceRef],
        };
      case 3:
        _fail(_FailureStage.result);
        return selectResult == null ? result : selectResult!(this);
      default:
        throw StateError('Unexpected evaluation: $command');
    }
  }

  @override
  void close() {
    closeCount++;
    refsAtClose = [
      setter.destroyCount,
      initRef.destroyCount,
      sourceRef.destroyCount,
    ];
    if (closeError != null) throw closeError!;
  }
}

Image _pixels() => Image(
  Uint32List.fromList([
    0xff000001,
    0xff000002,
    0xff000003,
    0xff000004,
    0xff000005,
    0xff000006,
  ]),
  3,
  2,
);

void _expectClosed(_SpyFlutterQjs runtime, {List<int> refs = const [1, 1, 1]}) {
  expect(runtime.dispatchCount, 1);
  expect(runtime.closeCount, 1);
  expect(runtime.receivePort.closeCount, 1);
  expect(runtime.refsAtClose, refs);
  if (runtime.sendMessage != null) {
    expect(
      runtime.sendMessage!({
        'method': 'image',
        'function': 'getWidth',
        'key': 0,
      }),
      isNull,
      reason: 'The engine must release its Dart image registry as well.',
    );
  }
}

void _expectRotatedPixels(Image image) {
  expect(image.width, 2);
  expect(image.height, 2);
  expect(List.generate(4, (index) => image.getPixelAtIndex(index).value), [
    0xff000005,
    0xff000002,
    0xff000006,
    0xff000003,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image script resource lifecycle', () {
    test(
      'success frees references and closes before returning Dart pixels',
      () {
        final runtime = _SpyFlutterQjs();
        final original = _pixels();
        final image = debugRunImageScript(
          original,
          'init // trailing comment',
          'source // trailing comment',
          runtime: runtime,
        );

        expect(image, same(original));
        expect(image.getPixel(2, 1).value, 0xff000006);
        expect(
          runtime.evaluations[1].code,
          'init // trailing comment\n;void 0;',
        );
        expect(runtime.evaluations[1].name, '<init>');
        expect(
          runtime.evaluations[2].code,
          'source // trailing comment\n;void 0;',
        );
        expect(runtime.evaluations[3].code, contains('modifyImage(image).key'));
        _expectClosed(runtime);
      },
    );

    test('selects derived pixels that remain usable after engine cleanup', () {
      final runtime = _SpyFlutterQjs(
        selectResult: (runtime) {
          final copied = runtime.sendMessage!({
            'method': 'image',
            'function': 'copyRange',
            'key': 0,
            'x': 1,
            'y': 0,
            'width': 2,
            'height': 2,
          });
          return runtime.sendMessage!({
            'method': 'image',
            'function': 'copyAndRotate90',
            'key': copied,
          });
        },
      );

      final image = debugRunImageScript(_pixels(), '', '', runtime: runtime);

      _expectClosed(runtime);
      _expectRotatedPixels(image);
    });

    for (final (stage, refs) in [
      (_FailureStage.dispatch, [0, 0, 0]),
      (_FailureStage.setterEvaluation, [0, 0, 0]),
      (_FailureStage.setterInvocation, [1, 0, 0]),
      (_FailureStage.init, [1, 0, 0]),
      (_FailureStage.source, [1, 1, 0]),
      (_FailureStage.result, [1, 1, 1]),
    ]) {
      test('${stage.name} failure still closes runtime and port once', () {
        final failure = StateError('${stage.name} failed');
        final runtime = _SpyFlutterQjs(failAt: stage, failure: failure);

        expect(
          () => debugRunImageScript(_pixels(), '', '', runtime: runtime),
          throwsA(same(failure)),
        );
        _expectClosed(runtime, refs: refs);
      });
    }

    test('rejects invalid keys and recursively frees returned references', () {
      final resultRef = _SpyRef();
      final nestedResultRef = _SpyRef();
      for (final key in [
        null,
        '0',
        0.0,
        -1,
        42,
        {
          'nested': [
            resultRef,
            {'other': nestedResultRef},
          ],
        },
      ]) {
        final runtime = _SpyFlutterQjs(result: key);
        expect(
          () => debugRunImageScript(_pixels(), '', '', runtime: runtime),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('synchronously return an Image with a valid key'),
            ),
          ),
        );
        _expectClosed(runtime);
      }
      expect(resultRef.destroyCount, 1);
      expect(nestedResultRef.destroyCount, 1);
    });

    test('close errors propagate after references and images are released', () {
      final error = JSError('reference leak: test failure');
      final runtime = _SpyFlutterQjs(closeError: error);

      expect(
        () => debugRunImageScript(_pixels(), '', '', runtime: runtime),
        throwsA(same(error)),
      );
      _expectClosed(runtime);
    });
  });

  test(
    'decoding preserves straight RGBA bytes and disposes the frame',
    () async {
      final png = img.Image(width: 2, height: 1, numChannels: 4)
        ..setPixelRgba(0, 0, 17, 34, 51, 255)
        ..setPixelRgba(1, 0, 204, 102, 51, 85);
      final created = <ui.Image>[];
      final disposed = <ui.Image>[];
      final previousOnCreate = ui.Image.onCreate;
      final previousOnDispose = ui.Image.onDispose;
      ui.Image.onCreate = (image) {
        created.add(image);
        previousOnCreate?.call(image);
      };
      ui.Image.onDispose = (image) {
        disposed.add(image);
        previousOnDispose?.call(image);
      };
      try {
        final image = await Image.decodeImage(
          Uint8List.fromList(img.encodePng(png)),
        );
        expect(image.width, 2);
        expect(image.height, 1);
        expect(image.getPixel(0, 0).value, 0xff332211);
        expect(image.getPixel(1, 0).value, 0x553366cc);
        expect(created, hasLength(1));
        expect(disposed, orderedEquals(created));
        expect(created.single.debugDisposed, isTrue);
      } finally {
        ui.Image.onCreate = previousOnCreate;
        ui.Image.onDispose = previousOnDispose;
      }
    },
  );

  test('image script scheduler limits concurrent tasks', () async {
    var active = 0;
    var maxActive = 0;
    final started = <Completer<void>>[];
    final release = <Completer<void>>[];

    final tasks = List.generate(5, (index) {
      final startedCompleter = Completer<void>();
      final releaseCompleter = Completer<void>();
      started.add(startedCompleter);
      release.add(releaseCompleter);

      return debugRunWithImageScriptSlot(() async {
        active++;
        if (active > maxActive) {
          maxActive = active;
        }
        startedCompleter.complete();
        await releaseCompleter.future;
        active--;
        return index;
      });
    });

    await Future.wait(
      started
          .take(4)
          .map(
            (completer) => completer.future.timeout(const Duration(seconds: 1)),
          ),
    );
    await pumpEventQueue();

    expect(started[4].isCompleted, isFalse);
    expect(maxActive, 4);

    release[0].complete();
    await started[4].future.timeout(const Duration(seconds: 1));

    expect(maxActive, 4);

    for (final completer in release.skip(1)) {
      completer.complete();
    }

    expect(await Future.wait(tasks), [0, 1, 2, 3, 4]);
    expect(active, 0);
  });

  Object? nativeLoadError;
  try {
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
  } catch (error) {
    nativeLoadError = error;
  }

  group(
    'image scripts with real QuickJS',
    () {
      late String initJs;
      setUpAll(() {
        if (nativeLoadError != null) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires a compatible QuickJS native '
            'library, but it failed to load: $nativeLoadError',
          );
        }
        initJs = File('assets/init.js').readAsStringSync();
      });

      test('repeated tasks preserve pixels and release trailing functions', () {
        for (var i = 0; i < 8; i++) {
          final image = debugRunImageScript(
            _pixels(),
            '$initJs\n(() => 42)\n// trailing init comment',
            '''
function modifyImage(image) {
  return image.copyRange(1, 0, 2, 2).copyAndRotate90();
}
(() => 42)
// trailing source comment''',
          );
          _expectRotatedPixels(image);
        }
      });

      test('init, source and invocation exceptions retain their JS errors', () {
        for (final (definitions, script) in [
          ('throw new Error("init failed")', ''),
          (initJs, 'throw new Error("source failed")'),
          (
            initJs,
            'function modifyImage(image) { throw new Error("invoke failed"); }',
          ),
        ]) {
          expect(
            () => debugRunImageScript(_pixels(), definitions, script),
            throwsA(
              isA<JSError>().having(
                (error) => error.message,
                'message',
                allOf(contains('failed'), isNot(contains('reference leak'))),
              ),
            ),
          );
        }
      });

      test('invalid and asynchronous returns fail without leaked JSRefs', () {
        for (final script in [
          'function modifyImage(image) { return {key: "0"}; }',
          'function modifyImage(image) { return {key: 999}; }',
          'function modifyImage(image) { return {key: () => image}; }',
          'function modifyImage(image) { return {key: [() => image]}; }',
          'async function modifyImage(image) { return image; }',
        ]) {
          expect(
            () => debugRunImageScript(_pixels(), initJs, script),
            throwsA(isA<StateError>()),
          );
        }
      });
    },
    skip: nativeLoadError == null || _ciRequireQuickJs
        ? false
        : 'QuickJS native library unavailable: $nativeLoadError. '
              'Run with existing compatible platform DLLs on PATH; '
              'CI_REQUIRE_QUICKJS=true makes missing libraries fail.',
  );
}
