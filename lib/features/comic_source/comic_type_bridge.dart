import 'package:venera_plus/foundation/comic_type.dart';

import 'source.dart';

void configureComicTypeSourceKeyResolver() {
  ComicType.configureSourceKeyResolver(
    (value) => ComicSource.fromIntKey(value)?.key,
  );
}

extension ComicTypeComicSource on ComicType {
  ComicSource? get comicSource {
    if (this == ComicType.local) {
      return null;
    }
    return ComicSource.fromIntKey(value);
  }
}
