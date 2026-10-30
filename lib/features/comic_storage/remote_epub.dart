import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import 'archive_metadata.dart';
import 'comic_file_rules.dart';
import 'remote_zip.dart';

/// Image-only EPUB reading order. Image contents are never read while indexing.
class RemoteEpubIndex {
  RemoteEpubIndex._(this.metadata, List<String> pages, this.coverEntry)
    : pages = List.unmodifiable(pages);

  final ComicMetaData metadata;
  final List<String> pages;
  final String coverEntry;

  static Future<RemoteEpubIndex> read({
    required RemoteZipIndex zip,
    required ZipRangeRead read,
    String fallbackTitle = 'EPUB',
  }) async {
    final reader = _EpubReader(zip, read);
    if (reader.entries.containsKey('META-INF/encryption.xml')) {
      throw UnsupportedError('Encrypted EPUB resources are not supported');
    }
    final container = await reader.document('META-INF/container.xml');
    final rootFile = _elements(container, 'rootfile')
        .map((element) => element.getAttribute('full-path')?.trim())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (rootFile == null) {
      throw const FormatException('EPUB package document is missing');
    }
    final opfPath = _resolve('', rootFile);
    final opf = await reader.document(opfPath);
    final metadata = _elements(opf, 'metadata').firstOrNull;
    final opfTitle = metadata == null ? null : _firstText(metadata, 'title');
    final title = opfTitle?.isNotEmpty == true
        ? opfTitle!
        : fallbackTitle.trim().isEmpty
        ? 'EPUB'
        : fallbackTitle;
    final manifest = <String, _ManifestItem>{};
    final manifestElement = _elements(opf, 'manifest').firstOrNull;
    if (manifestElement == null) {
      throw const FormatException('EPUB manifest is missing');
    }
    for (final element in manifestElement.childElements.where(
      (element) => element.name.local == 'item',
    )) {
      final id = element.getAttribute('id')?.trim();
      final href = element.getAttribute('href')?.trim();
      if (id == null ||
          id.isEmpty ||
          href == null ||
          href.isEmpty ||
          manifest.containsKey(id)) {
        throw const FormatException('Invalid or duplicate EPUB manifest item');
      }
      manifest[id] = _ManifestItem(
        _resolve(opfPath, href),
        (element.getAttribute('media-type') ?? '').toLowerCase().trim(),
        _words(element.getAttribute('properties') ?? ''),
      );
    }
    final mediaTypes = {
      for (final item in manifest.values) item.name: item.mediaType,
    };
    final spine = _elements(opf, 'spine').firstOrNull;
    if (spine == null) {
      throw const FormatException('EPUB spine is missing');
    }
    final cover = await _findCover(reader, opf, opfPath, manifest, mediaTypes);
    final labels = await _navigationLabels(
      reader,
      manifest,
      spine.getAttribute('toc'),
    );
    final spineItems = <_ManifestItem>[];
    for (final reference in spine.childElements.where(
      (element) => element.name.local == 'itemref',
    )) {
      if (reference.getAttribute('linear')?.trim().toLowerCase() == 'no') {
        continue;
      }
      final item = manifest[reference.getAttribute('idref')?.trim()];
      if (item == null) {
        throw const FormatException('EPUB spine references a missing item');
      }
      spineItems.add(item);
    }
    await reader.prefetchDocuments(
      spineItems
          .where(
            (item) =>
                !_isRaster(item.name, item.mediaType) &&
                _documentMediaTypes.contains(item.mediaType),
          )
          .map((item) => item.name),
    );
    final sections = <_Section>[];
    for (final item in spineItems) {
      final images = (await _itemPages(
        reader,
        item,
        mediaTypes,
      )).where((image) => image != cover).toList();
      if (images.isNotEmpty) {
        final label = labels[item.name];
        sections.add(
          _Section(
            images,
            label != null && !_isPageMarker(label) && !_isGeneratorCredit(label)
                ? label
                : null,
          ),
        );
      }
    }
    final pages = sections.expand((section) => section.pages).toList();
    if (pages.isEmpty) {
      throw const FormatException('EPUB contains no supported image pages');
    }
    final chapters = <ComicChapter>[];
    if (sections.where((section) => section.label != null).length >= 2) {
      var nextPage = 1;
      var start = 1;
      String? chapterTitle;
      for (final section in sections) {
        if (section.label != null || chapterTitle == null) {
          if (chapterTitle != null) {
            chapters.add(
              ComicChapter(
                title: chapterTitle,
                start: start,
                end: nextPage - 1,
              ),
            );
          }
          chapterTitle = section.label ?? title;
          start = nextPage;
        }
        nextPage += section.pages.length;
      }
      chapters.add(
        ComicChapter(title: chapterTitle!, start: start, end: pages.length),
      );
    }
    final result = ComicMetaData(
      title: title,
      author: metadata == null ? '' : _texts(metadata, 'creator').join(', '),
      tags: metadata == null
          ? []
          : _texts(metadata, 'subject').toSet().toList(),
      description: metadata == null
          ? ''
          : _firstText(metadata, 'description') ?? '',
      chapters: chapters.isEmpty ? null : chapters,
    );
    result.validateChapterRanges(pageCount: pages.length);
    return RemoteEpubIndex._(result, pages, cover ?? pages.first);
  }
}

