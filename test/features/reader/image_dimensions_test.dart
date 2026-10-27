import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/features/reader/comic_image.dart';

void main() {
  testWidgets(
    'pixel dimensions use the loaded image without changing its layout',
    (tester) async {
      final provider = MemoryImage(
        img.encodePng(img.Image(width: 200, height: 100)),
      );
      Widget host(bool show) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 100,
            child: ComicImage(image: provider, showDimensions: show),
          ),
        ),
      );
      await tester.pumpWidget(host(false));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byType(ComicImage));
      expect(find.text('200 × 100'), findsNothing);
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.text('200 × 100'), findsOneWidget);
      expect(tester.getSize(find.byType(ComicImage)), size);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(image));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
