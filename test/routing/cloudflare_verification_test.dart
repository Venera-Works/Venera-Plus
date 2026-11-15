import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/routing/cloudflare_verification.dart';

void main() {
  test('仅在页面可交互且正文非空时就绪', () {
    expect(
      isCloudflareDocumentReady('interactive', '', '<main>Ready</main>'),
      isTrue,
    );
    expect(
      isCloudflareDocumentReady('complete', '<title>Ready</title>', '正文'),
      isTrue,
    );
  });

  test('加载中、非字符串节点和空正文不会就绪', () {
    expect(
      isCloudflareDocumentReady('loading', '<title>Ready</title>', '正文'),
      isFalse,
    );
    expect(isCloudflareDocumentReady('complete', null, '正文'), isFalse);
    expect(
      isCloudflareDocumentReady('complete', '<title>Ready</title>', '  \n  '),
      isFalse,
    );
  });
}
