import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'appbar.dart';
import 'button.dart';
import 'select.dart';

void showToast({
  required String message,
  required BuildContext context,
  Widget? icon,
  Widget? trailing,
  int? seconds,
}) {
  var state = context.findAncestorStateOfType<OverlayWidgetState>();

  state?.showToast(
    message: message,
    icon: icon,
    trailing: trailing,
    seconds: seconds,
  );
}

class _ToastRecord {
  _ToastRecord({required this.message, this.icon, this.trailing});

  final String message;

  final Widget? icon;

  final Widget? trailing;

  final key = UniqueKey();

  Timer? timer;
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({required this.toasts});

  final List<_ToastRecord> toasts;

  @override
  Widget build(BuildContext context) {
    var bottom = App.isMobile
        ? MediaQuery.of(context).size.height * 0.25 +
              MediaQuery.of(context).viewPadding.bottom
        : 24 + MediaQuery.of(context).viewInsets.bottom;
    return Positioned(
      bottom: bottom,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < toasts.length; i++)
              Padding(
                key: toasts[i].key,
                padding: EdgeInsets.only(
                  bottom: i == toasts.length - 1 ? 0 : 8,
                ),
                child: _ToastOverlay(toast: toasts[i]),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToastOverlay extends StatelessWidget {
  const _ToastOverlay({required this.toast});

  final _ToastRecord toast;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      textStyle: ts.withColor(Theme.of(context).colorScheme.onInverseSurface),
      child: IconTheme(
        data: IconThemeData(
          color: Theme.of(context).colorScheme.onInverseSurface,
        ),
        child: IntrinsicWidth(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            constraints: BoxConstraints(maxWidth: context.width - 32),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (toast.icon != null) toast.icon!.paddingRight(8),
                Expanded(
                  child: Text(
                    toast.message,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (toast.trailing != null) toast.trailing!.paddingLeft(8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OverlayWidget extends StatefulWidget {
  const OverlayWidget(this.child, {super.key});

  final Widget child;

  @override
  State<OverlayWidget> createState() => OverlayWidgetState();
}

class OverlayWidgetState extends State<OverlayWidget> {
  final overlayKey = GlobalKey<OverlayState>();

  var entries = <OverlayEntry>[];

  OverlayEntry? _toastEntry;

  final _toasts = <_ToastRecord>[];

  void showToast({
    required String message,
    Widget? icon,
    Widget? trailing,
    int? seconds,
  }) {
    if (overlayKey.currentState == null) {
      return;
    }
    final toast = _ToastRecord(
      message: message,
      icon: icon,
      trailing: trailing,
    );
    toast.timer = Timer(
      Duration(seconds: seconds ?? 2),
      () => _removeToast(toast),
    );
    _toasts.add(toast);
    _ensureToastEntry();
    _toastEntry?.markNeedsBuild();
  }

  void _ensureToastEntry() {
    if (_toastEntry != null) {
      return;
    }
    _toastEntry = OverlayEntry(
      builder: (context) => _ToastStack(toasts: List.of(_toasts)),
    );
    overlayKey.currentState!.insert(_toastEntry!);
  }

  void _removeToast(_ToastRecord toast) {
    toast.timer?.cancel();
    if (!_toasts.remove(toast)) {
      return;
    }
    if (_toasts.isEmpty) {
      _toastEntry?.remove();
      _toastEntry = null;
    } else {
      _toastEntry?.markNeedsBuild();
    }
  }

  void addOverlay(OverlayEntry entry) {
    if (overlayKey.currentState != null) {
      overlayKey.currentState!.insert(entry);
      entries.add(entry);
    }
  }

  void remove(OverlayEntry entry) {
    if (entries.remove(entry)) {
      entry.remove();
    }
  }

  void removeAll() {
    for (var entry in entries) {
      entry.remove();
    }
    entries.clear();
    for (var toast in List.of(_toasts)) {
      _removeToast(toast);
    }
  }

  @override
  void dispose() {
    removeAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      key: overlayKey,
      initialEntries: [OverlayEntry(builder: (context) => widget.child)],
    );
  }
}

void showDialogMessage(BuildContext context, String title, String message) {
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(message).paddingHorizontal(16),
      actions: [
        FilledButton(
          style: actionButtonStyle,
          onPressed: context.pop,
          child: Text("OK".tl),
        ),
      ],
    ),
  );
}

Future<void> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  required void Function() onConfirm,
  String confirmText = "Confirm",
  Color? btnColor,
}) {
  return showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: title,
      content: Text(content).paddingHorizontal(16).paddingVertical(8),
      actions: [
        TextButton(onPressed: context.pop, child: Text('Cancel'.tl)),
        FilledButton(
          onPressed: () {
            context.pop();
            onConfirm();
          },
          style: actionButtonStyle.merge(
            FilledButton.styleFrom(
              backgroundColor: btnColor,
              foregroundColor: btnColor == context.colorScheme.error
                  ? context.colorScheme.onError
                  : null,
            ),
          ),
          child: Text(confirmText.tl),
        ),
      ],
    ),
  );
}

class LoadingDialogController {
  double? _progress;

  String? _message;

  void Function()? _closeDialog;

  VoidCallback? _refresh;

  bool closed = false;

  void close() {
    if (closed) {
      return;
    }
    closed = true;
    _closeDialog?.call();
  }

  void setProgress(double? value) {
    if (closed) {
      return;
    }
    _progress = value;
    _refresh?.call();
  }

  void setMessage(String message) {
    if (closed) {
      return;
    }
    _message = message;
    _refresh?.call();
  }
}

LoadingDialogController showLoadingDialog(
  BuildContext context, {
  void Function()? onCancel,
  bool barrierDismissible = true,
  bool allowCancel = true,
  String? message,
  String cancelButtonText = "Cancel",
  bool withProgress = false,
  bool closeOnCancel = true,
  WidgetBuilder? progressDetails,
}) {
  final controller = LoadingDialogController()
    .._message = message
    .._progress = withProgress ? 0 : null;
  final canPop = allowCancel && closeOnCancel;
  var cancelRequested = false;

  void requestCancel() {
    if (!allowCancel || controller.closed || cancelRequested) return;
    cancelRequested = true;
    if (closeOnCancel) {
      controller.close();
    } else {
      controller._refresh?.call();
    }
    onCancel?.call();
  }

  final loadingDialogRoute = _LoadingDialogRoute(
    context: context,
    barrierDismissible: allowCancel && barrierDismissible,
    allowUserPop: canPop,
    onBlockedPop: allowCancel ? requestCancel : null,
    builder: (context) {
      return PopScope<void>(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) requestCancel();
        },
        child: StatefulBuilder(
          builder: (context, setState) {
            controller._refresh = () => setState(() {});
            final canCancel = allowCancel && !cancelRequested;
            return ContentDialog(
              title: controller._message ?? 'Loading'.tl,
              dismissible: canCancel,
              onClose: requestCancel,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: controller._progress,
                    backgroundColor: context.colorScheme.surfaceContainer,
                  ),
                  if (progressDetails != null) ...[
                    const SizedBox(height: 16),
                    progressDetails(context),
                  ],
                  if (cancelRequested && !closeOnCancel) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Cancellation requested. Waiting for the current operation to finish safely.'
                          .tl,
                    ),
                  ],
                ],
              ).paddingHorizontal(16).paddingVertical(16),
              actions: [
                FilledButton(
                  onPressed: canCancel ? requestCancel : null,
                  child: Text(cancelButtonText.tl),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  final navigator = Navigator.of(context, rootNavigator: true);
  controller._closeDialog = () {
    if (loadingDialogRoute.isActive) navigator.removeRoute(loadingDialogRoute);
  };
  unawaited(
    navigator.push(loadingDialogRoute).then((_) {
      controller._refresh = null;
      requestCancel();
      controller.closed = true;
    }),
  );

  return controller;
}

class _LoadingDialogRoute extends DialogRoute<void> {
  _LoadingDialogRoute({
    required super.context,
    required super.builder,
    required super.barrierDismissible,
    required this.allowUserPop,
    this.onBlockedPop,
  });

  final bool allowUserPop;
  final VoidCallback? onBlockedPop;

  @override
  bool didPop(void result) {
    if (allowUserPop) return super.didPop(result);
    // 桌面端返回会直接调用 Navigator.pop，绕过 PopScope。
    final callback = onBlockedPop;
    if (callback != null) scheduleMicrotask(callback);
    return false;
  }
}

class ContentDialog extends StatelessWidget {
  const ContentDialog({
    super.key,
    this.title, // 如果不传 title 将不会展示
    required this.content,
    this.dismissible = true,
    this.onClose,
    this.actions = const [],
  });

  final String? title;

  final Widget content;

  final List<Widget> actions;

  final bool dismissible;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title != null
            ? Appbar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close'.tl,
                  onPressed: dismissible ? onClose ?? context.pop : null,
                ),
                title: Text(title!),
                backgroundColor: Colors.transparent,
              )
            : const SizedBox.shrink(),
        Flexible(
          child: SingleChildScrollView(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: this.content,
            ),
          ),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 16),
          Theme(
            data: theme.copyWith(
              filledButtonTheme: FilledButtonThemeData(
                style:
                    theme.filledButtonTheme.style?.merge(actionButtonStyle) ??
                    actionButtonStyle,
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style:
                    theme.outlinedButtonTheme.style?.merge(actionButtonStyle) ??
                    actionButtonStyle,
              ),
              textButtonTheme: TextButtonThemeData(
                style:
                    theme.textButtonTheme.style?.merge(actionButtonStyle) ??
                    actionButtonStyle,
              ),
            ),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: actions,
            ),
          ).paddingHorizontal(16),
        ],
        const SizedBox(height: 16),
      ],
    );
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: context.brightness == Brightness.dark
            ? BorderSide(color: context.colorScheme.outlineVariant)
            : BorderSide.none,
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: context.width < 400 ? 16 : 24,
        vertical: 24,
      ),
      constraints: BoxConstraints(
        minWidth: math.max(0.0, math.min(300.0, context.width - 32)),
        maxWidth: 520,
      ),
      elevation: 2,
      shadowColor: context.colorScheme.shadow,
      backgroundColor: context.colorScheme.surface,
      child: IntrinsicWidth(
        child: MediaQuery.removePadding(
          removeTop: true,
          removeBottom: true,
          context: context,
          child: content,
        ),
      ),
    );
  }
}

