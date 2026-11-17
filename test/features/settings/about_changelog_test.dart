import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

void main() {
  testWidgets('启动更新开关联动显示渠道，并保存和保留所选渠道', (tester) async {
    final directory = Directory.systemTemp.createTempSync('about-updates-');
    final previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'],
    );
    String previousDataPath;
    try {
      previousDataPath = App.dataPath;
    } catch (_) {
      previousDataPath = Directory.systemTemp.path;
    }
    App.dataPath = directory.path;
    appdata.settings['language'] = 'zh-CN';
    await AppTranslation.init();
    addTearDown(() {
      appdata.settings.replaceAll(previousSettings);
      App.dataPath = previousDataPath;
      directory.deleteSync(recursive: true);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Future<void> flushWrites() async {
      var completed = false;
      final saved = appdata
          .saveData(false)
          .whenComplete(() => completed = true);
      // 同时推进真实文件 IO 与 Widget 测试的虚拟时钟。
      for (var i = 0; i < 500 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed, isTrue);
      await saved;
    }

    final channelSetting = find.byWidgetPredicate(
      (widget) =>
          widget is SelectSetting && widget.settingKey == 'appUpdateChannel',
    );
    for (final size in [const Size(360, 720), const Size(800, 720)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      appdata.settings['checkUpdateOnStart'] = false;
      appdata.settings['appUpdateChannel'] = 'stable';
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AboutSettings())),
      );
      await tester.pumpAndSettle();
      expect(channelSetting, findsNothing);

      await tester.tap(find.byType(Switch));
      await flushWrites();
      await tester.pumpAndSettle();
      expect(channelSetting, findsOneWidget);
      expect(
        tester.getTopLeft(channelSetting).dy,
        greaterThan(tester.getTopLeft(find.byType(SwitchSetting)).dy),
      );
      await tester.tap(
        find.descendant(of: channelSetting, matching: find.text('稳定版')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta 版').last);
      await flushWrites();
      await tester.pumpAndSettle();
      expect(appdata.settings['appUpdateChannel'], 'beta');
      final saved = jsonDecode(
        File('${directory.path}/appdata.json').readAsStringSync(),
      );
      expect(saved['settings']['appUpdateChannel'], 'beta');

      await tester.tap(find.byType(Switch));
      await flushWrites();
      await tester.pumpAndSettle();
      expect(channelSetting, findsNothing);
      expect(appdata.settings['appUpdateChannel'], 'beta');
      await tester.tap(find.byType(Switch));
      await flushWrites();
      await tester.pumpAndSettle();
      expect(channelSetting, findsOneWidget);
      expect(find.text('Beta 版'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  group('Changelog Markdown rendering', () {
    setUpAll(() async {
      await AppTranslation.init();
    });

    const changelogFixture =
        '# Venera 2.3.0\n\n'
        '### **核心特性**\n\n'
        '这是一段包含**加粗片段**与`package:venera_plus`行内代码的普通句子说明。\n\n'
        '- 一级功能列表项\n'
        '  - 二级嵌套列表项\n'
        '    这是二级列表换行后的续写文本内容\n'
        '    - 三级深层列表项\n\n'
        '硬换行前置行文本  \n'
        '硬换行后置行文本\n\n'
        '- 这是一个用于验证移动端极窄宽度屏幕下长列表文字自动换行而不发生截断并且缩进保持正确对齐的超长列表项内容\n';

    void setupMockChangelog(WidgetTester tester, String content) {
      final messenger = tester.binding.defaultBinaryMessenger;
      final previousHandler = messenger.allMessagesHandler;
      messenger.allMessagesHandler = (channel, handler, message) {
        if (channel == 'flutter/assets' && message != null) {
          final key = utf8.decode(
            message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          if (key == 'CHANGELOG.md' || key.endsWith('/CHANGELOG.md')) {
            return SynchronousFuture<ByteData>(
              ByteData.sublistView(Uint8List.fromList(utf8.encode(content))),
            );
          }
        }
        if (previousHandler != null) {
          return previousHandler(channel, handler, message);
        }
        if (handler != null) {
          return handler(message);
        }
        return messenger.delegate.send(channel, message);
      };
      rootBundle.evict('CHANGELOG.md');

      addTearDown(() {
        messenger.allMessagesHandler = previousHandler;
        rootBundle.evict('CHANGELOG.md');
      });
    }

    Finder findRichTextContaining(String token) {
      return find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(token),
      );
    }

    TextSpan? findTextSpan(
      InlineSpan? span,
      bool Function(TextSpan span) predicate,
    ) {
      if (span == null) return null;
      if (span is TextSpan) {
        if (predicate(span)) return span;
        if (span.children != null) {
          for (final child in span.children!) {
            final found = findTextSpan(child, predicate);
            if (found != null) return found;
          }
        }
      }
      return null;
    }

    testWidgets(
      'changelog renders rich markdown formatting without raw syntax, supports nested list indentation, and preserves vertical order',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        for (final richText in tester.widgetList<RichText>(
          find.byType(RichText),
        )) {
          final plain = richText.text.toPlainText();
          expect(plain, isNot(contains('**')));
          expect(plain, isNot(contains('`')));
        }

        final sentenceFinder = findRichTextContaining('加粗片段');
        expect(sentenceFinder, findsOneWidget);
        final sentenceSpan = tester.widget<RichText>(sentenceFinder).text;

        final boldSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('加粗片段') ?? false,
        );
        expect(boldSpan, isNotNull);
        expect(
          boldSpan!.style?.fontWeight,
          anyOf(FontWeight.bold, FontWeight.w700, FontWeight.w800),
        );

        final normalSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('这是一段包含') ?? false,
        );
        expect(normalSpan, isNotNull);
        expect(
          normalSpan!.style?.fontWeight,
          isNot(anyOf(FontWeight.bold, FontWeight.w700, FontWeight.w800)),
        );

        final codeSpan = findTextSpan(
          sentenceSpan,
          (s) => s.text?.contains('package:venera_plus') ?? false,
        );
        expect(codeSpan, isNotNull);
        expect(codeSpan!.style?.fontFamily, 'monospace');

        final level2Finder = findRichTextContaining('二级嵌套列表项');
        expect(level2Finder, findsOneWidget);
        final level2Text = tester
            .widget<RichText>(level2Finder)
            .text
            .toPlainText();
        expect(level2Text, contains('这是二级列表换行后的续写文本内容'));

        final pLevel1 = tester.getTopLeft(findRichTextContaining('一级功能列表项'));
        final pLevel2 = tester.getTopLeft(level2Finder);
        final pLevel3 = tester.getTopLeft(findRichTextContaining('三级深层列表项'));

        expect(pLevel2.dx, greaterThan(pLevel1.dx));
        expect(pLevel3.dx, greaterThan(pLevel2.dx));

        expect(pLevel2.dy, greaterThan(pLevel1.dy));
        expect(pLevel3.dy, greaterThan(pLevel2.dy));

        final breakParagraph = tester.renderObject<RenderParagraph>(
          findRichTextContaining('硬换行前置行文本'),
        );
        final breakPlain = breakParagraph.text.toPlainText();
        final start1 = breakPlain.indexOf('硬换行前置行文本');
        final boxes1 = breakParagraph.getBoxesForSelection(
          TextSelection(
            baseOffset: start1,
            extentOffset: start1 + '硬换行前置行文本'.length,
          ),
        );
        final start2 = breakPlain.indexOf('硬换行后置行文本');
        final boxes2 = breakParagraph.getBoxesForSelection(
          TextSelection(
            baseOffset: start2,
            extentOffset: start2 + '硬换行后置行文本'.length,
          ),
        );
        expect(boxes1, isNotEmpty);
        expect(boxes2, isNotEmpty);
        expect(boxes2.first.top, greaterThan(boxes1.first.top));
      },
    );

    testWidgets('changelog lazily renders versions while scrolling', (
      tester,
    ) async {
      final changelog = StringBuffer('# 更新日志\n\n');
      for (var version = 60; version >= 1; version--) {
        changelog.writeln('## v$version.0.0\n');
        for (var item = 0; item < 6; item++) {
          changelog.writeln('- **功能 $item**：这是该版本的更新说明。');
        }
        changelog.writeln();
      }
      setupMockChangelog(tester, changelog.toString());
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
      await tester.pumpAndSettle();

      expect(findRichTextContaining('v60.0.0'), findsOneWidget);
      expect(findRichTextContaining('v1.0.0'), findsNothing);
      expect(find.byType(RichText).evaluate().length, lessThan(80));

      await tester.scrollUntilVisible(
        findRichTextContaining('v1.0.0'),
        800,
        scrollable: find.byType(Scrollable),
        maxScrolls: 100,
      );
      await tester.pumpAndSettle();

      expect(findRichTextContaining('v1.0.0'), findsOneWidget);
      expect(findRichTextContaining('v60.0.0'), findsNothing);
      expect(find.byType(RichText).evaluate().length, lessThan(80));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'changelog adapts inline code styling to light and dark theme',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        final lightTheme = ThemeData.light();
        await tester.pumpWidget(
          MaterialApp(theme: lightTheme, home: const ChangelogPage()),
        );
        await tester.pumpAndSettle();

        final lightFinder = findRichTextContaining('package:venera_plus');
        expect(lightFinder, findsOneWidget);
        final lightSpan = findTextSpan(
          tester.widget<RichText>(lightFinder).text,
          (s) => s.text?.contains('package:venera_plus') ?? false,
        );
        expect(lightSpan, isNotNull);
        expect(lightSpan!.style?.fontFamily, 'monospace');
        expect(
          lightSpan.style?.color,
          lightTheme.colorScheme.onSecondaryContainer,
        );
        expect(
          lightSpan.style?.backgroundColor,
          lightTheme.colorScheme.secondaryContainer,
        );

        final darkTheme = ThemeData.dark();
        await tester.pumpWidget(
          MaterialApp(theme: darkTheme, home: const ChangelogPage()),
        );
        await tester.pumpAndSettle();

        final darkFinder = findRichTextContaining('package:venera_plus');
        expect(darkFinder, findsOneWidget);
        final darkSpan = findTextSpan(
          tester.widget<RichText>(darkFinder).text,
          (s) => s.text?.contains('package:venera_plus') ?? false,
        );
        expect(darkSpan, isNotNull);
        expect(darkSpan!.style?.fontFamily, 'monospace');
        expect(
          darkSpan.style?.color,
          darkTheme.colorScheme.onSecondaryContainer,
        );
        expect(
          darkSpan.style?.backgroundColor,
          darkTheme.colorScheme.secondaryContainer,
        );
        expect(
          darkSpan.style?.color,
          isNot(lightTheme.colorScheme.onSecondaryContainer),
        );
      },
    );

    testWidgets(
      'changelog wraps long text on narrow screens without overflow or broken indentation',
      (tester) async {
        setupMockChangelog(tester, changelogFixture);
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        final longTextFinder = findRichTextContaining('超长列表项内容');
        expect(longTextFinder, findsOneWidget);

        final rect = tester.getRect(longTextFinder);
        expect(rect.left, greaterThanOrEqualTo(0.0));
        expect(rect.right, lessThanOrEqualTo(320.0));
        expect(rect.height, greaterThan(25.0));

        final p1 = tester.getTopLeft(findRichTextContaining('一级功能列表项'));
        final p2 = tester.getTopLeft(findRichTextContaining('二级嵌套列表项'));
        expect(p2.dx, greaterThan(p1.dx));
      },
    );

    testWidgets(
      'changelog supports full page selection and copy through SelectionArea and clipboard',
      (tester) async {
        setupMockChangelog(
          tester,
          '$changelogFixture\n## Venera 2.2.0\n\n历史版本的说明。\n',
        );
        String? copiedText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (methodCall) async {
            if (methodCall.method == 'Clipboard.setData') {
              copiedText =
                  (methodCall.arguments as Map<dynamic, dynamic>?)?['text']
                      as String?;
              return null;
            }
            if (methodCall.method == 'Clipboard.getData') {
              return {'text': copiedText};
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
        await tester.pumpAndSettle();

        final selectionAreaFinder = find.byType(SelectionArea);
        expect(selectionAreaFinder, findsOneWidget);

        final selectionState = tester.state<SelectionAreaState>(
          selectionAreaFinder,
        );
        selectionState.selectableRegion.selectAll(
          SelectionChangedCause.keyboard,
        );
        await tester.pump();

        final copyButton = selectionState
            .selectableRegion
            .contextMenuButtonItems
            .firstWhere((item) => item.type == ContextMenuButtonType.copy);
        copyButton.onPressed!();
        await tester.pump();

        expect(copiedText, isNotNull);
        expect(copiedText, contains('Venera 2.3.0'));
        expect(copiedText, contains('核心特性'));
        expect(copiedText, contains('一级功能列表项'));
        expect(copiedText, contains('三级深层列表项'));
        expect(copiedText, contains('package:venera_plus'));
        expect(copiedText, contains('Venera 2.2.0'));
        expect(copiedText, contains('历史版本的说明。'));
        expect(copiedText, isNot(contains('**')));
        expect(copiedText, isNot(contains('`')));
      },
    );
  });
}