class _EpubReader {
  _EpubReader(this.zip, this.read) {
    for (final entry in zip.entries.where((entry) => !entry.isDirectory)) {
      if (entries.containsKey(entry.name)) {
        throw FormatException('Ambiguous EPUB ZIP entry: ${entry.name}');
      }
      entries[entry.name] = entry;
    }
  }

  final RemoteZipIndex zip;
  final ZipRangeRead read;
  final entries = <String, RemoteZipEntry>{};
  final _documents = <String, XmlDocument>{};
  final _reservedDocuments = <String>{};
  final _prefetched = <String, ({int offset, Uint8List bytes})>{};
  var _controlBytes = 0;

  RemoteZipEntry entry(String name) =>
      entries[name] ??
      (throw FormatException('EPUB resource is missing: $name'));

  RemoteZipEntry _reserveDocument(String name) {
    if (isComicImageFileName(name)) {
      throw UnsupportedError(
        'EPUB image cannot be used as a control document: $name',
      );
    }
    final file = entry(name);
    if (_reservedDocuments.add(name)) {
      const maxDocumentBytes = 4 * 1024 * 1024;
      const maxTotalBytes = 16 * 1024 * 1024;
      final size = file.uncompressedSize > file.compressedSize
          ? file.uncompressedSize
          : file.compressedSize;
      if (size > maxDocumentBytes || size > maxTotalBytes - _controlBytes) {
        throw const FormatException(
          'EPUB control documents exceed the size limit',
        );
      }
      _controlBytes += size;
    }
    return file;
  }

