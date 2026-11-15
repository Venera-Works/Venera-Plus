import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/routing/pending_app_links.dart';

void main() {
  group('图库页码解析', () {
    for (final entry in [
      ('https://nhentai.net/g/123/7/', 'https://nhentai.net/g/123/', 7),
      (
        'https://NHENTAI.NET/g/123/1?from=share#image',
        'https://nhentai.net/g/123/?from=share#image',
        1,
      ),
      (
        'https://e-hentai.org/g/123/AbCd/12/',
        'https://e-hentai.org/g/123/AbCd/',
        12,
      ),
      (
        'https://EXHENTAI.ORG/g/123/456/2/',
        'https://exhentai.org/g/123/456/',
        2,
      ),
    ]) {
      test('提取正页码并保留漫画身份：${entry.$1}', () {
        final target = comicLinkTarget(Uri.parse(entry.$1));
        expect(target.uri, Uri.parse(entry.$2));
        expect(target.page, entry.$3);
      });
    }

    for (final url in [
      'https://nhentai.net/g/123/',
      'https://e-hentai.org/g/123/456/',
      'https://exhentai.org/g/123/token/?p=2',
      'https://other.test/g/123/7/',
      'https://other.test/comic/123/',
      'https://sub.nhentai.net/g/123/7/',
      'https://nhentai.net/comic/123/7/',
      'https://nhentai.net/g/123/7/extra/',
      'https://nhentai.net/g/123/7//',
      'https://nhentai.net/g/123/0/',
      'https://nhentai.net/g/123/-1/',
      'https://nhentai.net/g/123/page/',
      'https://nhentai.net/g/name/7/',
      'https://nhentai.net/g/0/7/',
      'https://nhentai.net/g//7/',
      'https://e-hentai.org/g/123//7/',
    ]) {
      test('未知结构或非法页码保持原始链接：$url', () {
        final uri = Uri.parse(url);
        final target = comicLinkTarget(uri);
        expect(target.uri, uri);
        expect(target.page, isNull);
      });
    }
  });

  test('启动前的链接按接收顺序处理，处理期间可暂停并恢复', () async {
    final first = Uri.parse('https://example.test/first');
    final second = Uri.parse('https://example.test/second');
    final firstFinished = Completer<bool>();
    final opened = <Uri>[];
    final pending = PendingAppLinks((uri) {
      opened.add(uri);
      return uri == first ? firstFinished.future : Future.value(true);
    }, (error, stack) => fail('$error\n$stack'));
    pending.add(first);
    pending.add(second);
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);

    pending.setReady(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first]);
    pending.setReady(false);
    firstFinished.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first]);

    pending.setReady(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second]);
  });

  test('导航失效时保留当前链接，下一次挂载后再处理', () async {
    final first = Uri.parse('https://example.test/first');
    final second = Uri.parse('https://example.test/second');
    var mounted = false;
    final opened = <Uri>[];
    final pending = PendingAppLinks((uri) async {
      if (!mounted) return false;
      opened.add(uri);
      return true;
    }, (error, stack) => fail('$error\n$stack'));

    pending.setReady(true);
    pending.add(first);
    pending.add(second);
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);

    mounted = true;
    pending.setReady(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second]);
    pending.setReady(true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, [first, second]);
  });

  test('单个链接处理异常不会阻塞后续链接', () async {
    final invalid = Uri.parse('https://example.test/invalid');
    final valid = Uri.parse('https://example.test/valid');
    final errors = <Object>[];
    final opened = <Uri>[];
    final pending = PendingAppLinks((uri) async {
      if (uri == invalid) throw const FormatException('无效链接');
      opened.add(uri);
      return true;
    }, (error, stack) => errors.add(error));

    pending.add(invalid);
    pending.add(valid);
    pending.setReady(true);
    await Future<void>.delayed(Duration.zero);
    expect(errors, [isA<FormatException>()]);
    expect(opened, [valid]);
  });

  for (final firstOpened in [false, true]) {
    test('异步处理期间的重新就绪通知不丢失：$firstOpened', () async {
      final first = Uri.parse('https://example.test/first');
      final second = Uri.parse('https://example.test/second');
      final opening = Completer<bool>();
      final attempts = <Uri>[];
      final pending = PendingAppLinks((uri) {
        attempts.add(uri);
        return attempts.length == 1 ? opening.future : Future.value(true);
      }, (error, stack) => fail('$error\n$stack'));
      pending.add(first);
      pending.add(second);
      pending.setReady(true);
      expect(attempts, [first]);

      pending.setReady(false);
      pending.setReady(true);
      opening.complete(firstOpened);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, firstOpened ? [first, second] : [first, first, second]);
    });
  }
}
