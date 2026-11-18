import 'package:flutter/material.dart';

import 'app_page_route.dart';

void Function(BuildContext context, String message)? _showMessageHandler;

void registerShowMessageHandler(
  void Function(BuildContext context, String message) handler,
) {
  _showMessageHandler = handler;
}

extension Navigation on BuildContext {
  void pop<T>([T? result]) {
    if (mounted) {
      Navigator.of(this).pop(result);
    }
  }

  bool canPop() {
    return Navigator.of(this).canPop();
  }

  Future<T?> to<T>(
    Widget Function() builder, {
    bool animatePreviousPage = true,
  }) {
    return Navigator.of(this).push<T>(
      AppPageRoute(
        builder: (context) => builder(),
        animatePreviousPage: animatePreviousPage,
      ),
    );
  }

  Future<void> toReplacement<T>(Widget Function() builder) {
    return Navigator.of(
      this,
    ).pushReplacement(AppPageRoute(builder: (context) => builder()));
  }

  double get width => MediaQuery.sizeOf(this).width;

  double get height => MediaQuery.sizeOf(this).height;

  EdgeInsets get padding => MediaQuery.paddingOf(this);

  EdgeInsets get viewInsets => MediaQuery.viewInsetsOf(this);

  ColorScheme get colorScheme => Theme.of(this).colorScheme;

  Brightness get brightness => Theme.of(this).brightness;

  bool get isDarkMode => brightness == Brightness.dark;

  void showMessage({required String message}) {
    _showMessageHandler?.call(this, message);
  }

  Color useBackgroundColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 100 : 800]!;
  }

  Color useTextColor(MaterialColor color) {
    return color[brightness == Brightness.light ? 800 : 100]!;
  }
}