  Future<void> prefetchDocuments(Iterable<String> names) async {
    final pending = names
        .where((name) => !_documents.containsKey(name))
        .toSet();
    if (pending.isEmpty) return;
    for (final name in pending) {
      _reserveDocument(name);
    }
    final ordered = zip.entries.toList()
      ..sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));
    const maxRangeBytes = 2 * 1024 * 1024;
    const maxPrefetchBytes = 16 * 1024 * 1024;
    var prefetchedBytes = 0;
    for (var i = 0; i < ordered.length - 1; i++) {
      final first = ordered[i];
      if (!pending.contains(first.name)) continue;
      var end = i + 1;
      while (end < ordered.length - 1 &&
          pending.contains(ordered[end].name) &&
          ordered[end + 1].localHeaderOffset - first.localHeaderOffset <=
              maxRangeBytes) {
        end++;
      }
      // The next local header bounds the batch without including its payload.
      final length = ordered[end].localHeaderOffset - first.localHeaderOffset;
      if (length <= 0 || length > maxRangeBytes) continue;
      if (length > maxPrefetchBytes - prefetchedBytes) break;
      final bytes = await read(first.localHeaderOffset, length);
      if (bytes.length != length) {
        throw const FormatException('Truncated EPUB control range response');
      }
      prefetchedBytes += length;
      for (var j = i; j < end; j++) {
        final offset = ordered[j].localHeaderOffset;
        _prefetched[ordered[j].name] = (
          offset: offset,
          // Exact entry buffers keep ZIP decode isolates from copying a batch.
          bytes: Uint8List.fromList(
            Uint8List.sublistView(
              bytes,
              offset - first.localHeaderOffset,
              ordered[j + 1].localHeaderOffset - first.localHeaderOffset,
            ),
          ),
        );
      }
      i = end - 1;
    }
  }

  Future<XmlDocument> document(String name) async {
    final cached = _documents[name];
    if (cached != null) return cached;
    final file = _reserveDocument(name);
    final prefetched = _prefetched.remove(name);
    final bytes = await zip.readEntry(
      file,
      prefetched == null
          ? read
          : (offset, length) async {
              final start = offset - prefetched.offset;
              if (start < 0 || length > prefetched.bytes.length - start) {
                throw const FormatException(
                  'EPUB control document exceeds its ZIP entry boundary',
                );
              }
              return Uint8List.sublistView(
                prefetched.bytes,
                start,
                start + length,
              );
            },
      prefetch: false,
    );
    final text = utf8.decode(bytes);
    if (RegExp(r'<!\s*ENTITY\b', caseSensitive: false).hasMatch(text)) {
      throw UnsupportedError('EPUB XML entity declarations are not supported');
    }
    late final XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } on XmlException catch (error) {
      throw FormatException('Invalid EPUB XML in $name: $error');
    }
    for (final element in document.descendants.whereType<XmlElement>()) {
      final tag = element.name.local.toLowerCase();
      if (tag == 'script' ||
          element.attributes.any(
            (attribute) =>
                attribute.name.local.toLowerCase().startsWith('on') ||
                attribute.name.qualified == 'xml:base',
          )) {
        throw UnsupportedError(
          'Scripted EPUB pages and xml:base are not supported',
        );
      }
      for (final attribute in element.attributes.where(
        (attribute) =>
            attribute.name.local == 'href' || attribute.name.local == 'src',
      )) {
        _resolve(name, attribute.value);
      }
      final style = element.getAttribute('style') ?? '';
      final css = tag == 'style' ? '$style ${element.innerText}' : style;
      if (RegExp(
        r'url\s*\(|\bcontent\s*:',
        caseSensitive: false,
      ).hasMatch(css)) {
        throw UnsupportedError(
          'EPUB CSS image or generated content is not supported',
        );
      }
    }
    _documents[name] = document;
    return document;
  }
}

class _ManifestItem {
  const _ManifestItem(this.name, this.mediaType, this.properties);
  final String name;
  final String mediaType;
  final Set<String> properties;
}

class _Section {
  const _Section(this.pages, this.label);
  final List<String> pages;
  final String? label;
}

final _pageMarkerPattern = RegExp(
  r'^\s*(?:第?\s*\d+\s*[頁页叶葉]|(?:page|pg\.?|p\.)\s*[:\-_]?\s*\d+(?:\s*(?:/|of)\s*\d+)?)\s*$',
  caseSensitive: false,
);

final _generatorCreditPattern = RegExp(
  r'^(?:(?:\w+@\d{6,8})|(?:(?:created|generated|built)\s+by\b.*))$',
  caseSensitive: false,
);

bool _isPageMarker(String label) => _pageMarkerPattern.hasMatch(label);

bool _isGeneratorCredit(String label) =>
    _generatorCreditPattern.hasMatch(label);

const _documentMediaTypes = {
  'application/xhtml+xml',
  'text/html',
  'image/svg+xml',
};

