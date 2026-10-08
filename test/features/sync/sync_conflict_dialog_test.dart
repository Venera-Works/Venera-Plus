import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';
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
  });

  group('SyncConflictDialog widget', () {
    const actorA = 'device_12345678-1234-1234-1234-123456789abc';
    const actorB = 'device_87654321-4321-4321-4321-cba987654321';

    testWidgets(
      'stages independent choices, refreshes stale selections, and submits once',
      (tester) async {
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
        final titleConflict = conflicts.firstWhere(
          (conflict) => conflict.field == 'title',
        );
        final progressConflict = conflicts.firstWhere(
          (conflict) => conflict.field == 'progress',
        );
        final firstTitle = titleConflict.candidates.firstWhere(
          (candidate) => candidate.actor == actorA,
        );
        final changedTitle = titleConflict.candidates.firstWhere(
          (candidate) => candidate.actor == actorB,
        );
        final selectedProgress = progressConflict.candidates.firstWhere(
          (candidate) => candidate.actor == actorB,
        );
        final calls = <List<MergeConflictResolution>>[];
        final resolution = Completer<Res<bool>>();

        Future<Res<bool>> resolve(
          List<MergeConflictResolution> selections,
        ) async {
          calls.add(List.unmodifiable(selections));
          final result = await resolution.future;
          if (!result.error) {
            for (final selection in selections) {
              left.resolve(
                'resolver',
                selection.recordKey,
                selection.field,
                selection.candidateId,
              );
            }
          }
          return result;
        }

        Widget buildDialog(List<MergeConflict> active) => MaterialApp(
          home: Scaffold(
            body: SyncConflictDialog(
              key: const ValueKey('batch-conflict-dialog'),
              conflicts: active,
              onResolve: resolve,
            ),
          ),
        );

        Future<void> scrollToCandidate(Finder candidate) async {
          await tester.scrollUntilVisible(
            candidate,
            100,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(buildDialog(conflicts));
        await tester.pumpAndSettle();
        final firstTitleChoice = find.byKey(
          ValueKey((key, titleConflict.field, firstTitle.id)),
        );
        await scrollToCandidate(firstTitleChoice);
        await tester.tap(firstTitleChoice);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resolve Selected'.tl),
              )
              .onPressed,
          isNull,
        );
        expect(calls, isEmpty);
        expect(left.conflicts, hasLength(2));
        final changedTitleChoice = find.byKey(
          ValueKey((key, titleConflict.field, changedTitle.id)),
        );
        await scrollToCandidate(changedTitleChoice);
        await tester.tap(changedTitleChoice);
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(left.conflicts, hasLength(2));
        final progressChoice = find.byKey(
          ValueKey((key, progressConflict.field, selectedProgress.id)),
        );
        await scrollToCandidate(progressChoice);
        await tester.tap(progressChoice);
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(left.conflicts, hasLength(2));

        await tester.drag(find.byType(Scrollable).first, const Offset(0, 1000));
        await tester.pumpAndSettle();
        final lateDocument = MergeDocument()
          ..captureLocal('late-device', {}, {
            key: {'title': 'Late title'},
          });
        left.merge(lateDocument);
        final updatedConflicts = left.conflicts;
        await tester.pumpWidget(buildDialog(updatedConflicts));
        await tester.pumpAndSettle();
        final updatedTitle = updatedConflicts.firstWhere(
          (conflict) => conflict.field == 'title',
        );
        final lateTitle = updatedTitle.candidates.firstWhere(
          (candidate) => candidate.actor == 'late-device',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resolve Selected'.tl),
              )
              .onPressed,
          isNull,
        );

        final lateTitleChoice = find.byKey(
          ValueKey((key, updatedTitle.field, lateTitle.id)),
        );
        await scrollToCandidate(lateTitleChoice);
        await tester.tap(lateTitleChoice);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resolve Selected'.tl),
              )
              .onPressed,
          isNotNull,
        );
        expect(calls, isEmpty);
        expect(left.conflicts, hasLength(2));
        await tester.tap(find.text('Resolve Selected'.tl));
        await tester.pump();

        expect(calls, hasLength(1));
        expect(
          calls.single
              .map((selection) => (selection.field, selection.candidateId))
              .toSet(),
          {('title', lateTitle.id), ('progress', selectedProgress.id)},
        );
        for (final selection in calls.single) {
          final active = updatedConflicts.singleWhere(
            (conflict) => conflict.field == selection.field,
          );
          expect(selection.expectedCandidateIds, {
            for (final candidate in active.candidates) candidate.id,
          });
          expect(
            selection.expectedCandidateFingerprint,
            active.candidateFingerprint,
          );
        }
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Close'.tl),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        resolution.complete(const Res(true));
        await tester.pumpAndSettle();
        expect(left.conflicts, isEmpty);
        final materialized = left.materialize()[key];
        expect(materialized?['title'], 'Late title');
        expect(materialized?['progress'], {'ep': 2, 'page': 8});
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('closing a staged conflict applies no resolution', (
      tester,
    ) async {
      final key = syncRecordKey('favorite', ['cancel-selection']);
      final previous = {
        key: <String, Object?>{'title': 'Original'},
      };
      final base = MergeDocument()..captureLocal('seed', {}, previous);
      final left = MergeDocument.fromJson(base.toJson());
      final right = MergeDocument.fromJson(base.toJson());
      left.captureLocal(actorA, previous, {
        key: {'title': 'Left'},
      });
      right.captureLocal(actorB, previous, {
        key: {'title': 'Right'},
      });
      left.merge(right);
      final conflict = left.conflicts.single;
      final candidate = conflict.candidates.first;
      final calls = <List<MergeConflictResolution>>[];

      Future<Res<bool>> resolve(
        List<MergeConflictResolution> selections,
      ) async {
        calls.add(List.unmodifiable(selections));
        for (final selection in selections) {
          left.resolve(
            'resolver',
            selection.recordKey,
            selection.field,
            selection.candidateId,
          );
        }
        return const Res(true);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-conflicts'),
                onPressed: () {
                  showSyncConflictDialog(
                    context,
                    conflicts: [conflict],
                    onResolve: resolve,
                  );
                },
                child: const Text('Open conflicts'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-conflicts')));
      await tester.pumpAndSettle();
      final candidateChoice = find.byKey(
        ValueKey((key, conflict.field, candidate.id)),
      );
      await tester.scrollUntilVisible(
        candidateChoice,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(candidateChoice);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(left.conflicts, hasLength(1));

      await tester.tap(find.text('Close'.tl));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(left.conflicts, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    for (final language in ['en-US', 'zh-CN', 'zh-TW']) {
      for (final width in [320.0, 800.0]) {
        testWidgets(
          'presence conflict dialog fits $language at $width with 2x text',
          (tester) async {
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
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SyncConflictDialog(
                    conflicts: [conflict],
                    onResolve: (resolutions) async {
                      for (final resolution in resolutions) {
                        calls.add(resolution.candidateId);
                        left.resolve(
                          'resolver',
                          resolution.recordKey,
                          resolution.field,
                          resolution.candidateId,
                        );
                      }
                      return const Res(true);
                    },
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final deletedChoice = find.byKey(
              ValueKey((key, 'presence', deleted.id)),
            );
            await tester.scrollUntilVisible(
              deletedChoice,
              100,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(find.textContaining('presence'), findsNothing);
            expect(find.textContaining('present'), findsNothing);
            expect(find.textContaining('true'), findsNothing);
            expect(find.textContaining('false'), findsNothing);
            expect(find.byTooltip(actorA), findsOneWidget);
            expect(find.byTooltip(actorB), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.tap(deletedChoice);
            await tester.pumpAndSettle();
            expect(calls, isEmpty);
            expect(left.conflicts, hasLength(1));
            await tester.tap(find.text('Resolve Selected'.tl));
            await tester.pumpAndSettle();
            expect(calls, [deleted.id]);
            expect(left.materialize().containsKey(key), isFalse);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
