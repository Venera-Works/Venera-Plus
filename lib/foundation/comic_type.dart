typedef ComicTypeSourceKeyResolver = String? Function(int value);

class ComicType {
  final int value;

  const ComicType(this.value);

  static ComicTypeSourceKeyResolver? _sourceKeyResolver;

  static void configureSourceKeyResolver(ComicTypeSourceKeyResolver? resolver) {
    _sourceKeyResolver = resolver;
  }

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if (this == local) {
      return "local";
    }
    // 源被移除后仍保留可还原的标识，供已下载漫画离线阅读。
    return _sourceKeyResolver?.call(value) ?? 'Unknown:$value';
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    if (key == "local") {
      return local;
    }
    if (key.startsWith('Unknown:')) {
      final value = int.tryParse(key.substring('Unknown:'.length));
      if (value != null) return ComicType(value);
    }
    return ComicType(key.hashCode);
  }
}
