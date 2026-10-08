import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/features/favorites/favorites.dart';

import 'init.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// The real dispatcher and CLI tests share this command grammar.
({String action, int argumentIndex}) parseHeadlessSyncCommand(
  List<String> args,
  int commandIndex,
) {
  if (commandIndex < 0 || commandIndex >= args.length) {
    throw const FormatException('Missing sync command.');
  }
  final grouped = args[commandIndex] == 'webdav';
  final actionIndex = commandIndex + (grouped ? 1 : 0);
  if (actionIndex >= args.length ||
      !(grouped
              ? const {'up', 'down', 'sync', 'conflicts', 'resolve'}
              : const {'sync', 'conflicts', 'resolve'})
          .contains(args[actionIndex])) {
    throw const FormatException(
      'Invalid sync command. Use webdav up, down, sync, conflicts, or resolve.',
    );
  }
  return (action: args[actionIndex], argumentIndex: actionIndex + 1);
}

/// IDs are opaque engine output, including duration-resolution candidates.
({String recordKey, String field, String candidateId})
parseHeadlessSyncResolveArguments(List<String> args, int startIndex) {
  String? recordKey;
  String? field;
  String? candidateId;
  final positional = <String>[];
  for (var i = startIndex; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      positional.add(arg);
      continue;
    }
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      throw FormatException('Missing value for $arg.');
    }
    final value = args[++i];
    switch (arg) {
      case '--record-key':
      case '--key':
        recordKey = value;
        break;
      case '--field':
        field = value;
        break;
      case '--candidate-id':
      case '--candidate':
        candidateId = value;
        break;
      default:
        throw FormatException('Unknown resolve argument: $arg.');
    }
  }
  if (positional.isNotEmpty) {
    if (positional.length != 3 ||
        recordKey != null ||
        field != null ||
        candidateId != null) {
      throw const FormatException(
        'Use three positional arguments or named resolve arguments, not both.',
      );
    }
    recordKey = positional[0];
    field = positional[1];
    candidateId = positional[2];
  }
  if (recordKey == null ||
      field == null ||
      candidateId == null ||
      recordKey.isEmpty ||
      field.isEmpty ||
      candidateId.isEmpty) {
    throw const FormatException(
      'Missing required arguments: record-key, field, and candidate-id are required.',
    );
  }
  return (recordKey: recordKey, field: field, candidateId: candidateId);
}

/// Never serialize MergeCandidate.toJson here: its value may contain credentials.
List<Map<String, Object?>> headlessSyncConflictPreviews(
  List<MergeConflict> conflicts,
) => [
  for (final conflict in conflicts)
    {
      'recordKey': conflict.recordKey,
      'field': conflict.field,
      'candidates': [
        for (final candidate in conflict.candidates)
          {
            'id': candidate.id,
            'actor': candidate.actor,
            'counter': candidate.counter,
            'isDeleted': candidate.isDeleted,
            'label': candidate.safeLabel,
          },
      ],
    },
];

