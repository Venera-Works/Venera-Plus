import 'download_retry.dart';
import 'local_storage_guard.dart';
import 'package:path/path.dart' as p;
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/missing_download_page.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/file_downloader.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:zip_flutter/zip_flutter.dart';

abstract class DownloadTask with ChangeNotifier {
  bool get isAwaitingMissingPages => false;
  Future<void> get pendingCleanup => Future.value();
  bool get isWaitingToRetry => false;
  void retryNow() {}

  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  void relocateOutput(String source, String destination) {
    final output = path;
    if (output != null && p.isWithin(source, output)) {
      path = p.join(destination, p.relative(output, from: source));
    }
  }

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    bool? skipUnavailableImages,
  }) : skipUnavailableImages =
           skipUnavailableImages ??
           appdata.settings['skipUnavailableDownloadImages'] == true;

  @override
  Future<void> get pendingCleanup =>
      _cancellation ?? _resumeFuture ?? Future.value();

  Future<void>? _cancellation;
  bool _cancelled = false;
  bool _awaitingMissingPages = false;
  bool _keepDownloadedFiles = false;
  bool _repairExisting = false;
  @override
  bool get isAwaitingMissingPages => _awaitingMissingPages;

  @override
  void relocateOutput(String source, String destination) {
    super.relocateOutput(source, destination);
    if (_cover?.startsWith('file://') == true &&
        p.isWithin(source, _cover!.substring(7))) {
      _cover =
          'file://${p.join(destination, p.relative(_cover!.substring(7), from: source))}';
    }
  }

  factory ImagesDownloadTask.repair(LocalComic local) {
    final source = ComicSource.fromIntKey(local.comicType.value);
    if (source == null) throw 'Comic source is unavailable'.tl;
    return ImagesDownloadTask(
        source: source,
        comicId: local.id,
        chapters: local.chapters == null
            ? null
            : local.incompleteChapters.keys.toList(),
        comicTitle: local.title,
      )
      ..path = local.baseDir
      .._cover = 'file://${local.coverFile.path}'
      .._keepDownloadedFiles = true
      .._repairExisting = true;
  }

  bool skipUnavailableImages;
  final _missingImages = <String, Set<int>>{};
  int get missingImageCount =>
      _missingImages.values.fold(0, (count, pages) => count + pages.length);
  DownloadRetry? _retry;
  int _generation = 0;
  bool _isCurrentRun(int generation) => _isRunning && generation == _generation;
  @override
  bool get isWaitingToRetry => _isRunning && (_retry?.isWaiting ?? false);
  @override
  void retryNow() {
    if (_isRunning) _retry?.wake();
  }

  Future<void> updateSkipUnavailableImages(bool value) async {
    skipUnavailableImages = value;
    notifyListeners();
    await LocalManager().saveCurrentDownloadingTasks();
  }

  String get _progressMessage => missingImageCount == 0
      ? '$_downloadedCount/$_totalCount'
      : 'Downloaded @a/@b; missing @c images'.tlParams({
          'a': _downloadedCount,
          'b': _totalCount,
          'c': missingImageCount,
        });

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    pause();
    _cancellation = () async {
      await _resumeFuture;
      final output = path;
      if (output == null) return;
      final local = LocalManager().find(id, comicType);
      if (_keepDownloadedFiles || local?.isIncomplete == true) return;
      try {
        if (local == null) {
          await Directory(output).delete(recursive: true);
        } else if (chapters != null) {
          for (final chapter in chapters!) {
            final directory = Directory(
              FilePath.join(
                output,
                LocalManager.getChapterDirectoryName(chapter),
              ),
            );
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          }
        }
      } catch (error, stack) {
        Log.error('Download cancellation', error, stack);
      }
    }();
    LocalManager().removeTask(this);
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _awaitingMissingPages
      ? '${'Waiting for missing pages'.tl}\n$_progressMessage'
      : isWaitingToRetry
      ? 'Connection interrupted. Waiting to retry...'.tl
      : _message;

  @override
  void pause() {
    if (isPaused) {
      stopRecorder();
      return;
    }
    _isRunning = false;
    _message = "Paused".tl;
    _currentSpeed = 0;
    _retry?.cancel();
    _generation++;
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
      }
    }
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...".tl;

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  Future<void>? _resumeFuture;

  @visibleForTesting
  Future<void>? get debugResumeFuture => _resumeFuture;

  Future<Res<T>> _runDownloadStepWithRetry<T>(Future<T> Function() task) async {
    try {
      return Res(await _retry!.run(task, retryUnknown: true));
    } catch (error) {
      return Res.error(error.toString());
    }
  }

  _ImageDownloadWrapper _createImageTask(String chapter, int index) {
    final saveTo = comic!.chapters == null
        ? Directory(path!)
        : Directory(
            FilePath.join(path!, LocalManager.getChapterDirectoryName(chapter)),
          );
    saveTo.createSync(recursive: true);
    return _ImageDownloadWrapper(
      this,
      chapter,
      _images![chapter]![index],
      saveTo,
      index,
    );
  }

  void _scheduleTasks() {
    if (!_isRunning) return;
    final chapter = _images!.keys.elementAt(_chapter);
    final images = _images![chapter]!;
    var downloading = tasks.values
        .where((task) => !task.isComplete && task.error == null)
        .length;
    final generation = _generation;
    for (
      var i = _index;
      i < images.length && downloading < _maxConcurrentTasks;
      i++
    ) {
      // A failed operation keeps its exhausted retry budget until the main loop handles it.
      if (tasks.containsKey(i)) continue;
      final task = tasks[i] = _createImageTask(chapter, i);
      downloading++;
      task.wait().then((finished) {
        if (_isCurrentRun(generation) && finished.isComplete) _scheduleTasks();
      });
    }
  }

  @override
  void resume() {
    if (_isRunning ||
        _cancelled ||
        LocalComicStorageGuard.instance.isExclusive) {
      return;
    }
    final previous = _resumeFuture;
    final transition = LocalManager().downloadTransition;
    final generation = ++_generation;
    _isRunning = true;
    _awaitingMissingPages = false;
    _isError = false;
    _message = 'Resuming...'.tl;
    notifyListeners();
    _resumeFuture = () async {
      await previous;
      await transition;
      if (!_isCurrentRun(generation)) return;
      if (LocalManager().downloadingTasks.contains(this) &&
          LocalManager().currentDownloadTask != this) {
        _isRunning = false;
        notifyListeners();
        return;
      }
      _retry = DownloadRetry(
        isActive: () => _isCurrentRun(generation),
        onWaitingChanged: notifyListeners,
      );
      try {
        await _download(generation);
      } catch (error, stack) {
        if (_isCurrentRun(generation)) {
          Log.error('Download', error, stack);
          _setError('Error: $error');
        }
      } finally {
        _retry?.cancel();
        final active = tasks.values.toList();
        for (final task in active) {
          if (!task.isComplete) task.cancel();
        }
        await Future.wait(active.map((task) => task.wait()));
        stopRecorder();
      }
    }();
  }

  Future<bool> _retryMissingImages(int generation) async {
    final missing = [
      for (final entry in _missingImages.entries)
        for (final index in entry.value) (entry.key, index),
    ];
    for (final (chapter, index) in missing) {
      final task = tasks[index] = _createImageTask(chapter, index);
      await task.wait();
      if (!_isCurrentRun(generation)) return false;
      tasks.remove(index);
      if (task.error != null) {
        if (!skipUnavailableImages || !task.canSkip) {
          _setError('Error: ${task.error}');
          return false;
        }
      } else {
        _missingImages[chapter]!.remove(index);
        if (_missingImages[chapter]!.isEmpty) _missingImages.remove(chapter);
        _downloadedCount++;
      }
      _message = _progressMessage;
      await LocalManager().saveCurrentDownloadingTasks();
    }
    return _isCurrentRun(generation);
  }

  Future<void> _download(int generation) async {
    _isError = false;
    _message = "Resuming...".tl;
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...".tl;
      notifyListeners();
      var res = await _runDownloadStepWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isCurrentRun(generation)) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...".tl;
      notifyListeners();
      var res = await _runDownloadStepWithRetry(() async {
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (!_isCurrentRun(generation)) {
        return;
      }
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...".tl;
        notifyListeners();
        var res = await _runDownloadStepWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isCurrentRun(generation)) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
        int cpCount = 0;
        int totalCpCount =
            chapters?.length ?? comic!.chapters!.allChapters.length;
        for (var i in comic!.chapters!.allChapters.keys) {
          if (chapters != null && !chapters!.contains(i)) {
            continue;
          }
          if (_images![i] != null) {
            _totalCount += _images![i]!.length;
            continue;
          }
          _message = "Fetching image list (@a/@b)...".tlParams({
            "a": cpCount,
            "b": totalCpCount,
          });
          notifyListeners();
          var res = await _runDownloadStepWithRetry(() async {
            var r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isCurrentRun(generation)) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images![i] = res.data;
            _totalCount += _images![i]!.length;
          }
        }
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_repairExisting) {
      final local = LocalManager().find(id, comicType);
      if (local == null) throw 'Comic Not Found';
      for (final entry in local.incompleteChapters.entries) {
        if (_images![entry.key]?.length != entry.value.pageCount) {
          throw 'The chapter page list changed. Download this chapter again instead of repairing it.'
              .tl;
        }
        final pages = await LocalManager().getImages(id, comicType, entry.key);
        _missingImages[entry.key] = {
          ...entry.value.missing,
          for (var index = 0; index < pages.length; index++)
            if (pages[index].startsWith(missingDownloadPagePrefix)) index,
        };
      }
      _chapter = _images!.length;
      _index = 0;
      _downloadedCount = _totalCount - missingImageCount;
      _repairExisting = false;
      await LocalManager().saveCurrentDownloadingTasks();
    }
    tasks.clear();
    if (!await _retryMissingImages(generation)) return;
    while (_chapter < _images!.length) {
      var images = _images![_images!.keys.elementAt(_chapter)]!;
      tasks.clear();
      while (_index < images.length) {
        _scheduleTasks();
        var task = tasks[_index]!;
        await task.wait();
        if (!_isCurrentRun(generation)) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          if (!skipUnavailableImages || !task.canSkip) {
            _setError("Error: ${task.error}");
            return;
          }
          (_missingImages[_images!.keys.elementAt(_chapter)] ??= {}).add(
            _index,
          );
        } else {
          _downloadedCount++;
        }
        _index++;
        _message = _progressMessage;
        await LocalManager().saveCurrentDownloadingTasks();
      }
      _index = 0;
      _chapter++;
    }

    if (missingImageCount > 0) {
      _isRunning = false;
      _awaitingMissingPages = true;
      _keepDownloadedFiles = true;
      try {
        await LocalManager().retainIncompleteTask(this);
      } catch (error, stack) {
        _awaitingMissingPages = false;
        Log.error('Download checkpoint', error, stack);
        _setError('Error: $error');
      }
      notifyListeners();
      return;
    }
    _isRunning = false;
    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
      "skipUnavailableImages": skipUnavailableImages,
      'awaitingMissingPages': _awaitingMissingPages,
      'keepDownloadedFiles': _keepDownloadedFiles,
      'repairExisting': _repairExisting,
      "missingImages": {
        for (final entry in _missingImages.entries)
          entry.key: entry.value.toList()..sort(),
      },
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    final task =
        ImagesDownloadTask(
            source: ComicSource.find(json["source"])!,
            comicId: json["comicId"],
            comic: json["comic"] == null
                ? null
                : ComicDetails.fromJson(json["comic"]),
            chapters: ListOrNull.from(json["chapters"]),
            skipUnavailableImages: json["skipUnavailableImages"] == true,
          )
          ..path = json["path"]
          .._cover = json["cover"]
          .._images = images
          .._downloadedCount = json["downloadedCount"]
          .._totalCount = json["totalCount"]
          .._index = json["index"]
          .._chapter = json["chapter"];
    final missing = json['missingImages'];
    if (missing is Map && images != null) {
      for (final entry in missing.entries) {
        final chapterImages = images[entry.key];
        if (chapterImages == null || entry.value is! List) continue;
        final indices = (entry.value as List)
            .whereType<int>()
            .where((index) => index >= 0 && index < chapterImages.length)
            .toSet();
        if (indices.isNotEmpty) {
          task._missingImages[entry.key as String] = indices;
        }
      }
    }
    task._awaitingMissingPages =
        json['awaitingMissingPages'] == true && task.missingImageCount > 0;
    task._keepDownloadedFiles =
        task._awaitingMissingPages || json['keepDownloadedFiles'] == true;
    task._repairExisting = json['repairExisting'] == true;
    return task;
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: (chapters ?? comic?.chapters?.ids.toList() ?? [])
          .where((chapter) => !_missingImages.containsKey(chapter))
          .toList(),
      incompleteChapters: {
        for (final entry in _missingImages.entries)
          entry.key: IncompleteChapter(
            pageCount: _images![entry.key]!.length,
            missing: entry.value,
          ),
      },
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