bool _isRaster(String name, String mediaType) =>
    mediaType != 'image/svg+xml' &&
    comicFileExtension(name) != 'svg' &&
    (isComicImageFileName(name) ||
        const {
          'image/jpeg',
          'image/png',
          'image/webp',
          'image/gif',
          'image/avif',
        }.contains(mediaType));

Future<List<String>> _itemPages(
  _EpubReader reader,
  _ManifestItem item,
  Map<String, String> mediaTypes,
) async {
  reader.entry(item.name);
  if (_isRaster(item.name, item.mediaType)) return [item.name];
  if (!_documentMediaTypes.contains(item.mediaType)) {
    throw UnsupportedError('Unsupported EPUB spine content: ${item.mediaType}');
  }
  final document = await reader.document(item.name);
  final root = document.rootElement;
  final svg = root.name.local.toLowerCase() == 'svg';
  final body = svg ? root : _elements(root, 'body').firstOrNull;
  if (body == null) {
    throw FormatException('EPUB image document has no body: ${item.name}');
  }
  final pages = <String>[];
  void visit(XmlNode node, {bool annotation = false, bool inSvg = false}) {
    if (node is XmlText || node is XmlCDATA) {
      if (!annotation && node.value!.trim().isNotEmpty) {
        throw UnsupportedError(
          'Text-based or mixed-text EPUB content is not supported',
        );
      }
      return;
    }
    if (node is! XmlElement) return;
    final tag = node.name.local.toLowerCase();
    const allowed = {
      'body',
      'div',
      'p',
      'span',
      'section',
      'article',
      'main',
      'figure',
      'center',
      'a',
      'br',
      'hr',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'img',
      'svg',
      'g',
      'image',
      'title',
      'desc',
    };
    if (!allowed.contains(tag)) {
      throw UnsupportedError('Unsupported static EPUB page element: $tag');
    }
    if (tag == 'a' && node.getAttribute('href') != null) {
      _resolve(item.name, node.getAttribute('href')!);
    }
    if (tag == 'img' || tag == 'image') {
      if (node.getAttribute('srcset') != null) {
        throw UnsupportedError(
          'EPUB responsive image selection is not supported',
        );
      }
      final reference = tag == 'img'
          ? node.getAttribute('src')
          : node.attributes
                .where((attribute) => attribute.name.local == 'href')
                .map((attribute) => attribute.value)
                .firstOrNull;
      if (reference == null || reference.trim().isEmpty) {
        throw const FormatException('EPUB image reference is missing');
      }
      final image = _resolve(item.name, reference);
      reader.entry(image);
      if (!_isRaster(image, mediaTypes[image] ?? '')) {
        throw UnsupportedError('Unsupported EPUB image resource: $image');
      }
      pages.add(image);
    }
    final insideSvg = inSvg || tag == 'svg';
    final isAnnotation =
        annotation ||
        RegExp(r'^h[1-6]$').hasMatch(tag) ||
        insideSvg && (tag == 'title' || tag == 'desc');
    for (final child in node.children) {
      visit(child, annotation: isAnnotation, inSvg: insideSvg);
    }
  }

  visit(body, inSvg: svg);
  return pages;
}

Future<String?> _findCover(
  _EpubReader reader,
  XmlDocument opf,
  String opfPath,
  Map<String, _ManifestItem> manifest,
  Map<String, String> mediaTypes,
) async {
  _ManifestItem? cover = manifest.values
      .where((item) => item.properties.contains('cover-image'))
      .firstOrNull;
  if (cover == null) {
    final coverId = _elements(opf, 'meta')
        .where(
          (element) => element.getAttribute('name')?.toLowerCase() == 'cover',
        )
        .map((element) => element.getAttribute('content')?.trim())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (coverId != null) {
      cover = manifest[coverId];
      if (cover == null) {
        throw const FormatException('EPUB cover manifest item is missing');
      }
    }
  }
  if (cover == null) {
    final guide = _elements(opf, 'reference')
        .where(
          (element) =>
              _words(element.getAttribute('type') ?? '').contains('cover'),
        )
        .firstOrNull;
    if (guide != null) {
      final href = guide.getAttribute('href');
      if (href == null || href.trim().isEmpty) {
        throw const FormatException('EPUB cover guide reference is missing');
      }
      final name = _resolve(opfPath, href);
      cover =
          manifest.values.where((item) => item.name == name).firstOrNull ??
          _ManifestItem(
            name,
            isComicImageFileName(name) ? '' : 'application/xhtml+xml',
            const <String>{},
          );
    }
  }
  if (cover == null) return null;
  final pages = await _itemPages(reader, cover, mediaTypes);
  if (pages.isEmpty) throw const FormatException('EPUB cover has no image');
  return pages.first;
}

