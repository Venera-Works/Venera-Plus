import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/history/image_favorites_models.dart';

void main() {
  ImageFavorite image(int page) => ImageFavorite(
    page,
    '$page.jpg',
    false,
    'chapter-1',
    'comic-1',
    1,
    'source',
    'Chapter 1',
  );

  ImageFavoritesComic comic() => ImageFavoritesComic(
    'comic-1',
    [],
    'Comic',
    'source',
    [],
    [],
    DateTime(2026),
    '',
    {},
    '',
    5,
  );

  bool toggle(ImageFavoritesComic comic, int page) => comic.toggleImageFavorite(
    image(page),
    firstImageKey: '1.jpg',
    chapterPageCount: 5,
  );

  test('repeated collection removes the bookmark and automatic cover', () {
    final favorites = comic();
    expect(toggle(favorites, 3), isTrue);
    expect(favorites.bookmarks.map((image) => image.page), [3]);
    expect(favorites.images.map((image) => image.page), containsAll([1, 3]));
    expect(toggle(favorites, 3), isFalse);
    expect(favorites.imageFavoritesEp, isEmpty);
    expect(toggle(favorites, 3), isTrue);
    expect(favorites.bookmarks.map((image) => image.page), [3]);
  });

  test('automatic cover can become a bookmark and return to cover only', () {
    final favorites = comic();
    toggle(favorites, 3);
    expect(toggle(favorites, 1), isTrue);
    expect(favorites.bookmarks.map((image) => image.page), containsAll([1, 3]));
    expect(toggle(favorites, 1), isFalse);
    expect(favorites.bookmarks.map((image) => image.page), [3]);
    final cover = favorites.images.singleWhere((image) => image.page == 1);
    expect(cover.isAutoFavorite, isTrue);
    expect(toggle(favorites, 3), isFalse);
    expect(favorites.images, isEmpty);
  });

  test(
    'collecting another page does not duplicate a manually collected cover',
    () {
      final favorites = comic();
      toggle(favorites, 1);
      toggle(favorites, 4);
      expect(favorites.images, hasLength(2));
      expect(favorites.bookmarks, hasLength(2));
      toggle(favorites, 4);
      expect(favorites.bookmarks.single.page, 1);
    },
  );

  test('manual cover can be uncollected while auto cover stays protected', () {
    final manualCover = ImageFavorite(
      1,
      'cover.jpg',
      null,
      'chapter-1',
      'comic-1',
      1,
      'source',
      'Chapter 1',
    );
    final autoCover = manualCover.copyWith(isAutoFavorite: true);

    expect(canUncollectImageFavorite(manualCover), isTrue);
    expect(canUncollectImageFavorite(autoCover), isFalse);
    expect(canUncollectImageFavorite(null), isFalse);
  });
}
