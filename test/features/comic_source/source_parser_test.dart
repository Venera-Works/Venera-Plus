import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/js_engine.dart';

const bool _ciRequireQuickJs = bool.fromEnvironment(
  'CI_REQUIRE_QUICKJS',
  defaultValue: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  Object? nativeLoadError;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    nativeAvailable = true;
  } catch (e) {
    nativeAvailable = false;
    nativeLoadError = e;
  }

  test(
    'entry class accepts indentation, multiline extends and helper classes',
    () {
      expect(
        sourceClassName(
          'class Helper {}\n  class Demo\n extends ComicSource {}',
        ),
        'Demo',
      );
      expect(
        sourceClassName('\uFEFFclass Demo extends ComicSource {}'),
        'Demo',
      );
      expect(
        () => sourceClassName('<html>Error</html>'),
        throwsA(isA<ComicSourceParseException>()),
      );
    },
  );

  group(
    'ComicSourceParser.probeKey metadata sandboxing',
    () {
      setUpAll(() async {
        if (_ciRequireQuickJs && !nativeAvailable) {
          fail(
            'CI_REQUIRE_QUICKJS=true requires QuickJS native library, '
            'but it failed to load: $nativeLoadError',
          );
        }
        App.version = '9.0.0';
        final initJs = File('assets/init.js');
        if (initJs.existsSync()) {
          JsEngine.cacheJsInit(await initJs.readAsBytes());
        }
      });

      test('empty script returns emptyScript failure', () async {
        final result = await ComicSourceParser.probeKey('   \n\t  ');
        expect(result.isSuccess, isFalse);
        expect(result.failure, ComicSourceKeyProbeFailure.emptyScript);
      });

      test('missing entry class returns missingEntryClass failure', () async {
        final result = await ComicSourceParser.probeKey('const a = 1;');
        expect(result.isSuccess, isFalse);
        expect(result.failure, ComicSourceKeyProbeFailure.missingEntryClass);
      });

      test('syntax error returns syntaxError failure', () async {
        final result = await ComicSourceParser.probeKey('''
class BrokenSyntax extends ComicSource {
  key = "test";
  invalid syntax here {{{
}
''');
        expect(result.isSuccess, isFalse);
        expect(result.failure, ComicSourceKeyProbeFailure.syntaxError);
      });

      test('unsupported host API call is blocked and classified', () async {
        final result = await ComicSourceParser.probeKey('''
class HostAccess extends ComicSource {
  key = "host_access";
  constructor() {
    super();
    sendMessage({method: "http", url: "https://example.com"});
  }
}
''');
        expect(result.isSuccess, isFalse);
        expect(result.failure, ComicSourceKeyProbeFailure.unsupportedHostApi);
      });

      test(
        'forbidden host diagnostics do not expose arbitrary tokens',
        () async {
          const secretMethod = 'privateAccessTokenNotForDiagnostics';
          const secretPayload = 'cookie-value-not-for-diagnostics';
          final result = await ComicSourceParser.probeKey('''
class SecretHostAccess extends ComicSource {
  key = "secret_host_access";
  constructor() {
    super();
    sendMessage({
      method: "$secretMethod",
      cookie: "$secretPayload",
    });
  }
}
''');
          expect(result.failure, ComicSourceKeyProbeFailure.unsupportedHostApi);
          expect(result.blockedMethod, isNull);
          expect(result.toString(), isNot(contains(secretMethod)));
          expect(result.toString(), isNot(contains(secretPayload)));
        },
      );

      test(
        'pure helpers preserve host random ranges and eager UUID v1 metadata',
        () async {
          // Force Math.random-based inclusive helpers to choose their maximum.
          final randomResult = await ComicSourceParser.probeKey('''
Math.random = () => 0.999999;
class RandomBounds extends ComicSource {
  upperExclusiveInt = randomInt(4, 5);
  fractionalBoundsInt = randomInt(0.1, 0.9);
  equalInt = randomInt(11, 11);
  rangedDouble = randomDouble(-2, 3);
  equalDouble = randomDouble(0.5, 0.5);
  key = this.upperExclusiveInt === 4 &&
        this.fractionalBoundsInt === 0 &&
        this.equalInt === 11 &&
        this.rangedDouble >= -2 &&
        this.rangedDouble < 3 &&
        this.equalDouble === 0.5
      ? "_random_bounds_09"
      : "invalid_random_bounds";
}
''');
          expect(randomResult.isSuccess, isTrue);
          expect(randomResult.key, '_random_bounds_09');

          final uuidResult = await ComicSourceParser.probeKey(r'''
class UuidPattern extends ComicSource {
  uuid = createUuid();
  key = /^[0-9a-f]{8}-[0-9a-f]{4}-1[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(this.uuid)
      ? "uuid_v1"
      : "invalid_uuid";
}
''');
          expect(uuidResult.isSuccess, isTrue);
          expect(uuidResult.key, 'uuid_v1');
          expect(uuidResult.failure, isNull);
        },
      );

      test(
        'pure random helpers resolve an eager generated source device id',
        () async {
          final result = await ComicSourceParser.probeKey(r'''
class ShonenPattern extends ComicSource {
  deviceId = this.genDeviceId();
  key = /^[a-f0-9]{8}$/.test(this.deviceId)
      ? "shonen_pattern"
      : "invalid_device_id";

  genDeviceId() {
    const chars = "abcdef0123456789";
    let res = "";
    for (let i = 0; i < 8; i++) {
      res += chars[randomInt(0, chars.length - 1)];
    }
    return res;
  }
}
''');
          expect(result.isSuccess, isTrue);
          expect(result.key, 'shonen_pattern');
          expect(result.failure, isNull);
        },
      );

      test('invalid keys return invalidKey failure', () async {
        for (final expr in [
          '123',
          'null',
          '""',
          '"key with spaces"',
          'true',
          '["arr"]',
        ]) {
          final result = await ComicSourceParser.probeKey('''
class InvalidKey extends ComicSource {
  key = $expr;
}
''');
          expect(result.isSuccess, isFalse);
          expect(result.failure, ComicSourceKeyProbeFailure.invalidKey);
        }
      });

      test(
        'accepted key syntax matches installed source conventions',
        () async {
          final result = await ComicSourceParser.probeKey('''
class ConventionalKey extends ComicSource {
  key = "_UpperCase_09";
}
''');
          expect(result.isSuccess, isTrue);
          expect(result.key, '_UpperCase_09');
        },
      );

      test('constructor runtime exception returns evaluationError', () async {
        final result = await ComicSourceParser.probeKey('''
class ErrorSource extends ComicSource {
  key = "err";
  constructor() {
    super();
    throw new TypeError("explicit constructor throw");
  }
}
''');
        expect(result.isSuccess, isFalse);
        expect(result.failure, ComicSourceKeyProbeFailure.evaluationError);
      });

      test(
        'syntax error in initialization definitions yields runtimeFailure not syntaxError',
        () async {
          final originalInit = await File('assets/init.js').readAsBytes();
          try {
            JsEngine.cacheJsInit(
              Uint8List.fromList(
                utf8.encode('broken syntax in init asset {{{'),
              ),
            );
            final result = await ComicSourceParser.probeKey('''
class Candidate extends ComicSource {
  key = "candidate";
}
''');
            expect(result.isSuccess, isFalse);
            expect(result.failure, ComicSourceKeyProbeFailure.runtimeFailure);
          } finally {
            JsEngine.cacheJsInit(originalInit);
          }
        },
      );
    },
    skip: nativeAvailable
        ? false
        : (_ciRequireQuickJs
              ? false
              : 'QuickJS native library unavailable; run with platform build DLLs on PATH.'),
  );
}
