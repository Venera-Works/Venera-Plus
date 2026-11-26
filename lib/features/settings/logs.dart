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

  @override
  Widget build(BuildContext context) {
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
              PopupMenuItem(value: 'info', child: Text('Information'.tl)),
              PopupMenuItem(value: 'warning', child: Text('Warning'.tl)),
              PopupMenuItem(value: 'error', child: Text('Error'.tl)),
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
          index = logToShow.length - index - 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(logToShow[index].title),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        decoration: BoxDecoration(
                          color: [
                            Theme.of(context).colorScheme.error,
                            Theme.of(context).colorScheme.errorContainer,
                            Theme.of(context).colorScheme.primaryContainer,
                          ][logToShow[index].level.index],
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(
                            logToShow[index].level.name,
                            style: TextStyle(
                              color: logToShow[index].level.index == 0
                                  ? Colors.white
                                  : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(logToShow[index].content),
                  Text(
                    logToShow[index].time.toString().replaceAll(
                      RegExp(r"\.\w+"),
                      "",
                    ),
                  ),
                  TextButton(
                    style: actionButtonStyle,
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: logToShow[index].content),
                      );
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
