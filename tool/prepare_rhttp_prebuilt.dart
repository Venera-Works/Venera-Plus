import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

const _upstreamProviderSha256 =
    '46ef875c9191acfb3f06625bf0d3e2d5da5f6fb12bd36f9bb59f20d2edfadc0d';
const _strictProviderSha256 =
    '4f58e0775174fe9945f8691fd3d2894a4d8dd0a495718b177f0fda8ecd20225a';

const _strictFailure = r'''    throw StateError(
      'Missing or invalid signed rhttp prebuilts for $pendingTargets. '
      'Publish the matching release in Venera-Works/Venera-Native-Prebuilts '
      'before building. Local Rust compilation is disabled.',
    );
  }

''';

void _checkPackage(
  Map packages,
  String name,
  String version, {
  String? archive,
}) {
  final package = packages[name] as Map;
  if (package['source'] != 'hosted' || package['version'] != version) {
    throw StateError('$name must remain locked to pub.dev version $version.');
  }
  if (archive != null && (package['description'] as Map)['sha256'] != archive) {
    throw StateError('$name archive SHA-256 differs from the prebuild lock.');
  }
}

String _strictProvider(String source) {
  source = source.replaceAll('\r\n', '\n');
  final digest = sha256.convert(utf8.encode(source)).toString();
  if (digest == _strictProviderSha256) return source;
  if (digest != _upstreamProviderSha256) {
    throw StateError(
      'Unexpected rhttp Cargokit source. Review the prebuild integration before '
      'upgrading or modifying this dependency.',
    );
  }
  final start = source.indexOf('    final rustup = Rustup();');
  final end = source.indexOf(
    '  Future<Map<Target, List<Artifact>>> _getPrecompiledArtifacts(',
  );
  final patched = source
      .replaceRange(start, end, _strictFailure)
      .replaceFirst("import 'rustup.dart';\n", '');
  if (sha256.convert(utf8.encode(patched)).toString() !=
      _strictProviderSha256) {
    throw StateError(
      'The rhttp download-only patch does not match its digest.',
    );
  }
  return patched;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

// Match Cargokit's content hash, including files that are not Rust source and
// ignoring line endings. The new configuration is hashed before it is written.
String _crateHash(Directory manifest, String configuration) {
  final files =
      Directory.fromUri(manifest.uri.resolve('src/'))
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final name in ['Cargo.toml', 'Cargo.lock', 'build.rs']) {
    final file = File.fromUri(manifest.uri.resolve(name));
    if (file.existsSync()) files.add(file);
  }
  final digest = _DigestSink();
  final sink = sha256.startChunkedConversion(digest);
  for (final file in files) {
    for (final line in const LineSplitter().convert(file.readAsStringSync())) {
      sink.add(utf8.encode(line));
    }
  }
  for (final line in const LineSplitter().convert(configuration)) {
    sink.add(utf8.encode(line));
  }
  sink.close();
  return digest.value.toString().substring(0, 32);
}

void main() {
  try {
    final lock =
        jsonDecode(File('native/prebuilts/rhttp/lock.json').readAsStringSync())
            as Map;
    final packages =
        (loadYaml(File('pubspec.lock').readAsStringSync()) as Map)['packages']
            as Map;
    _checkPackage(
      packages,
      'rhttp',
      lock['version'] as String,
      archive: lock['archiveSha256'] as String,
    );
    _checkPackage(
      packages,
      'flutter_rust_bridge',
      lock['flutterRustBridgeVersion'] as String,
    );
    final options =
        loadYaml(File('cargokit_options.yaml').readAsStringSync()) as Map;
    if (options['use_precompiled_binaries'] != true) {
      throw StateError(
        'cargokit_options.yaml must enable precompiled binaries.',
      );
    }
    final configuration = File(
      'native/prebuilts/rhttp/cargokit.yaml',
    ).readAsStringSync();
    final precompiled =
        (loadYaml(configuration) as Map)['precompiled_binaries'] as Map;
    if (precompiled['url_prefix'] !=
        'https://github.com/${lock['repository']}/releases/download/precompiled_') {
      throw StateError('The rhttp release repository differs from its lock.');
    }

    final packageConfig = File('.dart_tool/package_config.json').absolute;
    final packageEntries =
        (jsonDecode(packageConfig.readAsStringSync()) as Map)['packages']
            as List;
    final packageEntry = packageEntries.cast<Map>().firstWhere(
      (entry) => entry['name'] == 'rhttp',
    );
    final root = packageConfig.uri.resolve(packageEntry['rootUri'] as String);
    final packageSpec =
        loadYaml(File.fromUri(root.resolve('pubspec.yaml')).readAsStringSync())
            as Map;
    if (packageSpec['version'] != lock['version']) {
      throw StateError(
        'Run flutter pub get --enforce-lockfile before preparing.',
      );
    }
    final projectCache = Directory('.pub-cache').absolute.uri;
    if (Platform.environment['CI'] != 'true' &&
        !root.toString().startsWith(projectCache.toString())) {
      throw StateError(
        'Use a project-local PUB_CACHE (.pub-cache) for local prebuilt builds. '
        'The shared Pub cache will not be modified.',
      );
    }

    final manifest = Directory.fromUri(root.resolve('rust/'));
    final provider = File.fromUri(
      root.resolve('cargokit/build_tool/lib/src/artifacts_provider.dart'),
    );
    final providerSource = provider.readAsStringSync();
    final patched = _strictProvider(providerSource);
    final hash = _crateHash(manifest, configuration);
    final crateConfig = File.fromUri(manifest.uri.resolve('cargokit.yaml'));
    if (!crateConfig.existsSync() ||
        crateConfig.readAsStringSync() != configuration) {
      crateConfig.writeAsStringSync(configuration);
    }
    if (providerSource != patched) provider.writeAsStringSync(patched);
    stdout.writeln(
      'rhttp ${lock['version']}: using signed prebuilts from '
      '${precompiled['url_prefix']}$hash; local Rust compilation is disabled.',
    );
  } catch (error) {
    stderr.writeln('Cannot prepare rhttp prebuilts: $error');
    exitCode = 1;
  }
}
