import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/auto_reading.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/appdata.dart';

const _comicId = 'comic';
const _sourceKey = 'source';
const _position = Offset(100, 100);

void main() {
  final settings = appdata.settings;
  late Map<String, dynamic> previous;
  late _Reader reader;
  late _Images images;
  late ReaderGestureDetectorState gesture;

  setUp(() {
    previous = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    settings['deviceId'] = 'reader-gesture-test';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['longPressAction'] = null;
    images = _Images();
    reader = _Reader()..imageViewController = images;
    gesture = ReaderGestureDetectorState()..reader = reader;
  });

  tearDown(() => settings.replaceAll(previous));

  void longPress() {
    gesture.onLongPressedDown(_position);
    gesture.onLongPressedUp(_position);
  }

  test(
    'missing action uses default zoom and releases it after settings change',
    () {
      expect(
        settings.getReaderSetting(_comicId, _sourceKey, 'longPressAction'),
        isNull,
      );
      expect(
        settings.getReaderSetting(
          _comicId,
          _sourceKey,
          'enableLongPressToZoom',
        ),
        isTrue,
      );
      gesture.onLongPressedDown(_position);
      settings['enableLongPressToZoom'] = false;
      gesture.onLongPressedUp(_position);
      expect(images.presses, 1);
      expect(images.releases, 1);
      expect(reader.autoReading.toggles, 0);
    },
  );

  test('missing action respects disabled long press zoom', () {
    settings['enableLongPressToZoom'] = false;
    longPress();
    expect(images.presses, 0);
    expect(images.releases, 0);
    expect(reader.autoReading.toggles, 0);
  });

  test('missing action follows device and comic zoom overrides', () {
    settings['enableLongPressToZoom'] = true;
    settings.setEnabledDeviceSpecificSettings(true);
    settings.setDeviceReaderSetting('enableLongPressToZoom', false);
    longPress();
    expect(images.presses, 0);
    settings.setEnabledComicSpecificSettings(_comicId, _sourceKey, true);
    settings.setReaderSetting(
      _comicId,
      _sourceKey,
      'enableLongPressToZoom',
      true,
    );
    longPress();
    expect(images.presses, 1);
    expect(images.releases, 1);
    settings.setReaderSetting(
      _comicId,
      _sourceKey,
      'enableLongPressToZoom',
      false,
    );
    longPress();
    expect(images.presses, 1);
    expect(images.releases, 1);
    expect(reader.autoReading.toggles, 0);
  });

  for (final action in ['zoom', 'autoReading', 'none']) {
    test('explicit $action takes precedence over the zoom switch', () {
      settings['enableLongPressToZoom'] = action != 'zoom';
      settings['longPressAction'] = action;
      longPress();
      expect(images.presses, action == 'zoom' ? 1 : 0);
      expect(images.releases, action == 'zoom' ? 1 : 0);
      expect(reader.autoReading.toggles, action == 'autoReading' ? 1 : 0);
    });
  }
}

class _Reader extends ReaderState {
  @override
  final _AutoReading autoReading = _AutoReading();

  @override
  dynamic readerSetting(String key) =>
      appdata.settings.getReaderSetting(_comicId, _sourceKey, key);
}

class _AutoReading implements AutoReadingController {
  int toggles = 0;

  @override
  void toggle() => toggles++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Images implements ReaderImageViewController {
  int presses = 0;
  int releases = 0;

  @override
  void handleLongPressDown(Offset location) => presses++;

  @override
  void handleLongPressUp(Offset location) => releases++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
