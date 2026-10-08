import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_runtime/headless.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/sync_records.dart';

void main() {
  test(
    'real CLI conflict output excludes credential and executable values',
    () {
      final original = MergeDocument();
      final previous = <String, Map<String, Object?>>{};
      for (final root in ['backupWebdav', 'webdavComicLibrary']) {
        previous[syncRecordKey('setting', [root])] = {
          'value': ['https://example.com', 'old-user', 'old-password'],
        };
        previous[syncRecordKey('setting', [root, '2'])] = {
          'value': 'old-password',
        };
      }
      previous[syncRecordKey('cookies', ['example.com'])] = {
        'value': [
          {'name': 'session', 'value': 'old-cookie'},
        ],
      };
      previous[syncRecordKey('source', ['plugin'])] = {
        'script': {'filename': 'plugin.js', 'content': 'old script'},
      };
      original.captureLocal('seed', {}, previous);
      final left = MergeDocument.fromJson(original.toJson());
      final right = MergeDocument.fromJson(original.toJson());
      final current = cloneSyncRecords(previous);
      for (final fields in current.values) {
        if (fields.containsKey('script')) {
          fields['script'] = {
            'filename': 'plugin.js',
            'content': 'secret-executable',
          };
        } else if (fields['value'] is List) {
          fields['value'] = ['secret-url', 'secret-user', 'secret-password'];
        } else {
          fields['value'] = 'secret-nested-password';
        }
      }
      left.captureLocal('left', previous, current);
      final other = cloneSyncRecords(previous);
      for (final fields in other.values) {
        fields[fields.containsKey('script')
            ? 'script'
            : 'value'] = fields.containsKey('script')
            ? {'filename': 'other.js', 'content': 'other-secret-executable'}
            : 'other-secret-value';
      }
      right.captureLocal('right', previous, other);
      left.merge(right);

      final output = headlessSyncConflictPreviews(left.conflicts);
      expect(output, hasLength(previous.length));
      final encoded = jsonEncode(output);
      for (final secret in [
        'secret-url',
        'secret-user',
        'secret-password',
        'secret-nested-password',
        'secret-executable',
        'other-secret-value',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      for (var i = 0; i < output.length; i++) {
        final candidates = output[i]['candidates'] as List;
        for (var j = 0; j < candidates.length; j++) {
          final preview = candidates[j] as Map;
          expect(preview.containsKey('value'), isFalse);
          expect(preview['id'], left.conflicts[i].candidates[j].id);
        }
      }
    },
  );

  test('actual command grammar maps all WebDAV commands and root aliases', () {
    for (final action in ['up', 'down', 'sync', 'conflicts', 'resolve']) {
      expect(parseHeadlessSyncCommand(['--headless', 'webdav', action], 1), (
        action: action,
        argumentIndex: 3,
      ));
    }
    for (final action in ['sync', 'conflicts', 'resolve']) {
      expect(parseHeadlessSyncCommand(['--headless', action], 1), (
        action: action,
        argumentIndex: 2,
      ));
    }
    expect(
      () => parseHeadlessSyncCommand(['--headless', 'webdav'], 1),
      throwsFormatException,
    );
    expect(
      () => parseHeadlessSyncCommand(['--headless', 'up'], 1),
      throwsFormatException,
    );
  });

  test('production resolve parser forwards opaque engine IDs unchanged', () {
    final key = syncRecordKey('history', ['comic', 1]);
    const id = 'device_12345678-1234-1234-1234-123456789abc:27';
    for (final flags in [
      ['--record-key', key, '--field', 'presence', '--candidate-id', id],
      ['--key', key, '--field', 'presence', '--candidate', id],
      [key, 'presence', id],
    ]) {
      expect(parseHeadlessSyncResolveArguments(flags, 0), (
        recordKey: key,
        field: 'presence',
        candidateId: id,
      ));
    }
    expect(
      parseHeadlessSyncResolveArguments([
        key,
        'readDurationMs',
        'accumulated_total',
      ], 0),
      (
        recordKey: key,
        field: 'readDurationMs',
        candidateId: 'accumulated_total',
      ),
    );
    for (final invalid in [
      ['--record-key', key, '--field'],
      ['--record-key', key, '--field', 'title'],
      [key, 'title', id, 'extra'],
      ['--unknown', key, '--field', 'title', '--candidate', id],
    ]) {
      expect(
        () => parseHeadlessSyncResolveArguments(invalid, 0),
        throwsFormatException,
      );
    }
  });

  test(
    'headless source issue previews expose translated safe repair actions without payloads',
    () {
      const issues = [
        SyncSourceIssue(
          filename: 'komiic.js',
          reason: 'emptyScript',
          sourceKey: 'secret-source-key',
          backupPath: '/private/secret/backup.js',
          archiveName: 'legacy.venera',
          recovered: false,
        ),
        SyncSourceIssue(filename: 'corrupted.js', reason: 'password=secret'),
        SyncSourceIssue(
          filename: '.recovery_journal.json',
          reason: 'repairPending',
        ),
        SyncSourceIssue(
          filename: '.quarantine_journal.json',
          reason: 'journalCorrupted',
        ),
      ];

      final output = headlessSyncSourceIssuePreviews(issues);
      expect(output[0]['reason'], 'emptyScript');
      expect(output[0]['hasBackup'], isTrue);
      expect(output[0]['originalBackupAction'], 'exportForForensicsInApp');
      expect(output[0]['repairAction'], 'replaceFileInApp');

      expect(output[1]['reason'], 'unknown');
      expect(output[1]['hasBackup'], isFalse);
      expect(output[1]['originalBackupAction'], isNull);
      expect(output[1]['repairAction'], 'replaceFileInApp');
      expect(output[2]['reason'], 'repairPending');
      expect(output[2]['repairAction'], 'retryRecoveryInApp');
      expect(output[3]['repairAction'], 'requiresCompleteJournalBeforeRetry');

      final encoded = jsonEncode(output);
      expect(encoded, isNot(contains('secret')));
      expect(encoded, isNot(contains('password')));
      expect(encoded, isNot(contains('backupPath')));
      expect(encoded, isNot(contains('sourceKey')));
    },
  );
}