class _ImageDownloadWrapper {
  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    _finished = _start().then((_) => this);
  }
  final ImagesDownloadTask task;
  final String chapter;
  final String image;
  final Directory saveTo;
  final int index;
  bool isComplete = false;
  bool isCancelled = false;
  bool canSkip = false;
  Object? error;
  StreamIterator<ImageDownloadProgress>? _iterator;
  Future<void>? _cancelling;
  late final Future<_ImageDownloadWrapper> _finished;

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    _cancelling = _iterator?.cancel();
    _cancelling?.catchError((Object error, StackTrace stack) {
      Log.error('Download cancellation', error, stack);
    });
  }

  Future<void> _start() async {
    try {
      await task._retry!.run(_download, retryUnknown: true);
      isComplete = !isCancelled;
    } catch (failure, stack) {
      if (!isCancelled) {
        error = failure;
        canSkip = canSkipUnavailableDownloadImage(failure);
        Log.error('Download', failure, stack);
      }
    }
  }

  Future<void> _download() async {
    if (isCancelled) throw const DownloadCancelled();
    var lastBytes = 0;
    String? unsupportedMime;
    final iterator = StreamIterator(
      ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
      ),
    );
    _iterator = iterator;
    try {
      while (await iterator.moveNext()) {
        if (isCancelled) throw const DownloadCancelled();
        final progress = iterator.current;
        task.onData(progress.currentBytes - lastBytes);
        lastBytes = progress.currentBytes;
        final bytes = progress.imageBytes;
        if (bytes == null) continue;
        final fileType = detectFileType(bytes);
        final filename = '$index${fileType.ext}';
        if (!isComicImageFileName(filename)) {
          unsupportedMime = fileType.mime;
          continue;
        }
        await saveTo.joinFile(filename).writeAsBytes(bytes);
        if (isCancelled) throw const DownloadCancelled();
        return;
      }
      if (unsupportedMime != null) {
        throw UnsupportedDownloadImage(unsupportedMime);
      }
      throw StateError('Failed to download image');
    } finally {
      await (_cancelling ?? iterator.cancel());
      if (identical(_iterator, iterator)) _iterator = null;
    }
  }

  Future<_ImageDownloadWrapper> wait() => _finished;
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...".tl;

  DownloadRetry? _retry;
  Future<void>? _resumeFuture;
  Future<void>? _stopping;
  int _generation = 0;
  bool _isCurrentRun(int generation) => _isRunning && _generation == generation;
  @override
  Future<void> get pendingCleanup => _resumeFuture ?? Future.value();
  @override
  bool get isWaitingToRetry => _isRunning && (_retry?.isWaiting ?? false);
  @override
  void retryNow() {
    if (_isRunning) _retry?.wake();
  }

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    pause();
    await pendingCleanup;
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => isWaitingToRetry
      ? 'Connection interrupted. Waiting to retry...'.tl
      : _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused".tl;
    _generation++;
    _retry?.cancel();
    _stopping = _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() {
    if (_isRunning || LocalComicStorageGuard.instance.isExclusive) return;
    final previous = _resumeFuture;
    final transition = LocalManager().downloadTransition;
    final generation = ++_generation;
    _isRunning = true;
    notifyListeners();
    _resumeFuture = () async {
      await previous;
      await transition;
      await _stopping;
      if (!_isCurrentRun(generation)) return;
      _retry = DownloadRetry(
        isActive: () => _isCurrentRun(generation),
        onWaitingChanged: notifyListeners,
      );
      try {
        await _resume(generation);
      } catch (error, stack) {
        if (_isCurrentRun(generation)) {
          Log.error('Download', error, stack);
          _setError('Error: $error');
        }
      } finally {
        _retry?.cancel();
        await _stopping;
      }
    }();
  }

  Future<void> _resume(int generation) async {
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...".tl;

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(
      FilePath.join(App.dataPath, "archive_downloading.zip"),
    );

    Log.info("Download", "Downloading $archiveUrl");

    bool isDownloaded = false;
    try {
      await _retry!.run<void>(() async {
        final downloader = _downloader = FileDownloader(
          archiveUrl,
          archiveFile.path,
        );
        isDownloaded = false;
        try {
          await for (final status in downloader.start()) {
            if (!_isCurrentRun(generation)) throw const DownloadCancelled();
            _currentBytes = status.downloadedBytes;
            _expectedBytes = status.totalBytes;
            _message =
                '${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}';
            _speed = status.bytesPerSecond;
            isDownloaded = status.isFinished;
            notifyListeners();
          }
        } catch (_) {
          await downloader.stop();
          rethrow;
        }
      }, retryUnknown: true);
    } catch (error) {
      if (_isCurrentRun(generation)) _setError('Error: $error');
      return;
    }

    if (!_isCurrentRun(generation)) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    if (!_isCurrentRun(generation)) return;
    await archiveFile.deleteIgnoreError();

    _isRunning = false;
    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    final files = sortedComicImageEntries(
      Directory(path!).listSync().whereType<File>(),
      nameOf: (file) => file.name,
    );
    final cover = findNamedComicCover(files, nameOf: (file) => file.name);
    return (cover ?? files.first).name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
