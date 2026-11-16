import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/button.dart';

void main() {
  testWidgets('大字体下加载按钮的文字占位和进度指示器不裁切', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                style: actionButtonStyle,
                onPressed: null,
                child: const ButtonLoadingContent(
                  isLoading: true,
                  child: Text('保存并测试连接'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final buttonRect = tester.getRect(find.byType(FilledButton));
    for (final finder in [
      find.text('保存并测试连接'),
      find.byType(CircularProgressIndicator),
    ]) {
      final contentRect = tester.getRect(finder);
      expect(contentRect.left, greaterThanOrEqualTo(buttonRect.left));
      expect(contentRect.right, lessThanOrEqualTo(buttonRect.right));
      expect(contentRect.top, greaterThanOrEqualTo(buttonRect.top));
      expect(contentRect.bottom, lessThanOrEqualTo(buttonRect.bottom));
    }
    expect(tester.takeException(), isNull);
  });
}