/// Formats only safe, actionable issue metadata for CLI output.
List<Map<String, Object?>> headlessSyncSourceIssuePreviews(
  List<SyncSourceIssue> issues,
) {
  const safeReasons = {
    'emptyScript',
    'missingEntryClass',
    'syntaxError',
    'unsupportedHostApi',
    'timeout',
    'memoryLimit',
    'invalidKey',
    'evaluationError',
    'runtimeFailure',
    'invalidSession',
    'readFailure',
    'identityMismatch',
    'quarantineFailure',
    'quarantineFailed',
    'metadataCorrupted',
    'journalCorrupted',
    'concurrentModification',
    'writeFailure',
    'runtimeReloadDeferred',
    'runtimeReloadFailed',
    'repairPending',
  };
  return [
    for (final issue in issues)
      {
        'filename': issue.filename,
        'reason': safeReasons.contains(issue.reason) ? issue.reason : 'unknown',
        'reasonText': syncSourceIssueReasonText(
          safeReasons.contains(issue.reason) ? issue.reason : 'unknown',
        ),
        'hasBackup': issue.backupPath != null,
        if (issue.archiveName != null) 'archiveName': issue.archiveName,
        'originalBackupAction': issue.backupPath == null
            ? null
            : 'exportForForensicsInApp',
        if (!issue.recovered)
          'repairAction': switch (issue.reason) {
            'journalCorrupted' => 'requiresCompleteJournalBeforeRetry',
            'repairPending' ||
            'runtimeReloadDeferred' ||
            'runtimeReloadFailed' => 'retryRecoveryInApp',
            _ => 'replaceFileInApp',
          },
        'recovered': issue.recovered,
      },
  ];
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if (Platform.isLinux || Platform.isMacOS) {
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({
      'status': 'error',
      'message': 'No command provided for headless mode.',
    });
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length)
      ? args[commandIndex + 1]
      : null;

  switch (command) {
    case 'webdav':
    case 'sync':
    case 'conflicts':
    case 'resolve':
      try {
        final parsed = parseHeadlessSyncCommand(args, commandIndex);
        switch (parsed.action) {
          case 'up':
            await _handleWebdavTransfer(upload: true);
            break;
          case 'down':
            await _handleWebdavTransfer(upload: false);
            break;
          case 'sync':
            await _handleWebdavSync();
            break;
          case 'conflicts':
            await _handleWebdavConflicts();
            break;
          case 'resolve':
            await _handleWebdavResolve(args, parsed.argumentIndex);
            break;
        }
      } on FormatException catch (error) {
        cliPrint({'status': 'error', 'message': error.message});
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({
          'status': 'running',
          'message': 'Checking for comic source script updates...',
        });
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {'total': total, 'current': 0, 'updated': 0, 'errors': 0},
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                },
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {...data, 'error': e.toString()},
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
        }
      } else {
        cliPrint({
          'status': 'error',
          'message': 'Invalid updatescript command. Use "all".',
        });
        exit(1);
      }
      break;
    case 'updatesubscribe':
      try {
        cliPrint({
          'status': 'running',
          'message': 'Updating subscribed comics...',
        });
        await DataSync().waitForStartupMerge();
        await DataSync().waitForDownload();
        var folder = LocalFavoritesManager().readingFolder;
        if (folder == null) {
          cliPrint({
            'status': 'error',
            'message': 'Reading folder is not configured.',
          });
          exit(1);
        }

        var updateIndex = args.indexOf('--update-comic-by-id-type');
        if (updateIndex != -1) {
          if (updateIndex + 2 >= args.length) {
            cliPrint({
              'status': 'error',
              'message': 'Comic id and type are required.',
            });
            exit(1);
          }
          var id = args[updateIndex + 1];
          var type = args[updateIndex + 2];
          var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
          var comic = comics
              .where((c) => c.id == id && c.type.sourceKey == type)
              .firstOrNull;
          if (comic == null) {
            cliPrint({
              'status': 'error',
              'message': 'Comic is not in the Reading folder.',
            });
            exit(1);
          }

          var result = await updateComic(comic, folder);

          Map<String, dynamic> data = {
            'current': 1,
            'total': 1,
            'comic': {
              'id': comic.id,
              'name': comic.name,
              'coverUrl': comic.coverPath,
              'author': comic.author,
              'type': comic.type.sourceKey,
              'updateTime': comic.updateTime,
              'tags': comic.tags,
            },
          };

          var message = 'Progress';
          if (result.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = result.errorMessage;
          }

          cliPrint({'status': 'running', 'message': message, 'data': data});

          cliPrint({
            'status': 'running',
            'message': 'Update check complete.',
            'data': {
              'total': 1,
              'updated': result.updated ? 1 : 0,
              'errors': result.errorMessage != null ? 1 : 0,
            },
          });

          var json = await getUpdatedComicsAsJson(folder);
          cliPrint({
            'status': result.errorMessage != null ? 'error' : 'success',
            'message': 'Updated comics list.',
            'data': jsonDecode(json),
          });
          if (result.errorMessage != null) exit(1);
        } else {
          int total = 0;
          int updated = 0;
          int errors = 0;
          await for (var progress in updateFolder(folder, true)) {
            total = progress.total;
            updated = progress.updated;
            errors = progress.errors;
            Map<String, dynamic> data = {
              'current': progress.current,
              'total': progress.total,
            };
            if (progress.comic != null) {
              data['comic'] = {
                'id': progress.comic!.id,
                'name': progress.comic!.name,
                'coverUrl': progress.comic!.coverPath,
                'author': progress.comic!.author,
                'type': progress.comic!.type.sourceKey,
                'updateTime': progress.comic!.updateTime,
                'tags': progress.comic!.tags,
              };
            }
            var message = 'Progress';
            if (progress.errorMessage != null) {
              message = 'ProgressError';
              data['error'] = progress.errorMessage;
            }
            cliPrint({'status': 'running', 'message': message, 'data': data});
          }
          cliPrint({
            'status': 'running',
            'message': 'Update check complete.',
            'data': {'total': total, 'updated': updated, 'errors': errors},
          });
          var json = await getUpdatedComicsAsJson(folder);
          cliPrint({
            'status': errors > 0 ? 'error' : 'success',
            'message': 'Updated comics list.',
            'data': jsonDecode(json),
          });
          if (errors > 0) exit(1);
        }
      } catch (error, stack) {
        Log.error('Headless updates', error, stack);
        cliPrint({'status': 'error', 'message': error.toString()});
        exit(1);
      }
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}

