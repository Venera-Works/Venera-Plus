import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'openlist_rpc.dart';

/// Cross-platform client for the embedded OpenList core. Mobile uses the
/// platform channel; desktop loads the C ABI supplied by the platform bundle.
class EmbeddedOpenListRpc implements OpenListRpcClient {
  EmbeddedOpenListRpc({MethodChannel? channel, this.desktopLibraryPath})
    : _channel = channel ?? const MethodChannel('venera/openlist');

  final MethodChannel _channel;
  static const _platformChannel = MethodChannel('venera/method_channel');
  final String? desktopLibraryPath;
  Future<bool>? _macSupported;

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    final message = jsonEncode({'method': method, 'arguments': request});
    try {
      if (Platform.isMacOS && !await _isMacSupported()) {
        return const {
          'error': {
            'code': 'unsupported_platform',
            'message': 'OpenList requires macOS 13 or later',
          },
        };
      }
      final response = Platform.isAndroid || Platform.isIOS
          ? await _channel.invokeMethod<String>('invoke', message)
          : await Isolate.run(
              () => _invokeDesktop(message, desktopLibraryPath),
            );
      return _decodeResponse(response);
    } catch (error) {
      return {
        'error': {'code': 'unavailable', 'message': '$error'},
      };
    }
  }

  Future<bool> _isMacSupported() => _macSupported ??= _platformChannel
      .invokeMethod<bool>('isOpenListSupported')
      .then((value) => value == true)
      .catchError((_) => false);

  static String _invokeDesktop(String request, String? libraryPath) {
    final abi = _OpenListAbi.open(libraryPath);
    return abi.invoke(request);
  }

  static Map<String, dynamic> _decodeResponse(String? response) {
    if (response == null || response.isEmpty) {
      return const {
        'error': {
          'code': 'invalid_response',
          'message': 'OpenList returned an empty response',
        },
      };
    }
    try {
      final value = jsonDecode(response);
      if (value is Map) return value.map((key, item) => MapEntry('$key', item));
    } catch (_) {}
    return const {
      'error': {
        'code': 'invalid_response',
        'message': 'OpenList returned invalid JSON',
      },
    };
  }
}

final class _OpenListAbi {
  _OpenListAbi._(DynamicLibrary library)
    : _invoke = library
          .lookupFunction<
            Pointer<Char> Function(Pointer<Char>),
            Pointer<Char> Function(Pointer<Char>)
          >('OpenListInvoke'),
      _allocate = library
          .lookupFunction<
            Pointer<Void> Function(Int32),
            Pointer<Void> Function(int)
          >('OpenListAllocate'),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('OpenListFree');

  final Pointer<Char> Function(Pointer<Char>) _invoke;
  final Pointer<Void> Function(int) _allocate;
  final void Function(Pointer<Void>) _free;

  static _OpenListAbi open(String? suppliedPath) {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final path =
        suppliedPath ??
        switch (Platform.operatingSystem) {
          'windows' =>
            '${executableDirectory.path}${Platform.pathSeparator}venera_openlist.dll',
          'linux' =>
            '${executableDirectory.path}${Platform.pathSeparator}lib${Platform.pathSeparator}libvenera_openlist.so',
          'macos' =>
            '${executableDirectory.parent.path}${Platform.pathSeparator}Frameworks${Platform.pathSeparator}libvenera_openlist.dylib',
          _ => throw UnsupportedError(
            'OpenList C ABI is not available on this platform',
          ),
        };
    return _OpenListAbi._(DynamicLibrary.open(path));
  }

  String invoke(String request) {
    final encoded = utf8.encode(request);
    final input = _allocate(encoded.length + 1);
    if (input == nullptr) throw StateError('OpenListAllocate failed');
    try {
      final bytes = input.cast<Uint8>().asTypedList(encoded.length + 1);
      bytes.setAll(0, encoded);
      bytes[encoded.length] = 0;
      final output = _invoke(input.cast<Char>());
      if (output == nullptr) throw StateError('OpenListInvoke failed');
      try {
        final outputBytes = <int>[];
        final pointer = output.cast<Uint8>();
        for (var i = 0; ; i++) {
          final byte = (pointer + i).value;
          if (byte == 0) break;
          outputBytes.add(byte);
        }
        return utf8.decode(outputBytes);
      } finally {
        _free(output.cast<Void>());
      }
    } finally {
      _free(input);
    }
  }
}