Future<Map<String, String>> _navigationLabels(
  _EpubReader reader,
  Map<String, _ManifestItem> manifest,
  String? tocId,
) async {
  final labels = <String, String>{};
  final nav = manifest.values
      .where((item) => item.properties.contains('nav'))
      .firstOrNull;
  if (nav != null) {
    final document = await reader.document(nav.name);
    for (final toc in _elements(document, 'nav').where(
      (element) => element.attributes.any(
        (attribute) =>
            attribute.name.local == 'type' &&
            _words(attribute.value).contains('toc'),
      ),
    )) {
      for (final anchor in _elements(toc, 'a')) {
        final href = anchor.getAttribute('href');
        final title = anchor.innerText.trim();
        if (href == null || href.trim().isEmpty || title.isEmpty) continue;
        labels.putIfAbsent(_resolve(nav.name, href), () => title);
      }
    }
  }
  final ncx = tocId == null || tocId.trim().isEmpty
      ? manifest.values
            .where((item) => item.mediaType == 'application/x-dtbncx+xml')
            .firstOrNull
      : manifest[tocId.trim()];
  if (tocId?.trim().isNotEmpty == true && ncx == null) {
    throw const FormatException('EPUB NCX manifest item is missing');
  }
  if (ncx != null) {
    final document = await reader.document(ncx.name);
    for (final point in _elements(document, 'navPoint')) {
      final content = point.childElements
          .where((element) => element.name.local == 'content')
          .firstOrNull;
      final label = point.childElements
          .where((element) => element.name.local == 'navLabel')
          .firstOrNull;
      final href = content?.getAttribute('src');
      final title = label == null ? null : _firstText(label, 'text');
      if (href == null ||
          href.trim().isEmpty ||
          title == null ||
          title.isEmpty) {
        continue;
      }
      labels.putIfAbsent(_resolve(ncx.name, href), () => title);
    }
  }
  return labels;
}

Iterable<XmlElement> _elements(XmlNode node, String name) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == name);

Iterable<String> _texts(XmlNode node, String name) => _elements(
  node,
  name,
).map((element) => element.innerText.trim()).where((text) => text.isNotEmpty);

String? _firstText(XmlNode node, String name) => _texts(node, name).firstOrNull;
Set<String> _words(String value) =>
    value.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toSet();

String _resolve(String base, String reference) {
  final uri = Uri.tryParse(reference.trim());
  if (uri == null || uri.hasScheme || uri.hasAuthority) {
    throw FormatException('EPUB contains an external reference: $reference');
  }
  final decoded = Uri.decodeComponent(uri.path).replaceAll('\\', '/');
  if (decoded.isEmpty) {
    if (base.isNotEmpty && (uri.hasFragment || uri.hasQuery)) return base;
    throw const FormatException('EPUB reference path is empty');
  }
  if (decoded.startsWith('/') ||
      decoded.contains(':') ||
      decoded.contains('\u0000')) {
    throw FormatException(
      'EPUB contains an absolute or invalid path: $reference',
    );
  }
  final resolved = path.posix.normalize(
    path.posix.join(path.posix.dirname(base), decoded),
  );
  if (resolved == '.' ||
      resolved == '..' ||
      resolved.startsWith('../') ||
      path.posix.isAbsolute(resolved)) {
    throw FormatException('EPUB path escapes the archive: $reference');
  }
  return resolved;
}
