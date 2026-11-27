import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String logLevelToShow = "all";

  String _levelLabel(LogLevel level) => switch (level) {
    LogLevel.info => 'Information'.tl,
    LogLevel.warning => 'Warning'.tl,
    LogLevel.error => 'Error'.tl,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    var logToShow = logLevelToShow == "all"
        ? Log.logs
        : Log.logs.where((log) => log.level.name == logLevelToShow).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Logs".tl),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Filter'.tl,
            icon: const Icon(Icons.filter_list_outlined),
            position: PopupMenuPosition.under,
            onSelected: (level) => setState(() => logLevelToShow = level),
            itemBuilder: (context) => [
              PopupMenuItem(value: 'all', child: Text('All'.tl)),
              for (final level in LogLevel.values.reversed)
                PopupMenuItem(
                  value: level.name,
                  child: Text(_levelLabel(level)),
                ),
            ],
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'More'.tl,
            icon: const Icon(Icons.more_horiz),
            position: PopupMenuPosition.under,
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: () => setState(Log.clear),
                child: Text('Clear'.tl),
              ),
              PopupMenuItem(
                value: () {
                  Log.ignoreLimitation = true;
                  context.showMessage(message: 'Only valid for this run'.tl);
                },
                child: Text('Disable Length Limitation'.tl),
              ),
              PopupMenuItem(
                value: () => saveLog(Log().toString()),
                child: Text('Export'.tl),
              ),
            ],
          ),
        ],
      ),
      body: ListView.builder(
        reverse: true,
        controller: ScrollController(),
        itemCount: logToShow.length,
        itemBuilder: (context, index) {
          final log = logToShow[logToShow.length - index - 1];
          final (background, foreground) = switch (log.level) {
            LogLevel.info => (
              colors.primaryContainer,
              colors.onPrimaryContainer,
            ),
            LogLevel.warning => (
              colors.tertiaryContainer,
              colors.onTertiaryContainer,
            ),
            LogLevel.error => (colors.errorContainer, colors.onErrorContainer),
          };
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                            child: Text(
                              log.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                        child: Text(
                          _levelLabel(log.level),
                          style: TextStyle(color: foreground),
                        ),
                      ),
                    ],
                  ),
                  Text(log.content),
                  Text(log.time.toString().replaceAll(RegExp(r"\.\w+"), "")),
                  TextButton(
                    style: actionButtonStyle,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: log.content));
                    },
                    child: Text("Copy".tl),
                  ),
                  const Divider(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void saveLog(String log) async {
    await Log.flush();
    saveFile(data: utf8.encode(log), filename: 'log.txt');
  }
}
