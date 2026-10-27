import 'package:pdfrx/pdfrx.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/local_comics/import_export/document_import.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/features/local_comics/local_storage_guard.dart';
import 'package:venera_plus/foundation/file_system.dart';

export 'package:venera_plus/features/comic_storage/comic_storage.dart'
    show PdfRenderSize, PdfPageRenderException, calculatePdfRenderSize;

abstract final class PdfComicImporter {
  static Future<LocalComic> import(
    File file, {
    String? title,
    DocumentImportProgress? onProgress,
    DocumentImportCancellation? cancellation,
    Future<void> Function(LocalComic comic)? registerComic,
  }) async {
    cancellation?.throwIfCancelled();
    await pdfrxFlutterInitialize();
    late final PdfDocument document;
    try {
      document = await PdfDocument.openFile(file.path);
    } on PdfPasswordException {
      throw const FormatException(
        'Password-protected PDF files are not supported',
      );
    }
    return importDocument(
      document,
      title: title ?? file.basenameWithoutExt,
      onProgress: onProgress,
      cancellation: cancellation,
      registerComic: registerComic,
    );
  }

  /// Takes ownership of [document] and closes it even if conversion fails.
  /// The output is committed only after [registerComic] succeeds, when supplied.
  static Future<LocalComic> importDocument(
    PdfDocument document, {
    required String title,
    DocumentImportProgress? onProgress,
    DocumentImportCancellation? cancellation,
    Future<void> Function(LocalComic comic)? registerComic,
  }) => LocalComicStorageGuard.instance.runImport(
    () => _importDocument(
      document,
      title: title,
      onProgress: onProgress,
      cancellation: cancellation,
      registerComic: registerComic,
    ),
  );

  static Future<LocalComic> _importDocument(
    PdfDocument document, {
    required String title,
    DocumentImportProgress? onProgress,
    DocumentImportCancellation? cancellation,
    Future<void> Function(LocalComic comic)? registerComic,
  }) async {
    DocumentImportSession? session;
    try {
      cancellation?.throwIfCancelled();
      if (document.pages.isEmpty) {
        throw const FormatException('PDF contains no pages');
      }

      session = DocumentImportSession.start(title);
      final total = document.pages.length;
      onProgress?.call(0, total);
      for (var i = 0; i < total; i++) {
        cancellation?.throwIfCancelled();
        final page = document.pages[i];
        final size = calculatePdfRenderSize(page.width, page.height);
        final rendered = await page.render(
          fullWidth: size.width.toDouble(),
          fullHeight: size.height.toDouble(),
        );
        if (rendered == null) {
          cancellation?.throwIfCancelled();
          throw PdfPageRenderException(i + 1);
        }
        try {
          cancellation?.throwIfCancelled();
          final encoded = await encodePdfPageJpeg(
            pixels: rendered.pixels,
            width: rendered.width,
            height: rendered.height,
          );
          cancellation?.throwIfCancelled();
          final pageFile = File(
            session.pagePath(pageIndex: i + 1, extension: 'jpg'),
          );
          await pageFile.writeAsBytes(encoded);
          if (i == 0) {
            await pageFile.copyMem(
              FilePath.join(session.directory.path, 'cover.jpg'),
            );
          }
        } finally {
          rendered.dispose();
        }
        onProgress?.call(i + 1, total);
      }

      cancellation?.throwIfCancelled();
      final comic = session.finish(
        author: '',
        tags: const [],
        cover: 'cover.jpg',
      );
      await registerComic?.call(comic);
      return comic;
    } catch (_) {
      await session?.abort();
      rethrow;
    } finally {
      await document.dispose();
    }
  }
}
