import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/context.dart';

const _codeFontSize = 14.0;
const _codeLineHeightMultiplier = 1.5;
const _codeFontFamily = 'Consolas';
const _codeFontFallback = ['Courier New', 'Roboto Mono', 'monospace'];
const _codeHorizontalPadding = 8.0;
const _codeVerticalPadding = 8.0;
const _minGutterWidth = 40.0;
const _gutterHorizontalPadding = 8.0;
const _maxHighlightedLineLength = 2000;
const _maxCachedLinePainters = 160;

const _baseCodeStyle = TextStyle(
  fontSize: _codeFontSize,
  height: _codeLineHeightMultiplier,
  fontFamily: _codeFontFamily,
  fontFamilyFallback: _codeFontFallback,
);

const _codeStrutStyle = StrutStyle(
  fontSize: _codeFontSize,
  height: _codeLineHeightMultiplier,
  fontFamily: _codeFontFamily,
  fontFamilyFallback: _codeFontFallback,
  forceStrutHeight: true,
);

const _codeTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
);

class CodeEditor extends StatefulWidget {
  const CodeEditor({super.key, this.initialValue, this.onChanged});

  final String? initialValue;

  final void Function(String value)? onChanged;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late final _PlainCodeEditingController _controller;
  late final FocusNode _focusNode;
  final _horizontalScrollController = ScrollController();
  final _verticalScrollController = ScrollController();
  final _paintVersion = _CodePaintNotifier();
  late final Listenable _gutterRepaint;
  late final Listenable _codeRepaint;
  final _linePainterCache = _LinePainterCache(_maxCachedLinePainters);

  late _CodeDocumentIndex _document;
  TextRange _lastComposing = TextRange.empty;
  TextScaler? _measuredTextScaler;
  double _measuredLineHeight = _codeFontSize * _codeLineHeightMultiplier;
  double _measuredMaxLineWidth = 0;
  double _measuredGutterWidth = _minGutterWidth;
  int _measuredWidthLineDigits = 0;
  int _measuredWidthMaxAscii = -1;
  int _measuredWidthMaxWeighted = -1;
  String? _measuredWidthText;

