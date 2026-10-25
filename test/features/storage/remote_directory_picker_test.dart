import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  testWidgets('checkboxes select across folders without navigating', (
    tester,
  ) async {
    final store = _DirectoryStore();
    RemoteFileStore? released;
    final result = await _openPicker(
      tester,
      store,
      initialDirectories: ['/Comics/Ongoing', '/Comics/Ongoing/'],
      disposeStore: true,
      onDisposeStore: (value) => released = value,
    );
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('1 folders selected'), findsOneWidget);
    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(_checkbox('Ongoing')).value, isTrue);

    final requests = List<String>.of(store.listed);
    await tester.tap(_checkbox('Completed'));
    await tester.pumpAndSettle();
    expect(store.listed, requests);
    expect(find.text('Current path: /Comics/'), findsOneWidget);
    expect(result.isCompleted, isFalse);

    await tester.tap(find.text('Empty'));
    await tester.pumpAndSettle();
    expect(find.text('No subfolders'), findsOneWidget);
    await tester.tap(_checkbox('Current folder'));
    await tester.pumpAndSettle();
    expect(find.text('3 folders selected'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Parent directory'),
        matching: find.byType(Checkbox),
      ),
      findsNothing,
    );

    await tester.tap(find.text('Parent directory'));
    await tester.pumpAndSettle();
    for (final name in ['Ongoing', 'Completed', 'Empty']) {
      expect(tester.widget<Checkbox>(_checkbox(name)).value, isTrue);
    }
    expect(result.isCompleted, isFalse);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result.future, [
      '/Comics/Ongoing/',
      '/Comics/Completed/',
      '/Comics/Empty/',
    ]);
    expect(store.cancelCount, 1);
    expect(released, same(store));
  });

  testWidgets('current root stays selectable when listing fails', (
    tester,
  ) async {
    final store = _DirectoryStore()..listingError = 'Unable to list folders';
    final result = await _openPicker(tester, store);
    expect(find.text('Unable to list folders'), findsOneWidget);
    expect(find.text('Root directory'), findsOneWidget);
    await tester.tap(_checkbox('Current folder'));
    await tester.pumpAndSettle();
    expect(find.text('1 folders selected'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result.future, ['/']);
  });

  testWidgets('multiple selections can be cleared explicitly', (tester) async {
    final store = _DirectoryStore();
    final result = await _openPicker(
      tester,
      store,
      initialDirectories: ['/Comics/'],
    );
    await tester.tap(_checkbox('Comics'));
    await tester.pumpAndSettle();
    expect(find.text('0 folders selected'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result.future, isEmpty);
  });

  testWidgets('going back discards changes and preserves initial directories', (
    tester,
  ) async {
    final initial = <String>['/Comics/'];
    final store = _DirectoryStore();
    final result = await _openPicker(
      tester,
      store,
      initialDirectories: initial,
    );
    await tester.tap(_checkbox('Backups'));
    await tester.pumpAndSettle();
    expect(find.text('2 folders selected'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await result.future, isNull);
    expect(initial, ['/Comics/']);
    expect(store.cancelCount, 0);
  });

  testWidgets('single selection replaces the target and waits for Done', (
    tester,
  ) async {
    final result = await _openPicker(
      tester,
      _DirectoryStore(),
      multiSelect: false,
      initialDirectories: ['/Comics/'],
    );
    await tester.tap(_checkbox('Backups'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(_checkbox('Comics')).value, isFalse);
    expect(tester.widget<Checkbox>(_checkbox('Backups')).value, isTrue);
    expect(find.text('1 folders selected'), findsOneWidget);
    expect(result.isCompleted, isFalse);

    await tester.tap(_checkbox('Backups'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
          .onPressed,
      isNull,
    );
    await tester.tap(_checkbox('Current folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result.future, ['/']);
  });

  for (final size in [const Size(320, 640), const Size(1200, 800)]) {
    testWidgets('Done stays at the bottom right at ${size.width}', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      final store = _DirectoryStore({
        '/': List.generate(
          20,
          (index) => RemoteEntry(
            name: 'A long folder name that should fit in one row $index',
            path: '/Folder $index/',
            isDirectory: true,
          ),
        ),
      });
      await _openPicker(tester, store, textScale: size.width < 600 ? 1.3 : 1);
      final done = find.widgetWithText(FilledButton, 'Done');
      final position = tester.getRect(done);
      final footer = tester.getRect(
        find.ancestor(of: done, matching: find.byType(Row)).first,
      );
      expect(position.right, closeTo(size.width - 16, 0.01));
      expect(footer.bottom, closeTo(size.height - 24 - 16, 0.01));
      expect(position.center.dy, closeTo(footer.center.dy, 0.01));
      expect(position.bottom, lessThanOrEqualTo(footer.bottom));
      expect(position.height, greaterThanOrEqualTo(52));
      expect(tester.widget<AppBar>(find.byType(AppBar)).actions, isNull);
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(tester.getRect(done), position);
      expect(done.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Finder _checkbox(String title) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byType(Checkbox),
);

Future<Completer<List<String>?>> _openPicker(
  WidgetTester tester,
  _DirectoryStore store, {
  List<String> initialDirectories = const [],
  bool multiSelect = true,
  bool disposeStore = false,
  void Function(RemoteFileStore)? onDisposeStore,
  double textScale = 1,
}) async {
  final result = Completer<List<String>?>();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.complete(
                await Navigator.of(context).push<List<String>>(
                  MaterialPageRoute(
                    builder: (_) => RemoteDirectoryPicker(
                      store: store,
                      initialDirectories: initialDirectories,
                      multiSelect: multiSelect,
                      disposeStore: disposeStore,
                      onDisposeStore: onDisposeStore,
                    ),
                  ),
                ),
              );
            },
            child: const Text('Choose folders'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Choose folders'));
  await tester.pumpAndSettle();
  return result;
}

class _DirectoryStore extends Fake implements RemoteFileStore {
  _DirectoryStore([this.directories = _directories]);

  final Map<String, List<RemoteEntry>> directories;
  final listed = <String>[];
  String? listingError;
  var cancelCount = 0;

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    listed.add(directory);
    if (listingError != null) throw RemoteStorageException(listingError!);
    return directories[directory] ?? const [];
  }

  @override
  Future<void> cancelAll() async => cancelCount++;
}

const _directories = <String, List<RemoteEntry>>{
  '/': [
    RemoteEntry(name: 'Comics', path: '/Comics', isDirectory: true),
    RemoteEntry(name: 'Backups', path: '/Backups/', isDirectory: true),
    RemoteEntry(name: 'notes.txt', path: '/notes.txt', isDirectory: false),
  ],
  '/Comics/': [
    RemoteEntry(name: 'Ongoing', path: '/Comics/Ongoing/', isDirectory: true),
    RemoteEntry(
      name: 'Completed',
      path: '/Comics/Completed/',
      isDirectory: true,
    ),
    RemoteEntry(name: 'Empty', path: '/Comics/Empty/', isDirectory: true),
  ],
};
