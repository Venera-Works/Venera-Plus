import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:lodepng_flutter/lodepng_flutter.dart' as lodepng;

class Image {
  final Uint32List _data;

  final int width;

  final int height;

  Image(this._data, this.width, this.height) {
    if (_data.length != width * height) {
      throw ArgumentError(
        'Invalid argument: data length must be equal to width * height.',
      );
    }
  }

  Image.empty(this.width, this.height) : _data = Uint32List(width * height);

  static Future<Image> decodeImage(Uint8List data) async {
    final codec = await ui.instantiateImageCodec(data);
    late ui.FrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } finally {
      codec.dispose();
    }
    try {
      final info = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (info == null) {
        throw Exception('Failed to decode image');
      }
      return Image(
        info.buffer.asUint32List(),
        frame.image.width,
        frame.image.height,
      );
    } finally {
      frame.image.dispose();
    }
  }

  Color getPixelAtIndex(int index) {
    if (index < 0 || index >= _data.length) {
      throw ArgumentError(
        'Invalid argument: index must be in the range of [0, ${_data.length}).',
      );
    }
    return Color.fromValue(_data[index]);
  }

  Image copyRange(int x, int y, int width, int height) {
    if (width + x > this.width) {
      throw ArgumentError(
        '''
        Invalid argument: x + width must be less than or equal to the image width.
        x: $x, width: $width, image width: ${this.width}
      '''
            .trim(),
      );
    }
    if (height + y > this.height) {
      throw ArgumentError(
        '''
        Invalid argument: y + height must be less than or equal to the image height.
        y: $y, height: $height, image height: ${this.height}
      '''
            .trim(),
      );
    }
    var data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[j * width + i] = _data[(j + y) * this.width + i + x];
      }
    }
    return Image(data, width, height);
  }

  void fillImageAt(int x, int y, Image image) {
    if (x + image.width > width) {
      throw ArgumentError(
        '''
        Invalid argument: x + image width must be less than or equal to the image width.
        x: $x, image width: ${image.width}, image width: $width
      '''
            .trim(),
      );
    }
    if (y + image.height > height) {
      throw ArgumentError(
        '''
        Invalid argument: y + image height must be less than or equal to the image height.
        y: $y, image height: ${image.height}, image height: $height
      '''
            .trim(),
      );
    }
    for (var j = 0; j < image.height && (j + y) < height; j++) {
      for (var i = 0; i < image.width && (i + x) < width; i++) {
        _data[(j + y) * width + i + x] = image._data[j * image.width + i];
      }
    }
  }

  void fillImageRangeAt(
    int x,
    int y,
    Image image,
    int srcX,
    int srcY,
    int width,
    int height,
  ) {
    if (x + width > this.width) {
      throw ArgumentError(
        '''
        Invalid argument: x + width must be less than or equal to the image width.
        x: $x, width: $width, image width: ${this.width}
      '''
            .trim(),
      );
    }
    if (y + height > this.height) {
      throw ArgumentError(
        '''
        Invalid argument: y + height must be less than or equal to the image height.
        y: $y, height: $height, image height: ${this.height}
      '''
            .trim(),
      );
    }
    if (srcX + width > image.width) {
      throw ArgumentError(
        '''
        Invalid argument: srcX + width must be less than or equal to the image width.
        srcX: $srcX, width: $width, image width: ${image.width}
      '''
            .trim(),
      );
    }
    if (srcY + height > image.height) {
      throw ArgumentError(
        '''
        Invalid argument: srcY + height must be less than or equal to the image height.
        srcY: $srcY, height: $height, image height: ${image.height}
      '''
            .trim(),
      );
    }
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        _data[(j + y) * this.width + i + x] =
            image._data[(j + srcY) * image.width + i + srcX];
      }
    }
  }

  Image copyAndRotate90() {
    var data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[i * height + height - j - 1] = _data[j * width + i];
      }
    }
    return Image(data, height, width);
  }

  Color getPixel(int x, int y) {
    if (x < 0 || x >= width) {
      throw ArgumentError(
        'Invalid argument: x must be in the range of [0, $width).',
      );
    }
    if (y < 0 || y >= height) {
      throw ArgumentError(
        'Invalid argument: y must be in the range of [0, $height).',
      );
    }
    return Color.fromValue(_data[y * width + x]);
  }

  void setPixel(int x, int y, Color color) {
    if (x < 0 || x >= width) {
      throw ArgumentError(
        'Invalid argument: x must be in the range of [0, $width).',
      );
    }
    if (y < 0 || y >= height) {
      throw ArgumentError(
        'Invalid argument: y must be in the range of [0, $height).',
      );
    }
    _data[y * width + x] = color.value;
  }

  Uint8List encodePng() {
    var data = lodepng.encodePngToPointer(
      lodepng.Image(_data.buffer.asUint8List(), width, height),
    );
    return Pointer<Uint8>.fromAddress(
      data.address,
    ).asTypedList(data.length, finalizer: lodepng.ByteBuffer.finalizer);
  }
}