  @override
  void initState() {
    super.initState();
    final initialText = widget.initialValue ?? '';
    _controller = _PlainCodeEditingController(text: initialText);
    _document = _CodeDocumentIndex.parse(initialText);
    _lastComposing = _controller.value.composing;
    _controller.addListener(_onControllerChanged);

    _gutterRepaint = Listenable.merge([
      _verticalScrollController,
      _paintVersion,
    ]);
    _codeRepaint = Listenable.merge([
      _verticalScrollController,
      _horizontalScrollController,
      _paintVersion,
    ]);

    _focusNode = FocusNode()
      ..onKeyEvent = (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          if (event is KeyDownEvent) {
            handleTab();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      };
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _focusNode.dispose();
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    _paintVersion.dispose();
    _linePainterCache.clear();
    super.dispose();
  }

  void _onControllerChanged() {
    final text = _controller.text;
    final composing = _controller.value.composing;
    final textChanged = text != _document.text;
    final composingChanged = composing != _lastComposing;
    if (!textChanged && !composingChanged) return;

    _lastComposing = composing;
    _linePainterCache.clear();

    if (textChanged) {
      final previous = _document;
      _document = _CodeDocumentIndex.parse(text);
      _paintVersion.bump();

      final scaler = _measuredTextScaler;
      if (scaler != null) {
        final previousGutter = _measuredGutterWidth;
        final previousWidth = _measuredMaxLineWidth;
        _updateMetrics(scaler, forceLineWidth: _needsWidthRemeasure(previous));
        if (_measuredGutterWidth != previousGutter ||
            _measuredMaxLineWidth != previousWidth) {
          if (mounted) setState(() {});
        }
      }
      return;
    }

    _paintVersion.bump();
  }

  bool _needsWidthRemeasure(_CodeDocumentIndex previous) {
    return _document.maxAsciiLength != previous.maxAsciiLength ||
        _document.maxWeightedLength != previous.maxWeightedLength ||
        _document.widestAsciiLine != previous.widestAsciiLine ||
        _document.widestWeightedLine != previous.widestWeightedLine;
  }

  void _updateMetrics(TextScaler textScaler, {bool forceLineWidth = false}) {
    final scalerChanged = _measuredTextScaler != textScaler;
    if (scalerChanged) {
      _measuredTextScaler = textScaler;
      _measuredLineHeight = _measureLineHeight(textScaler);
      _linePainterCache.clear();
    }

    final digits = _document.lineCount.toString().length;
    if (scalerChanged || digits != _measuredWidthLineDigits) {
      _measuredWidthLineDigits = digits;
      _measuredGutterWidth = _measureGutterWidth(digits, textScaler);
    }

    final widthChanged =
        scalerChanged ||
        forceLineWidth ||
        _measuredWidthText == null ||
        _document.maxAsciiLength != _measuredWidthMaxAscii ||
        _document.maxWeightedLength != _measuredWidthMaxWeighted;
    if (widthChanged) {
      _measuredWidthText = _document.text;
      _measuredWidthMaxAscii = _document.maxAsciiLength;
      _measuredWidthMaxWeighted = _document.maxWeightedLength;
      _measuredMaxLineWidth = _measureMaxLineWidth(_document, textScaler);
    }
  }

  double _measureLineHeight(TextScaler textScaler) {
    final painter = TextPainter(
      text: const TextSpan(text: '0\n0', style: _baseCodeStyle),
      textDirection: TextDirection.ltr,
      strutStyle: _codeStrutStyle,
      textHeightBehavior: _codeTextHeightBehavior,
      textScaler: textScaler,
    )..layout();
    try {
      final secondLineY = painter
          .getOffsetForCaret(const TextPosition(offset: 2), Rect.zero)
          .dy;
      if (secondLineY > 0) return secondLineY;
      return painter.preferredLineHeight;
    } finally {
      painter.dispose();
    }
  }

  double _measureGutterWidth(int digits, TextScaler textScaler) {
    final sample = '9' * math.max(digits, 2);
    final painter = TextPainter(
      text: TextSpan(
        text: sample,
        style: const TextStyle(
          fontSize: 13,
          height: 1.0,
          fontFamily: _codeFontFamily,
          fontFamilyFallback: _codeFontFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    try {
      return math.max(
        _minGutterWidth,
        painter.width.ceilToDouble() + _gutterHorizontalPadding * 2,
      );
    } finally {
      painter.dispose();
    }
  }

  double _measureMaxLineWidth(
    _CodeDocumentIndex document,
    TextScaler textScaler,
  ) {
    double measureLine(int lineIndex) {
      final line = document.visibleLineText(lineIndex);
      if (line.isEmpty) return 0;
      final painter = TextPainter(
        text: TextSpan(text: line, style: _baseCodeStyle),
        textDirection: TextDirection.ltr,
        strutStyle: _codeStrutStyle,
        textHeightBehavior: _codeTextHeightBehavior,
        textScaler: textScaler,
      )..layout();
      try {
        return painter.width;
      } finally {
        painter.dispose();
      }
    }

    var maxWidth = measureLine(document.widestWeightedLine);
    if (document.widestAsciiLine != document.widestWeightedLine) {
      maxWidth = math.max(maxWidth, measureLine(document.widestAsciiLine));
    }
    // 预留横向安全余量，避免包含宽字符或制表符的行在 TextField 内发生软换行。
    return maxWidth.ceilToDouble() + 64.0;
  }

  void handleTab() {
    final selection = _controller.selection;
    final start = selection.start;
    final end = selection.end;
    if (start < 0 || end < 0) return;
    final text = _controller.text;
    final updated = '${text.substring(0, start)}    ${text.substring(end)}';
    _controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + 4),
    );
    widget.onChanged?.call(updated);
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    _updateMetrics(textScaler);
    final palette = context.isDarkMode ? _CodePalette.dark : _CodePalette.light;
    final colorScheme = context.colorScheme;
    final lineHeight = _measuredLineHeight;
    final gutterWidth = _measuredGutterWidth;

    return DefaultTextHeightBehavior(
      textHeightBehavior: _codeTextHeightBehavior,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _codeVerticalPadding),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewportWidth = math.max(
              0.0,
              constraints.maxWidth - gutterWidth,
            );
            final innerWidth = math.max(
              math.max(0.0, viewportWidth - _codeHorizontalPadding * 2),
              _measuredMaxLineWidth,
            );

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: gutterWidth,
                  child: RepaintBoundary(
                    child: ClipRect(
                      child: CustomPaint(
                        painter: _LineNumberPainter(
                          repaint: _gutterRepaint,
                          verticalController: _verticalScrollController,
                          documentProvider: () => _document,
                          lineHeight: lineHeight,
                          textScaler: textScaler,
                          textColor: colorScheme.outline,
                          dividerColor: colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    controller: _verticalScrollController,
                    notificationPredicate: (notif) =>
                        notif.metrics.axis == Axis.vertical,
                    child: Scrollbar(
                      thumbVisibility: true,
                      controller: _horizontalScrollController,
                      notificationPredicate: (notif) =>
                          notif.metrics.axis == Axis.horizontal,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: IgnorePointer(
                              child: RepaintBoundary(
                                child: ClipRect(
                                  child: CustomPaint(
                                    painter: _HighlightedCodePainter(
                                      repaint: _codeRepaint,
                                      verticalController:
                                          _verticalScrollController,
                                      horizontalController:
                                          _horizontalScrollController,
                                      controller: _controller,
                                      documentProvider: () => _document,
                                      cache: _linePainterCache,
                                      palette: palette,
                                      lineHeight: lineHeight,
                                      textScaler: textScaler,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ScrollConfiguration(
                            behavior: const _CustomScrollBehavior(),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              controller: _horizontalScrollController,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: _codeHorizontalPadding,
                                ),
                                child: SizedBox(
                                  width: innerWidth,
                                  height: constraints.maxHeight,
                                  child: TextField(
                                    controller: _controller,
                                    focusNode: _focusNode,
                                    scrollController: _verticalScrollController,
                                    expands: true,
                                    maxLines: null,
                                    minLines: null,
                                    keyboardType: TextInputType.multiline,
                                    textAlignVertical: TextAlignVertical.top,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    smartDashesType: SmartDashesType.disabled,
                                    smartQuotesType: SmartQuotesType.disabled,
                                    cursorHeight: lineHeight,
                                    cursorColor: colorScheme.primary,
                                    style: _baseCodeStyle.copyWith(
                                      color: Colors.transparent,
                                    ),
                                    strutStyle: _codeStrutStyle,
                                    decoration: null,
                                    onChanged: (value) {
                                      widget.onChanged?.call(value);
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CodePaintNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _CustomScrollBehavior extends MaterialScrollBehavior {
  const _CustomScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _PlainCodeEditingController extends TextEditingController {
  _PlainCodeEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 保持 TextField 内部仅为单段透明纯文本，将语法着色延迟到视口绘制层。
    return TextSpan(style: style, text: text);
  }
}

class _LineNumberPainter extends CustomPainter {
  _LineNumberPainter({
    required super.repaint,
    required this.verticalController,
    required this.documentProvider,
    required this.lineHeight,
    required this.textScaler,
    required this.textColor,
    required this.dividerColor,
  });

  final ScrollController verticalController;
  final _CodeDocumentIndex Function() documentProvider;
  final double lineHeight;
  final TextScaler textScaler;
  final Color textColor;
  final Color dividerColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || lineHeight <= 0) return;

    final dividerPaint = Paint()
      ..color = dividerColor
      ..strokeWidth = 0.6;
    canvas.drawLine(
      Offset(size.width - 0.3, 0),
      Offset(size.width - 0.3, size.height),
      dividerPaint,
    );

    final lineCount = documentProvider().lineCount;
    final scrollOffset = verticalController.hasClients
        ? verticalController.offset
        : 0.0;
    final firstLine = ((scrollOffset / lineHeight).floor() - 1).clamp(
      0,
      lineCount - 1,
    );
    final lastLine = (((scrollOffset + size.height) / lineHeight).ceil() + 1)
        .clamp(0, lineCount - 1);

    final style = TextStyle(
      color: textColor,
      fontSize: 13,
      height: 1.0,
      fontFamily: _codeFontFamily,
      fontFamilyFallback: _codeFontFallback,
    );
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    try {
      for (var line = firstLine; line <= lastLine; line++) {
        painter.text = TextSpan(text: '${line + 1}', style: style);
        painter.layout();
        final dx = math.max(
          0.0,
          size.width - _gutterHorizontalPadding - painter.width,
        );
        final dy =
            line * lineHeight -
            scrollOffset +
            (lineHeight - painter.height) / 2;
        painter.paint(canvas, Offset(dx, dy));
      }
    } finally {
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _LineNumberPainter oldDelegate) {
    return lineHeight != oldDelegate.lineHeight ||
        textScaler != oldDelegate.textScaler ||
        textColor != oldDelegate.textColor ||
        dividerColor != oldDelegate.dividerColor;
  }
}

class _HighlightedCodePainter extends CustomPainter {
  _HighlightedCodePainter({
    required super.repaint,
    required this.verticalController,
    required this.horizontalController,
    required this.controller,
    required this.documentProvider,
    required this.cache,
    required this.palette,
    required this.lineHeight,
    required this.textScaler,
  });

  final ScrollController verticalController;
  final ScrollController horizontalController;
  final TextEditingController controller;
  final _CodeDocumentIndex Function() documentProvider;
  final _LinePainterCache cache;
  final _CodePalette palette;
  final double lineHeight;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || lineHeight <= 0) return;

    final document = documentProvider();
    final lineCount = document.lineCount;
    final scrollY = verticalController.hasClients
        ? verticalController.offset
        : 0.0;
    final scrollX = horizontalController.hasClients
        ? horizontalController.offset
        : 0.0;
    final firstLine = ((scrollY / lineHeight).floor() - 1).clamp(
      0,
      lineCount - 1,
    );
    final lastLine = (((scrollY + size.height) / lineHeight).ceil() + 1).clamp(
      0,
      lineCount - 1,
    );

    final composing = controller.value.composing;
    final hasComposing = composing.isValid && !composing.isCollapsed;
    final dx = _codeHorizontalPadding - scrollX;

    cache.ensureContext(
      text: document.text,
      palette: palette,
      textScaler: textScaler,
      composing: composing,
    );

    for (var line = firstLine; line <= lastLine; line++) {
      final dy = line * lineHeight - scrollY;
      final lineStart = document.lineStart(line);
      final visibleEnd = document.visibleLineEnd(line);
      if (visibleEnd <= lineStart) continue;

      final painter = cache.getOrCreate(line, () {
        final lineText = document.text.substring(lineStart, visibleEnd);
        final lineComposing = hasComposing
            ? _lineLocalComposing(composing, lineStart, visibleEnd)
            : TextRange.empty;
        final span = _buildHighlightedLineSpan(
          lineText,
          entryState: document.lineState(line),
          isFirstLine: line == 0,
          palette: palette,
          composing: lineComposing,
        );
        return TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          strutStyle: _codeStrutStyle,
          textHeightBehavior: _codeTextHeightBehavior,
          textScaler: textScaler,
        )..layout();
      });
      painter.paint(canvas, Offset(dx, dy));
    }
  }

  TextRange _lineLocalComposing(
    TextRange composing,
    int lineStart,
    int visibleEnd,
  ) {
    final start = math.max(composing.start, lineStart);
    final end = math.min(composing.end, visibleEnd);
    if (start >= end) return TextRange.empty;
    return TextRange(start: start - lineStart, end: end - lineStart);
  }

  @override
  bool shouldRepaint(covariant _HighlightedCodePainter oldDelegate) {
    return palette != oldDelegate.palette ||
        lineHeight != oldDelegate.lineHeight ||
        textScaler != oldDelegate.textScaler;
  }
}

class _LinePainterCache {
  _LinePainterCache(this.capacity);

  final int capacity;
  final _entries = <int, TextPainter>{};
  String? _text;
  _CodePalette? _palette;
  TextScaler? _textScaler;
  TextRange _composing = TextRange.empty;

  void ensureContext({
    required String text,
    required _CodePalette palette,
    required TextScaler textScaler,
    required TextRange composing,
  }) {
    if (identical(_text, text) &&
        _palette == palette &&
        _textScaler == textScaler &&
        _composing == composing) {
      return;
    }
    clear();
    _text = text;
    _palette = palette;
    _textScaler = textScaler;
    _composing = composing;
  }

  TextPainter getOrCreate(int line, TextPainter Function() create) {
    final existing = _entries.remove(line);
    if (existing != null) {
      _entries[line] = existing;
      return existing;
    }
    final created = create();
    _entries[line] = created;
    if (_entries.length > capacity) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey)?.dispose();
    }
    return created;
  }

  void clear() {
    for (final painter in _entries.values) {
      painter.dispose();
    }
    _entries.clear();
  }
}

class _LexState {
  static const int normal = 0;
  static const int blockComment = 1;
  static const int template = 2;
}

class _CodeDocumentIndex {
  _CodeDocumentIndex._({
    required this.text,
    required this.lineStarts,
    required this.lineStates,
    required this.widestAsciiLine,
    required this.widestWeightedLine,
    required this.maxAsciiLength,
    required this.maxWeightedLength,
  });

  final String text;
  final List<int> lineStarts;
  final Uint8List lineStates;
  final int widestAsciiLine;
  final int widestWeightedLine;
  final int maxAsciiLength;
  final int maxWeightedLength;

  int get lineCount => lineStarts.length;

  int lineStart(int line) => lineStarts[line];

  int lineEnd(int line) =>
      line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : text.length;

  int visibleLineEnd(int line) {
    final end = lineEnd(line);
    final start = lineStarts[line];
    if (end > start && text.codeUnitAt(end - 1) == 0x0D) {
      return end - 1;
    }
    return end;
  }

  String visibleLineText(int line) =>
      text.substring(lineStarts[line], visibleLineEnd(line));

  int lineState(int line) => lineStates[line];

  static _CodeDocumentIndex parse(String text) {
    final starts = <int>[0];
    final states = <int>[_LexState.normal];

    var state = _LexState.normal;
    var quote = 0;
    var inLineComment = false;
    var lineIndex = 0;
    var asciiLen = 0;
    var weightedLen = 0;
    var widestAsciiLine = 0;
    var widestWeightedLine = 0;
    var maxAsciiLength = 0;
    var maxWeightedLength = 0;

    final length = text.length;
    var i = 0;
    while (i < length) {
      final ch = text.codeUnitAt(i);
      if (ch == 0x0A) {
        if (asciiLen > maxAsciiLength) {
          maxAsciiLength = asciiLen;
          widestAsciiLine = lineIndex;
        }
        if (weightedLen > maxWeightedLength) {
          maxWeightedLength = weightedLen;
          widestWeightedLine = lineIndex;
        }
        lineIndex++;
        asciiLen = 0;
        weightedLen = 0;
        inLineComment = false;
        quote = 0;
        starts.add(i + 1);
        states.add(state);
        i++;
        continue;
      }

      if (ch != 0x0D) {
        asciiLen++;
        if (ch == 0x09) {
          weightedLen += 4;
        } else if (ch > 0x7F) {
          weightedLen += 2;
        } else {
          weightedLen++;
        }
      }

      if (inLineComment) {
        i++;
        continue;
      }

      if (state == _LexState.blockComment) {
        if (ch == 0x2A && i + 1 < length && text.codeUnitAt(i + 1) == 0x2F) {
          state = _LexState.normal;
          asciiLen++;
          weightedLen++;
          i += 2;
        } else {
          i++;
        }
        continue;
      }

      if (state == _LexState.template) {
        if (ch == 0x5C && i + 1 < length && text.codeUnitAt(i + 1) != 0x0A) {
          final next = text.codeUnitAt(i + 1);
          if (next != 0x0D) {
            asciiLen++;
            weightedLen += next == 0x09 ? 4 : (next > 0x7F ? 2 : 1);
          }
          i += 2;
        } else if (ch == 0x60) {
          state = _LexState.normal;
          i++;
        } else {
          i++;
        }
        continue;
      }

      if (quote != 0) {
        if (ch == 0x5C && i + 1 < length && text.codeUnitAt(i + 1) != 0x0A) {
          final next = text.codeUnitAt(i + 1);
          if (next != 0x0D) {
            asciiLen++;
            weightedLen += next == 0x09 ? 4 : (next > 0x7F ? 2 : 1);
          }
          i += 2;
        } else if (ch == quote) {
          quote = 0;
          i++;
        } else {
          i++;
        }
        continue;
      }

      if (ch == 0x2F && i + 1 < length) {
        final next = text.codeUnitAt(i + 1);
        if (next == 0x2F) {
          inLineComment = true;
          asciiLen++;
          weightedLen++;
          i += 2;
          continue;
        }
        if (next == 0x2A) {
          state = _LexState.blockComment;
          asciiLen++;
          weightedLen++;
          i += 2;
          continue;
        }
      }

      if (ch == 0x22 || ch == 0x27) {
        quote = ch;
        i++;
        continue;
      }

      if (ch == 0x60) {
        state = _LexState.template;
        i++;
        continue;
      }

      i++;
    }

    if (asciiLen > maxAsciiLength) {
      maxAsciiLength = asciiLen;
      widestAsciiLine = lineIndex;
    }
    if (weightedLen > maxWeightedLength) {
      maxWeightedLength = weightedLen;
      widestWeightedLine = lineIndex;
    }

    return _CodeDocumentIndex._(
      text: text,
      lineStarts: starts,
      lineStates: Uint8List.fromList(states),
      widestAsciiLine: widestAsciiLine,
      widestWeightedLine: widestWeightedLine,
      maxAsciiLength: maxAsciiLength,
      maxWeightedLength: maxWeightedLength,
    );
  }
}

class _CodePalette {
  const _CodePalette({
    required this.plain,
    required this.comment,
    required this.keywordControl,
    required this.keywordDeclaration,
    required this.constant,
    required this.number,
    required this.string,
    required this.interpolation,
    required this.operator,
    required this.bracket,
  });

  final TextStyle plain;
  final TextStyle comment;
  final TextStyle keywordControl;
  final TextStyle keywordDeclaration;
  final TextStyle constant;
  final TextStyle number;
  final TextStyle string;
  final TextStyle interpolation;
  final TextStyle operator;
  final TextStyle bracket;

  static const light = _CodePalette(
    plain: TextStyle(color: Color(0xFF1F2328)),
    comment: TextStyle(color: Color(0xFF008000)),
    keywordControl: TextStyle(color: Color(0xFFAF00DB)),
    keywordDeclaration: TextStyle(color: Color(0xFF0000FF)),
    constant: TextStyle(color: Color(0xFF0000FF)),
    number: TextStyle(color: Color(0xFF098658)),
    string: TextStyle(color: Color(0xFFA31515)),
    interpolation: TextStyle(color: Color(0xFF001080)),
    operator: TextStyle(color: Color(0xFF383A42)),
    bracket: TextStyle(color: Color(0xFF0431FA)),
  );

  static const dark = _CodePalette(
    plain: TextStyle(color: Color(0xFFD4D4D4)),
    comment: TextStyle(color: Color(0xFF6A9955)),
    keywordControl: TextStyle(color: Color(0xFFC586C0)),
    keywordDeclaration: TextStyle(color: Color(0xFF569CD6)),
    constant: TextStyle(color: Color(0xFF569CD6)),
    number: TextStyle(color: Color(0xFFB5CEA8)),
    string: TextStyle(color: Color(0xFFCE9178)),
    interpolation: TextStyle(color: Color(0xFF9CDCFE)),
    operator: TextStyle(color: Color(0xFFD4D4D4)),
    bracket: TextStyle(color: Color(0xFFFFD700)),
  );
}

const _controlKeywords = {
  'if',
  'else',
  'for',
  'while',
  'do',
  'switch',
  'case',
  'default',
  'break',
  'continue',
  'return',
  'throw',
  'try',
  'catch',
  'finally',
  'await',
  'yield',
  'import',
  'export',
  'from',
  'as',
};

const _declarationKeywords = {
  'var',
  'let',
  'const',
  'function',
  'class',
  'extends',
  'async',
  'static',
  'get',
  'set',
  'new',
  'typeof',
  'instanceof',
  'delete',
  'in',
  'of',
  'void',
  'this',
  'super',
};

const _languageConstants = {
  'true',
  'false',
  'null',
  'undefined',
  'NaN',
  'Infinity',
};

TextSpan _buildHighlightedLineSpan(
  String line, {
  required int entryState,
  required bool isFirstLine,
  required _CodePalette palette,
  required TextRange composing,
}) {
  final rootStyle = _baseCodeStyle.merge(palette.plain);
  if (line.length > _maxHighlightedLineLength) {
    return _applyComposingToPlainLine(line, rootStyle, composing);
  }

  final spans = <TextSpan>[];
  final length = line.length;
  var i = 0;
  var plainStart = 0;
  var state = entryState;

  void flushPlain(int end) {
    if (end > plainStart) {
      spans.add(TextSpan(text: line.substring(plainStart, end)));
    }
    plainStart = end;
  }

  void addToken(int start, int end, TextStyle style) {
    flushPlain(start);
    spans.add(TextSpan(text: line.substring(start, end), style: style));
    plainStart = end;
  }

  if (isFirstLine &&
      state == _LexState.normal &&
      length >= 2 &&
      line.codeUnitAt(0) == 0x23 &&
      line.codeUnitAt(1) == 0x21) {
    spans.add(TextSpan(text: line, style: palette.comment));
    return _finalizeLineSpan(spans, rootStyle, composing);
  }

  while (i < length) {
    if (state == _LexState.blockComment) {
      final closeIndex = line.indexOf('*/', i);
      if (closeIndex == -1) {
        addToken(i, length, palette.comment);
        i = length;
      } else {
        addToken(i, closeIndex + 2, palette.comment);
        i = closeIndex + 2;
        state = _LexState.normal;
      }
      continue;
    }

    if (state == _LexState.template) {
      final tokenStart = i;
      var hitInterpolation = false;
      while (i < length) {
        final ch = line.codeUnitAt(i);
        if (ch == 0x5C && i + 1 < length) {
          i += 2;
          continue;
        }
        if (ch == 0x60) {
          i++;
          state = _LexState.normal;
          break;
        }
        if (ch == 0x24 && i + 1 < length && line.codeUnitAt(i + 1) == 0x7B) {
          hitInterpolation = true;
          break;
        }
        i++;
      }
      if (i > tokenStart) {
        addToken(tokenStart, i, palette.string);
      }
      if (hitInterpolation) {
        final exprStart = i;
        i += 2;
        var depth = 1;
        while (i < length && depth > 0) {
          final ch = line.codeUnitAt(i);
          if (ch == 0x7B) {
            depth++;
          } else if (ch == 0x7D) {
            depth--;
          }
          i++;
        }
        addToken(exprStart, i, palette.interpolation);
      }
      continue;
    }

    final ch = line.codeUnitAt(i);

    if (ch == 0x2F && i + 1 < length) {
      final next = line.codeUnitAt(i + 1);
      if (next == 0x2F) {
        addToken(i, length, palette.comment);
        i = length;
        continue;
      }
      if (next == 0x2A) {
        final closeIndex = line.indexOf('*/', i + 2);
        if (closeIndex == -1) {
          addToken(i, length, palette.comment);
          i = length;
          state = _LexState.blockComment;
        } else {
          addToken(i, closeIndex + 2, palette.comment);
          i = closeIndex + 2;
        }
        continue;
      }
    }

    if (ch == 0x22 || ch == 0x27) {
      final quote = ch;
      final start = i++;
      while (i < length) {
        final c = line.codeUnitAt(i);
        if (c == 0x5C && i + 1 < length) {
          i += 2;
          continue;
        }
        i++;
        if (c == quote) break;
      }
      addToken(start, i, palette.string);
      continue;
    }

    if (ch == 0x60) {
      addToken(i, i + 1, palette.string);
      i++;
      state = _LexState.template;
      continue;
    }

    if (_isIdentStart(ch)) {
      final start = i++;
      while (i < length && _isIdentPart(line.codeUnitAt(i))) {
        i++;
      }
      final word = line.substring(start, i);
      if (_controlKeywords.contains(word)) {
        addToken(start, i, palette.keywordControl);
      } else if (_declarationKeywords.contains(word)) {
        addToken(start, i, palette.keywordDeclaration);
      } else if (_languageConstants.contains(word)) {
        addToken(start, i, palette.constant);
      }
      continue;
    }

    if (_isDigit(ch)) {
      final start = i++;
      if (ch == 0x30 && i < length) {
        final next = line.codeUnitAt(i);
        if (next == 0x78 || next == 0x58) {
          i++;
          while (i < length && _isHexDigit(line.codeUnitAt(i))) {
            i++;
          }
          addToken(start, i, palette.number);
          continue;
        }
        if (next == 0x62 || next == 0x42 || next == 0x6F || next == 0x4F) {
          i++;
          while (i < length && _isDigit(line.codeUnitAt(i))) {
            i++;
          }
          addToken(start, i, palette.number);
          continue;
        }
      }
      while (i < length && _isDigit(line.codeUnitAt(i))) {
        i++;
      }
      if (i + 1 < length &&
          line.codeUnitAt(i) == 0x2E &&
          _isDigit(line.codeUnitAt(i + 1))) {
        i += 2;
        while (i < length && _isDigit(line.codeUnitAt(i))) {
          i++;
        }
      }
      if (i < length &&
          (line.codeUnitAt(i) == 0x65 || line.codeUnitAt(i) == 0x45)) {
        var exp = i + 1;
        if (exp < length &&
            (line.codeUnitAt(exp) == 0x2B || line.codeUnitAt(exp) == 0x2D)) {
          exp++;
        }
        if (exp < length && _isDigit(line.codeUnitAt(exp))) {
          i = exp + 1;
          while (i < length && _isDigit(line.codeUnitAt(i))) {
            i++;
          }
        }
      }
      addToken(start, i, palette.number);
      continue;
    }

    if (_isBracket(ch)) {
      addToken(i, i + 1, palette.bracket);
      i++;
      continue;
    }

    if (_isOperator(ch)) {
      final start = i++;
      while (i < length && _isOperator(line.codeUnitAt(i))) {
        if (line.codeUnitAt(i) == 0x2F &&
            i + 1 < length &&
            (line.codeUnitAt(i + 1) == 0x2F ||
                line.codeUnitAt(i + 1) == 0x2A)) {
          break;
        }
        i++;
      }
      addToken(start, i, palette.operator);
      continue;
    }

    i++;
  }

  flushPlain(length);
  return _finalizeLineSpan(spans, rootStyle, composing);
}

TextSpan _applyComposingToPlainLine(
  String line,
  TextStyle rootStyle,
  TextRange composing,
) {
  if (!composing.isValid || composing.isCollapsed) {
    return TextSpan(text: line, style: rootStyle);
  }
  final start = composing.start.clamp(0, line.length);
  final end = composing.end.clamp(0, line.length);
  if (start >= end) return TextSpan(text: line, style: rootStyle);
  return TextSpan(
    style: rootStyle,
    children: [
      if (start > 0) TextSpan(text: line.substring(0, start)),
      TextSpan(
        text: line.substring(start, end),
        style: const TextStyle(decoration: TextDecoration.underline),
      ),
      if (end < line.length) TextSpan(text: line.substring(end)),
    ],
  );
}

TextSpan _finalizeLineSpan(
  List<TextSpan> spans,
  TextStyle rootStyle,
  TextRange composing,
) {
  if (!composing.isValid || composing.isCollapsed) {
    return TextSpan(style: rootStyle, children: spans);
  }
  final decorated = <TextSpan>[];
  var offset = 0;
  for (final span in spans) {
    final text = span.text;
    if (text == null || text.isEmpty) continue;
    final end = offset + text.length;
    if (end <= composing.start || offset >= composing.end) {
      decorated.add(span);
    } else {
      final localStart = math.max(0, composing.start - offset);
      final localEnd = math.min(text.length, composing.end - offset);
      if (localStart > 0) {
        decorated.add(
          TextSpan(text: text.substring(0, localStart), style: span.style),
        );
      }
      decorated.add(
        TextSpan(
          text: text.substring(localStart, localEnd),
          style: (span.style ?? const TextStyle()).copyWith(
            decoration: TextDecoration.underline,
          ),
        ),
      );
      if (localEnd < text.length) {
        decorated.add(
          TextSpan(text: text.substring(localEnd), style: span.style),
        );
      }
    }
    offset = end;
  }
  return TextSpan(style: rootStyle, children: decorated);
}

bool _isIdentStart(int ch) =>
    (ch >= 0x41 && ch <= 0x5A) ||
    (ch >= 0x61 && ch <= 0x7A) ||
    ch == 0x5F ||
    ch == 0x24;

bool _isIdentPart(int ch) => _isIdentStart(ch) || _isDigit(ch);

bool _isDigit(int ch) => ch >= 0x30 && ch <= 0x39;

bool _isHexDigit(int ch) =>
    _isDigit(ch) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66);

bool _isBracket(int ch) =>
    ch == 0x28 ||
    ch == 0x29 ||
    ch == 0x5B ||
    ch == 0x5D ||
    ch == 0x7B ||
    ch == 0x7D;

bool _isOperator(int ch) =>
    ch == 0x3D ||
    ch == 0x2B ||
    ch == 0x2D ||
    ch == 0x2A ||
    ch == 0x2F ||
    ch == 0x25 ||
    ch == 0x21 ||
    ch == 0x26 ||
    ch == 0x7C ||
    ch == 0x5E ||
    ch == 0x7E ||
    ch == 0x3C ||
    ch == 0x3E ||
    ch == 0x3F ||
    ch == 0x3A;