Future<void> _handleWebdavTransfer({required bool upload}) async {
  cliPrint({
    'status': 'running',
    'message': upload
        ? 'Uploading WebDAV data...'
        : 'Downloading WebDAV data...',
  });
  await DataSync().waitForStartupMerge();
  await DataSync().waitForSync();
  final result = upload
      ? await DataSync().uploadData()
      : await DataSync().downloadData();
  if (result.error) {
    cliPrint({
      'status': 'error',
      'message':
          result.errorMessage ??
          (upload ? 'Upload failed.' : 'Download failed.'),
    });
    exit(1);
  }
  final snapshot = DataSync().statusSnapshot;
  if (snapshot.isPartial) {
    cliPrint({
      'status': 'partial',
      'message': upload
          ? 'Upload completed with partial sources.'
          : 'Download completed with partial sources.',
      'data': {
        'sourceIssues': headlessSyncSourceIssuePreviews(snapshot.sourceIssues),
        'unavailableDomains': snapshot.unavailableDomains.toList()..sort(),
      },
    });
  } else {
    cliPrint({
      'status': 'success',
      'message': upload ? 'Upload complete.' : 'Download complete.',
    });
  }
}

Future<void> _handleWebdavSync() async {
  cliPrint({'status': 'running', 'message': 'Syncing WebDAV data...'});
  await DataSync().waitForStartupMerge();
  await DataSync().waitForSync();
  final result = await DataSync().syncData();
  if (result.error) {
    cliPrint({
      'status': 'error',
      'message': result.errorMessage ?? 'Sync failed.',
    });
    exit(1);
  }
  final snapshot = DataSync().statusSnapshot;
  final conflicts = DataSync().conflicts;
  if (snapshot.isPartial) {
    cliPrint({
      'status': 'partial',
      'message': 'Sync completed with partial sources.',
      'data': {
        'conflictCount': conflicts.length,
        'hasConflict': conflicts.isNotEmpty,
        'sourceIssues': headlessSyncSourceIssuePreviews(snapshot.sourceIssues),
        'unavailableDomains': snapshot.unavailableDomains.toList()..sort(),
      },
    });
  } else {
    cliPrint({
      'status': 'success',
      'message': 'Sync complete.',
      'data': {
        'conflictCount': conflicts.length,
        'hasConflict': conflicts.isNotEmpty,
      },
    });
  }
}

Future<void> _handleWebdavConflicts() async {
  cliPrint({'status': 'running', 'message': 'Checking sync conflicts...'});
  await DataSync().waitForStartupMerge();
  await DataSync().waitForSync();
  final conflicts = DataSync().conflicts;
  final sanitizedConflicts = headlessSyncConflictPreviews(conflicts);
  cliPrint({
    'status': 'success',
    'message': 'Sync conflicts retrieved.',
    'data': {'count': conflicts.length, 'conflicts': sanitizedConflicts},
  });
}

Future<void> _handleWebdavResolve(List<String> args, int startIndex) async {
  final parsed = parseHeadlessSyncResolveArguments(args, startIndex);
  final recordKey = parsed.recordKey;
  final field = parsed.field;
  final candidateId = parsed.candidateId;

  cliPrint({'status': 'running', 'message': 'Resolving sync conflict...'});
  await DataSync().waitForStartupMerge();
  await DataSync().waitForSync();
  final result = await DataSync().resolveConflicts([
    MergeConflictResolution(
      recordKey: recordKey,
      field: field,
      candidateId: candidateId,
    ),
  ]);
  if (result.error) {
    cliPrint({
      'status': 'error',
      'message': result.errorMessage ?? 'Resolve conflict failed.',
    });
    exit(1);
  }
  cliPrint({
    'status': 'success',
    'message': 'Conflict resolved.',
    'data': {
      'recordKey': recordKey,
      'field': field,
      'candidateId': candidateId,
      'remainingConflicts': DataSync().conflicts.length,
    },
  });
}
