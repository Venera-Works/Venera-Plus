import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/keyword_settings_store.dart';

void main() {
  late Map<String, dynamic> previous;
  late KeywordSettingsStore store;
  late Future<void> Function() persist;
  const keys = [
    'blockedWords',
    'blockedWordRules',
    'language',
    'comicDisplayMode',
    'showFavoriteStatusOnTile',
    'showHistoryStatusOnTile',
  ];
  setUp(() {
    previous = {for (final key in keys) key: appdata.settings[key]};
    appdata.settings.setKeywordSettings(
      'blockedWords',
      [],
      'blockedWordRules',
      {},
    );
    appdata.settings['language'] = 'en-US';
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    persist = () async {};
  });
  tearDown(() {
    previous.forEach((key, value) => appdata.settings[key] = value);
    configureComicWidgets();
  });

  Widget editor({KeywordRule? rule}) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showKeywordRuleEditor(
            context,
            target: BlockedKeywordList.comics,
            rule: rule,
            store: store,
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );

  void testKeywordWidgets(
    String name,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(name, (tester) async {
      // Keep queue microtasks in the same fake-async zone as the widget.
      store = KeywordSettingsStore(
        readSettings: () => {
          'blockedWords': appdata.settings['blockedWords'],
          'blockedWordRules': appdata.settings['blockedWordRules'],
        },
        writeSettings: (target, words, rules) => appdata.settings
            .setKeywordSettings(target.key, words, target.rulesKey, rules),
        persist: () => persist(),
      );
      await body(tester);
    });
  }

  testKeywordWidgets(
    'short word preview highlights literal match and excludes longer words',
    (tester) async {
      await tester.pumpWidget(editor());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyword-rule-word')),
        'BL',
      );
      await tester.tap(find.text('Try matching'));
      await tester.pumpAndSettle();
      final sample = find.byKey(const ValueKey('keyword-rule-sample'));
      await tester.enterText(sample, 'black');
      await tester.pump();
      expect(find.text('Will stay visible'), findsOneWidget);
      await tester.enterText(sample, '[bl]');
      await tester.pump();
      expect(find.text('Will be hidden'), findsOneWidget);
      final preview = tester.widget<Text>(
        find.descendant(
          of: find.byType(KeywordMatchPreview),
          matching: find.byType(Text),
        ),
      );
      expect(preview.textSpan!.toPlainText(), '[bl]');
      final spans = (preview.textSpan as TextSpan).children!.cast<TextSpan>();
      expect(spans[1].text, 'bl');
      expect(spans[1].style?.backgroundColor, isNotNull);
    },
  );

  testKeywordWidgets(
    'failed accepted save stays retryable without losing draft',
    (tester) async {
      persist = () async {
        throw StateError('disk full');
      };
      await tester.pumpWidget(editor());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyword-rule-word')),
        'BL',
      );
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();
      expect(find.text('Failed to save keyword rules'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      persist = () async {};
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(KeywordRuleEditor), findsNothing);
      expect(
        store.ruleFor(BlockedKeywordList.comics, 'BL')?.mode,
        KeywordMatchMode.word,
      );
      expect(appdata.settings['blockedWords'], ['BL']);
    },
  );

  testKeywordWidgets(
    'old editor reports concurrent edits and cannot recreate deleted rules',
    (tester) async {
      const original = KeywordRule('BL');
      await store.saveRule(BlockedKeywordList.comics, original);
      await tester.pumpWidget(editor(rule: original));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await store.removeRule(BlockedKeywordList.comics, original);
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(
        find.text('The rule changed. Close and reopen the editor.'),
        findsOneWidget,
      );
      expect(store.rules(BlockedKeywordList.comics), isEmpty);
    },
  );

  testKeywordWidgets('accepted save completes when editor route is closed', (
    tester,
  ) async {
    final barrier = Completer<void>();
    persist = () => barrier.future;
    await tester.pumpWidget(editor());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('keyword-rule-word')),
      'BL',
    );
    await tester.tap(find.text('Add').last);
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(KeywordRuleEditor), findsNothing);
    barrier.complete();
    await tester.pumpAndSettle();
    expect(store.pending, 0);
    expect(store.error, isNull);
    expect(
      store.ruleFor(BlockedKeywordList.comics, 'BL')?.mode,
      KeywordMatchMode.word,
    );
  });

  testKeywordWidgets(
    'reason edit updates the actual loaded grid without showing hidden covers',
    (tester) async {
      await store.saveRule(BlockedKeywordList.comics, const KeywordRule('bl'));
      final comics = [
        Comic('black', '', 'one', null, null, '', 'test', null, null),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: appdata.settings,
              builder: (context, _) => CustomScrollView(
                slivers: [
                  if (matchComicKeyword(comics.single) != null)
                    SliverToBoxAdapter(
                      child: KeywordHiddenNotice(
                        count: 1,
                        comics: () => comics,
                        store: store,
                      ),
                    ),
                  SliverGridComics(comics: comics),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicTile), findsNothing);
      await tester.tap(find.text('View reasons'));
      await tester.pumpAndSettle();
      expect(find.byType(KeywordMatchPreview), findsOneWidget);
      expect(find.byType(ComicTile), findsNothing);
      await tester.tap(find.text('Edit rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<KeywordMatchMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole word').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(
        find.text('No comics in this list are hidden by keywords.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicTile), findsOneWidget);
      expect(find.byType(KeywordHiddenNotice), findsNothing);
    },
  );

  testKeywordWidgets(
    'narrow large text reduced motion editor remains scrollable and keyboard usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.8),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showKeywordRuleEditor(
                  context,
                  target: BlockedKeywordList.comics,
                  store: store,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyword-rule-word')),
        'BL',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        store.ruleFor(BlockedKeywordList.comics, 'BL')?.mode,
        KeywordMatchMode.word,
      );
    },
  );
}
