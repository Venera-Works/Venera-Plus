import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/reader_diagnostics.dart';
import 'package:venera_plus/foundation/translations.dart';

/// Reports stay in this reader's memory until cleared or the reader closes.
class ReaderDiagnosticsDialog extends StatefulWidget {
  const ReaderDiagnosticsDialog({super.key, required this.diagnostics});
  final ReaderDiagnostics diagnostics;

  @override
  State<ReaderDiagnosticsDialog> createState() =>
      _ReaderDiagnosticsDialogState();
}

class _ReaderDiagnosticsDialogState extends State<ReaderDiagnosticsDialog> {
  final _previewScroll = ScrollController();
  bool _copying = false;
  String? _feedback;

  @override
  void dispose() {
    _previewScroll.dispose();
    super.dispose();
  }

  Future<void> _copy(String report) async {
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: report));
      if (mounted) setState(() => _feedback = 'Copied'.tl);
    } catch (_) {
      if (mounted) setState(() => _feedback = 'Unable to copy report.'.tl);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.diagnostics,
    builder: (context, _) {
      final diagnostics = widget.diagnostics;
      final report = diagnostics.hasCapture ? diagnostics.exportJson() : null;
      final lines = report?.split('\n') ?? const <String>[];
      final theme = Theme.of(context);
      return ContentDialog(
        title: 'Reading diagnostics'.tl,
        content: Container(
          width: 600,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manual capture only, up to 45 seconds. Browse existing local pages, then quickly revisit them. Open this dialog again to stop and review.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Only numeric timings, anonymous image numbers and basic reader options are included. No comic content, titles, paths, URLs, accounts, scripts or error text. Nothing is uploaded.'
                    .tl,
              ),
              const SizedBox(height: 12),
              Text(
                'Elapsed image waits do not prove UI blocking. Frame samples are not measured FPS. Captures are cleared when the reader closes.'
                    .tl,
              ),
              if (diagnostics.hasCapture) ...[
                const SizedBox(height: 12),
                Text(
                  diagnostics.isRecording
                      ? 'Capturing...'.tl
                      : 'Report preview'.tl,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: (MediaQuery.sizeOf(context).height * .35).clamp(
                    100,
                    280,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Scrollbar(
                      controller: _previewScroll,
                      child: ListView.builder(
                        key: const ValueKey('reader-diagnostic-preview'),
                        controller: _previewScroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        itemBuilder: (context, index) => SelectableText(
                          lines[index],
                          textDirection: TextDirection.ltr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (_feedback != null) ...[
                const SizedBox(height: 8),
                Text(_feedback!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Close'.tl),
          ),
          if (report != null && !diagnostics.isRecording) ...[
            TextButton(
              onPressed: _copying
                  ? null
                  : () {
                      diagnostics.clear();
                      setState(() => _feedback = null);
                    },
              child: Text('Clear report'.tl),
            ),
            TextButton(
              onPressed: _copying ? null : () => _copy(report),
              child: Text('Copy report'.tl),
            ),
          ],
          if (diagnostics.isRecording)
            FilledButton(
              onPressed: () => diagnostics.stop(ReaderDiagnosticStop.review),
              child: Text('Stop and review'.tl),
            )
          else
            FilledButton(
              onPressed: _copying
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: Text('Start new 45-second capture'.tl),
            ),
        ],
      );
    },
  );
}
