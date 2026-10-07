import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/foundation/translations.dart';

void main() {
  late Directory safeTemp;
  var previousDataPath = Directory.systemTemp.path;
  var previousCachePath = Directory.systemTemp.path;

  setUpAll(() async {
    safeTemp = Directory.systemTemp.createTempSync('sync-dialog-widget-');
    try {
      previousDataPath = App.dataPath;
    } on Error {
      // A widget-only process has no initialized application profile.
    }
    try {
      previousCachePath = App.cachePath;
    } on Error {
      // Keep the restoration path isolated without an application profile.
    }
    App.dataPath = safeTemp.path;
    App.cachePath = safeTemp.path;
    await AppTranslation.init();
  });

  tearDownAll(() {
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    safeTemp.deleteSync(recursive: true);
  });

  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });

  group('formatCandidateSafePreview', () {
    test('masks cookies session data and tokens', () {
      final label = formatCandidateSafePreview(
        domain: 'cookies',
        field: 'value',
        value: [
          {'name': 'session_id', 'value': 'secret_token_12345'},
          {'name': 'auth', 'value': 'bearer_abcde'},
        ],
        isDeleted: false,
      );
      expect(label, contains('2'));
      expect(label.toLowerCase(), contains('cookie'));
      expect(label, isNot(contains('secret_token_12345')));
      expect(label, isNot(contains('bearer_abcde')));
    });

    test('masks sourceSession data', () {
      final label = formatCandidateSafePreview(
        domain: 'sourceSession',
        field: 'value',
        value: {'token': 'session_token_xyz', 'state': 'active'},
        isDeleted: false,
      );
      expect(label, isNot(contains('session_token_xyz')));
      expect(label, isNot(contains('active')));
    });

    test(
      'masks sensitive setting values based on field name or recordKey identity',
      () {
        for (final sensitiveField in [
          'token',
          'password',
          'authToken',
          'secretKey',
          'apiKey',
        ]) {
          final label = formatCandidateSafePreview(
            domain: 'setting',
            field: sensitiveField,
            value: 'super_secret_password_123',
            isDeleted: false,
          );
          expect(label, '***protected setting value***');
          expect(label, isNot(contains('super_secret_password_123')));
        }

        // When field is just 'value', but recordKey identity contains password/token/auth
        for (final keyIdentity in [
          ['webdav', 'password'],
          ['auth', 'token'],
          ['sync', 'secretKey'],
        ]) {
          final label = formatCandidateSafePreview(
            domain: 'setting',
            field: 'value',
            recordKey: syncRecordKey('setting', keyIdentity),
            value: 'super_secret_password_456',
            isDeleted: false,
          );
          expect(label, '***protected setting value***');
          expect(label, isNot(contains('super_secret_password_456')));
        }
      },
    );

    test(
      'displays comic source script as filename/version without full executable code',
      () {
        // Direct map
        final label = formatCandidateSafePreview(
          domain: 'source',
          field: 'script',
          value: {
            'name': 'Test Source',
            'filename': 'test_source.js',
            'version': '1.2.0',
            'content': 'function login() { return sendPassword("my_secret"); }',
          },
          isDeleted: false,
        );
        expect(label, contains('test_source.js'));
        expect(label, contains('1.2.0'));
        expect(label, isNot(contains('sendPassword')));
        expect(label, isNot(contains('my_secret')));

        // Nested script field: {'script': {'filename': ..., 'content': ...}}
        final nestedLabel = formatCandidateSafePreview(
          domain: 'source',
          field: 'script',
          value: {
            'script': {
              'filename': 'nested_source.js',
              'version': '3.0.0',
              'content': 'const secretKey = "do_not_leak";',
            },
          },
          isDeleted: false,
        );
        expect(nestedLabel, contains('nested_source.js'));
        expect(nestedLabel, contains('3.0.0'));
        expect(nestedLabel, isNot(contains('secretKey')));
        expect(nestedLabel, isNot(contains('do_not_leak')));
      },
    );

    test('displays reading progress with episode and page', () {
      final label = formatCandidateSafePreview(
        domain: 'history',
        field: 'progress',
        value: {'ep': 5, 'page': 21},
        isDeleted: false,
      );
      expect(label, contains('5'));
      expect(label, contains('21'));
    });

    test('clearly indicates deletion vs retention', () {
      final deleteLabel = formatCandidateSafePreview(
        domain: 'favorite',
        field: 'value',
        value: null,
        isDeleted: true,
      );
      expect(deleteLabel.toLowerCase(), contains('delete'));

      final retainLabel = formatCandidateSafePreview(
        domain: 'favorite',
        field: 'title',
        value: 'My Favorite Comic',
        isDeleted: false,
      );
      expect(retainLabel, 'My Favorite Comic');
    });

    test(
      'masks entire WebDAV credential roots, including flattened passwords',
      () {
        for (final root in ['backupWebdav', 'webdavComicLibrary']) {
          for (final identity in [
            [root],
            [root, '2'],
            [root, 'password'],
          ]) {
            final label = formatCandidateSafePreview(
              domain: 'setting',
              field: 'value',
              recordKey: syncRecordKey('setting', identity),
              value: identity.length == 1
                  ? ['secret-url', 'secret-user', 'secret-password']
                  : 'secret-password',
              isDeleted: false,
            );
            expect(label, '***protected setting value***');
            expect(label, isNot(contains('secret-')));
          }
        }
      },
    );

    test('presence never exposes technical values', () {
      for (final value in [true, 'present']) {
        expect(
          formatCandidateSafePreview(
            domain: 'favorite',
            field: 'presence',
            value: value,
            isDeleted: false,
          ),
          'Keep record'.tl,
        );
      }
      expect(
        formatCandidateSafePreview(
          domain: 'favorite',
          field: 'presence',
          value: 'deleted',
          isDeleted: true,
        ),
        'Delete record'.tl,
      );
    });
  });

  group('SyncConflictDialog widget', () {
    const actorA = 'device_12345678-1234-1234-1234-123456789abc';
    const actorB = 'device_87654321-4321-4321-4321-cba987654321';

    testWidgets('resolves only the chosen field of a real engine conflict', (
      tester,
    ) async {
      final key = syncRecordKey('history', ['comic', 1]);
      final previous = {
        key: <String, Object?>{
          'title': 'Original',
          'progress': {'ep': 1, 'page': 10},
        },
      };
      final base = MergeDocument()..captureLocal('seed', {}, previous);
      final left = MergeDocument.fromJson(base.toJson());
      final right = MergeDocument.fromJson(base.toJson());
      left.captureLocal(actorA, previous, {
        key: {
          'title': 'Left',
          'progress': {'ep': 1, 'page': 5},
        },
      });
      right.captureLocal(actorB, previous, {
        key: {
          'title': 'Right',
          'progress': {'ep': 2, 'page': 8},
        },
      });
      left.merge(right);
      final conflicts = left.conflicts;
      expect(conflicts, hasLength(2));
      final chosen = conflicts.first;
      final candidate = chosen.candidates.first;
      final calls = <({String recordKey, String field, String candidateId})>[];
      final resolution = Completer<Res<bool>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SyncConflictDialog(
              conflicts: conflicts,
              onResolve:
                  ({
                    required recordKey,
                    required field,
                    required candidateId,
                  }) async {
                    calls.add((
                      recordKey: recordKey,
                      field: field,
                      candidateId: candidateId,
                    ));
                    final result = await resolution.future;
                    if (result.error) return result;
                    left.resolve('resolver', recordKey, field, candidateId);
                    return result;
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey((key, chosen.field, candidate.id))));
      await tester.pump();
      expect(
        tester
            .widget<Button>(
              find.byKey(ValueKey((key, chosen.field, candidate.id))),
            )
            .isLoading,
        isTrue,
      );
      final other = conflicts.last;
      expect(
        tester
            .widget<Button>(
              find.byKey(
                ValueKey((key, other.field, other.candidates.first.id)),
              ),
            )
            .isLoading,
        isFalse,
      );
      resolution.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(calls, [
        (recordKey: key, field: chosen.field, candidateId: candidate.id),
      ]);
      expect(left.conflicts.single.field, conflicts.last.field);
      expect(find.byType(Card), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final language in ['en-US', 'zh-CN', 'zh-TW']) {
      for (final width in [320.0, 800.0]) {
        testWidgets('real UUID delete/keep dialog fits $language at $width', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final oldLanguage = appdata.settings['language'];
          appdata.settings['language'] = language;
          addTearDown(() => appdata.settings['language'] = oldLanguage);

          final key = syncRecordKey('favorite', ['folder', 'comic', 1]);
          final previous = {
            key: <String, Object?>{'title': 'Original'},
          };
          final base = MergeDocument()..captureLocal('seed', {}, previous);
          final left = MergeDocument.fromJson(base.toJson());
          final right = MergeDocument.fromJson(base.toJson());
          left.captureLocal(actorA, previous, {});
          right.captureLocal(actorB, previous, {
            key: {'title': 'Edited'},
          });
          left.merge(right);
          final conflict = left.conflicts.single;
          expect(conflict.field, 'presence');
          final deleted = conflict.candidates.singleWhere(
            (candidate) => candidate.isDeleted,
          );
          final calls = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SyncConflictDialog(
                  conflicts: [conflict],
                  onResolve:
                      ({
                        required recordKey,
                        required field,
                        required candidateId,
                      }) async {
                        calls.add(candidateId);
                        left.resolve('resolver', recordKey, field, candidateId);
                        return const Res(true);
                      },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Delete record'.tl), findsOneWidget);
          expect(find.text('Keep record'.tl), findsOneWidget);
          expect(find.textContaining('Record existence'.tl), findsOneWidget);
          expect(find.textContaining('presence'), findsNothing);
          expect(find.textContaining('present'), findsNothing);
          expect(find.textContaining('true'), findsNothing);
          expect(find.textContaining('false'), findsNothing);
          expect(find.byTooltip(actorA), findsOneWidget);
          expect(find.byTooltip(actorB), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(ValueKey((key, 'presence', deleted.id))));
          await tester.pumpAndSettle();
          expect(calls, [deleted.id]);
          expect(left.materialize().containsKey(key), isFalse);
          expect(find.text('All conflicts resolved'.tl), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