Future<void> showInputDialog({
  required BuildContext context,
  required String title,
  String? hintText,
  required FutureOr<Object?> Function(String) onConfirm,
  String? initialValue,
  String confirmText = "Confirm",
  String cancelText = "Cancel",
  RegExp? inputValidator,
  String? image,
  Uint8List? imageData,
}) {
  var controller = TextEditingController(text: initialValue);
  bool isLoading = false;
  String? error;

  return showDialog(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: title,
            content: Column(
              children: [
                if (image != null)
                  SizedBox(
                    height: 108,
                    child: Image.network(image, fit: BoxFit.none),
                  ).paddingBottom(8),
                if (image == null && imageData != null)
                  SizedBox(
                    height: 108,
                    child: Image.memory(imageData, fit: BoxFit.none),
                  ).paddingBottom(8),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: const OutlineInputBorder(),
                    errorText: error,
                  ),
                ).paddingHorizontal(12),
              ],
            ),
            actions: [
              TextButton(
                onPressed: isLoading ? null : context.pop,
                child: Text(cancelText.tl),
              ),
              FilledButton(
                style: actionButtonStyle,
                onPressed: isLoading
                    ? null
                    : () async {
                        if (inputValidator != null &&
                            !inputValidator.hasMatch(controller.text)) {
                          setState(() => error = "Invalid input".tl);
                          return;
                        }
                        var futureOr = onConfirm(controller.text);
                        Object? result;
                        if (futureOr is Future) {
                          setState(() => isLoading = true);
                          result = await futureOr;
                          setState(() => isLoading = false);
                        } else {
                          result = futureOr;
                        }
                        if (result == null) {
                          context.pop();
                        } else {
                          setState(() => error = result.toString());
                        }
                      },
                child: ButtonLoadingContent(
                  isLoading: isLoading,
                  child: Text(confirmText.tl),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

void showInfoDialog({
  required BuildContext context,
  required String title,
  required String content,
  String confirmText = "OK",
}) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: title,
        content: Text(content).paddingHorizontal(16).paddingVertical(8),
        actions: [
          FilledButton(
            style: actionButtonStyle,
            onPressed: context.pop,
            child: Text(confirmText.tl),
          ),
        ],
      );
    },
  );
}

Future<int?> showSelectDialog({
  required String title,
  required List<String> options,
  int? initialIndex,
}) async {
  int? current = initialIndex;

  await showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: title,
            content: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Select(
                      current: current == null ? "" : options[current!],
                      values: options,
                      selectedIndex: current,
                      minWidth: 156,
                      onTap: (i) {
                        setState(() {
                          current = i;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  current = null;
                  context.pop();
                },
                child: Text('Cancel'.tl),
              ),
              FilledButton(
                onPressed: current == null ? null : context.pop,
                child: Text('Confirm'.tl),
              ),
            ],
          );
        },
      );
    },
  );

  return current;
}
