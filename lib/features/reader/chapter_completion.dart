import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/comic_type.dart';

@immutable
class ReaderChapterCompletedEvent {
  const ReaderChapterCompletedEvent({
    required this.sourceKey,
    required this.comicId,
    required this.chapterKey,
    this.chapterTitle,
    this.groupId,
    this.updateSnapshot,
    this.isLastChapter = false,
    this.comicType,
  });

  final String sourceKey;
  final String comicId;
  final String chapterKey;
  final String? chapterTitle;
  final String? groupId;
  final ComicUpdateSnapshot? updateSnapshot;
  final bool isLastChapter;
  final ComicType? comicType;

  @override
  bool operator ==(Object other) =>
      other is ReaderChapterCompletedEvent &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId &&
      other.chapterKey == chapterKey &&
      other.chapterTitle == chapterTitle &&
      other.groupId == groupId &&
      other.isLastChapter == isLastChapter &&
      other.updateSnapshot == updateSnapshot &&
      other.comicType == comicType;

  @override
  int get hashCode => Object.hash(
    sourceKey,
    comicId,
    chapterKey,
    chapterTitle,
    groupId,
    isLastChapter,
    updateSnapshot,
    comicType,
  );
}

typedef ReaderChapterCompletedHandler =
    FutureOr<void> Function(ReaderChapterCompletedEvent event);

ReaderChapterCompletedHandler? _chapterCompletedHandler;

void configureReaderChapterCompletedHandler(
  ReaderChapterCompletedHandler? handler,
) {
  _chapterCompletedHandler = handler;
}

bool isReaderChapterCompletionPosition({
  required bool isActive,
  required bool hasImages,
  required int page,
  required int lastImagePage,
  required int totalPages,
}) =>
    isActive &&
    hasImages &&
    lastImagePage > 0 &&
    page >= lastImagePage &&
    page <= totalPages;

/// Interface for reader controllers to report source size resolution and chapter readiness.
abstract interface class ChapterCompletionSourceController {
  bool isReadyForChapter(int chapter);
  bool isCurrentSourceSizeResolved();
  bool isAtLastVisualPartOfSource();
}

/// Verifies whether the reader can complete the current chapter, strictly gating
/// on source size resolution and controller readiness when gallery split is active.
bool canCompleteReaderChapter({
  required bool isContentReady,
  required bool isActive,
  required bool hasImages,
  required int page,
  required int lastImagePage,
  required int totalPages,
  required int chapter,
  required int maxChapter,
  required bool isGallerySplitEnabled,
  required ChapterCompletionSourceController? controller,
}) {
  if (!isContentReady) return false;
  if (chapter < 1 || chapter > maxChapter) return false;
  if (!isReaderChapterCompletionPosition(
    isActive: isActive,
    hasImages: hasImages,
    page: page,
    lastImagePage: lastImagePage,
    totalPages: totalPages,
  )) {
    return false;
  }
  if (isGallerySplitEnabled) {
    if (controller == null) return false;
    if (!controller.isReadyForChapter(chapter)) return false;
    if (!controller.isCurrentSourceSizeResolved()) return false;
    if (!controller.isAtLastVisualPartOfSource()) return false;
  } else {
    if (controller != null && !controller.isAtLastVisualPartOfSource()) {
      return false;
    }
  }
  return true;
}

class ReaderChapterCompletionNotifier {
  ReaderChapterCompletionNotifier([ReaderChapterCompletedHandler? handler])
    : _handler = handler ?? _chapterCompletedHandler;

  final ReaderChapterCompletedHandler? _handler;
  final Set<(String?, String)> _notified = <(String?, String)>{};

  Future<void> notify({
    required bool isAtEnd,
    required ReaderChapterCompletedEvent event,
  }) async {
    final handler = _handler;
    if (!isAtEnd ||
        handler == null ||
        !_notified.add((event.groupId, event.chapterKey))) {
      return;
    }
    await Future.sync(() => handler(event));
  }
}
