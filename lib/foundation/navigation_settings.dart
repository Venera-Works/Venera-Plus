enum LibrarySection { favorites, local, images, history }

enum DiscoverySection { browse, categories }

enum StartupPage {
  home('home'),
  library('library'),
  favorites('library.favorites'),
  browse('discover.browse'),
  categories('discover.categories');

  final String id;
  const StartupPage(this.id);

  static StartupPage fromId(Object? value) {
    if (value is String) {
      for (final page in StartupPage.values) {
        if (page.id == value) {
          return page;
        }
      }
    }
    return StartupPage.home;
  }
}

String normalizeStartupPage(Object? value) {
  if (value is int) {
    return switch (value) {
      0 => StartupPage.home.id,
      1 => StartupPage.favorites.id,
      2 => StartupPage.browse.id,
      3 => StartupPage.categories.id,
      _ => StartupPage.home.id,
    };
  }
  if (value is String) {
    return switch (value) {
      '0' => StartupPage.home.id,
      '1' => StartupPage.favorites.id,
      '2' => StartupPage.browse.id,
      '3' => StartupPage.categories.id,
      'home' ||
      'library' ||
      'library.favorites' ||
      'discover.browse' ||
      'discover.categories' => value,
      _ => StartupPage.home.id,
    };
  }
  return StartupPage.home.id;
}