class Color {
  final int value;

  Color(int r, int g, int b, [int a = 255])
    : value = (a << 24) | (r << 16) | (g << 8) | b;

  Color.fromValue(this.value);

  int get r => value & 0xFF;

  int get g => (value >> 8) & 0xFF;

  int get b => (value >> 16) & 0xFF;

  int get a => (value >> 24) & 0xFF;
}

class _ImageScriptEngine {
  _ImageScriptEngine([FlutterQjs? runtime]) : runtime = runtime ?? FlutterQjs();

  final FlutterQjs runtime;

  void runCode(String js, [String? name]) {
    dynamic result;
    try {
      result = runtime.evaluate('$js\n;void 0;', name: name);
    } finally {
      JSRef.freeRecursive(result);
    }
  }

  final images = <int, Image>{};

  var _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      runtime.close();
    } finally {
      runtime.port.close();
      images.clear();
    }
  }

  int _key = 0;

  int setImage(Image image) {
    var key = _key++;
    images[key] = image;
    return key;
  }

  Object? _messageReceiver(dynamic message) {
    if (message is! Map) return null;
    var method = message['method'];
    if (method == 'image') {
      switch (message['function']) {
        case 'copyRange':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var width = message['width'];
          var height = message['height'];
          var newImage = image.copyRange(x, y, width, height);
          return setImage(newImage);
        case 'copyAndRotate90':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var newImage = image.copyAndRotate90();
          return setImage(newImage);
        case 'fillImageAt':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var key2 = message['image'];
          var image2 = images[key2];
          if (image2 == null) return null;
          image.fillImageAt(x, y, image2);
          return null;
        case 'fillImageRangeAt':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          var x = message['x'];
          var y = message['y'];
          var key2 = message['image'];
          var image2 = images[key2];
          if (image2 == null) return null;
          var srcX = message['srcX'];
          var srcY = message['srcY'];
          var width = message['width'];
          var height = message['height'];
          image.fillImageRangeAt(x, y, image2, srcX, srcY, width, height);
          return null;
        case 'getWidth':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          return image.width;
        case 'getHeight':
          var key = message['key'];
          var image = images[key];
          if (image == null) return null;
          return image.height;
        case 'emptyImage':
          var width = message['width'];
          var height = message['height'];
          var newImage = Image.empty(width, height);
          return setImage(newImage);
      }
    }
    return null;
  }
}

final _imageScriptSlots = _AsyncSemaphore(4);

@visibleForTesting
Future<T> debugRunWithImageScriptSlot<T>(Future<T> Function() task) {
  return _imageScriptSlots.run(task);
}

@visibleForTesting
Image debugRunImageScript(
  Image image,
  String initJs,
  String script, {
  FlutterQjs? runtime,
}) {
  return _runImageScript(image, initJs, script, runtime: runtime);
}

Image _runImageScript(
  Image image,
  String initJs,
  String script, {
  FlutterQjs? runtime,
}) {
  final engine = _ImageScriptEngine(runtime);
  try {
    unawaited(engine.runtime.dispatch());
    final setGlobalFunc = engine.runtime.evaluate(
      '(key, value) => { this[key] = value; }',
    );
    try {
      (setGlobalFunc as JSInvokable)(['sendMessage', engine._messageReceiver]);
    } finally {
      JSRef.freeRecursive(setGlobalFunc);
    }
    engine.runCode(initJs, '<init>');
    engine.runCode(script);
    final key = engine.setImage(image);
    dynamic result;
    try {
      result = engine.runtime.evaluate('''(() => {
        const image = new Image($key);
        return modifyImage(image).key;
      })()''');
      if (result is! int || !engine.images.containsKey(result)) {
        throw StateError(
          'Image script must synchronously return an Image with a valid key.',
        );
      }
      return engine.images[result]!;
    } finally {
      JSRef.freeRecursive(result);
    }
  } finally {
    engine.dispose();
  }
}

Future<Uint8List> modifyImageWithScript(Uint8List data, String script) async {
  return _imageScriptSlots.run(() async {
    var image = await Image.decodeImage(data);
    var initJs = await rootBundle.loadString('assets/init.js');
    return await Isolate.run(() {
      final newImage = _runImageScript(image, initJs, script);
      final data = newImage.encodePng();
      return Uint8List.fromList(data);
    });
  });
}

class _AsyncSemaphore {
  final int maxConcurrent;

  int _active = 0;

  final _waiters = Queue<Completer<void>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
  }
}
