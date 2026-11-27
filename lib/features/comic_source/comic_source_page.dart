import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source_manager.dart';
import 'package:venera_plus/features/comic_source/source.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/app_dio.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/routing/webview.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'source_translation.dart';
import 'source_repositories.dart';
import 'source_import_dialog.dart';
import 'source_installation_widgets.dart';
import 'source_repository_page.dart';
import 'source_script_editor.dart';
import 'parser.dart' show compareSemVer;

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  @visibleForTesting
  static Dio Function()? debugCreateDio;

  static Dio _createDio() => debugCreateDio?.call() ?? AppDio();

  static final _updating = <String, CancelToken>{};

  static Future<void> update(ComicSource source, [bool showLoading = true]) =>
      _update(source, showLoading: showLoading);

  static Future<void> _update(
    ComicSource source, {
    required bool showLoading,
    CancelToken? cancelToken,
  }) async {
    if (_updating.containsKey(source.key)) {
      // An interactive duplicate tap stays silent because the loading dialog
      // already owns the update. A batch caller must not mistake the skipped
      // update for a success.
      if (!showLoading) throw 'Update already in progress'.tl;
      return;
    }
    final token = cancelToken ?? CancelToken();
    _updating[source.key] = token;
    var publishing = false;
    Dio? dio;
    LoadingDialogController? controller;
    final loadingContext = showLoading ? App.rootContext : null;
    void releaseUpdate() {
      if (identical(_updating[source.key], token)) {
        _updating.remove(source.key);
      }
    }

    try {
      if (loadingContext != null) {
        controller = showLoadingDialog(
          loadingContext,
          onCancel: () {
            token.cancel();
            releaseUpdate();
          },
          barrierDismissible: false,
        );
      }
      dio = _createDio();
      final store = SourceRepositories.instance;
      final origin = store.originFor(source.key);
      final repository = store.find(origin?.repositoryId);
      final url = await store.updateUrl(
        source,
        client: dio,
        cancelToken: token,
      );
      if (token.isCancelled) throw token.cancelError!;
      final res = await dio.get<String>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      if (token.isCancelled) throw token.cancelError!;
      await ComicSourceManager().replaceScript(
        source,
        res.data!,
        validate: () {
          if (!publishing && token.isCancelled) throw token.cancelError!;
          if (store.originFor(source.key)?.repositoryId !=
                  origin?.repositoryId ||
              store.originFor(source.key)?.url != origin?.url ||
              ComicSource.find(source.key)?.filePath != source.filePath ||
              (repository != null &&
                  store.find(repository.id)?.url != repository.url)) {
            throw 'Repository changed. Refresh the list and try again.'.tl;
          }
          // 排队时仍可取消，开始替换后让当前事务完整结束。
          if (!publishing) {
            publishing = true;
            controller?.close();
          }
        },
        origin: repository == null
            ? null
            : SourceOrigin(
                kind: 'repository',
                repositoryId: repository.id,
                repositoryName: repository.name,
                url: url,
              ),
      );
    } catch (e, stack) {
      if (!publishing && token.isCancelled) {
        if (!showLoading) throw token.cancelError!;
        return;
      }
      Log.error('Update comic source', e, stack);
      if (!showLoading) rethrow;
      final context = App.rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        context.showMessage(
          message: e is DioException ? 'Network error'.tl : e.toString(),
        );
      }
    } finally {
      controller?.close();
      dio?.close();
      releaseUpdate();
    }
  }

  static Future<int> checkComicSourceUpdate() async {
    final result = await _checkSourceUpdates();
    if (result.failures.isNotEmpty) {
      Log.warning('Check Comic Source Updates', result.failures.join('\n'));
    }
    return result.updates.length;
  }

  static Future<SourceUpdateCheck> _checkSourceUpdates() async {
    final result = await SourceRepositories.instance.checkUpdates(
      ComicSource.all().where((source) => source.filePath.isNotEmpty).toList(),
    );
    ComicSourceManager().updateAvailableUpdates(result.updates);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Website Sources'.tl),
            actions: [
              TextButton.icon(
                onPressed: () => showAddWebsiteSource(context),
                icon: const Icon(Icons.add),
                label: Text('Add'.tl),
              ),
            ],
          ),
          const ComicSourcesSliverList(),
        ],
      ),
    );
  }
}

Future<void> showSourceRepositories(BuildContext context) => showPopUpWidget(
  context,
  PopUpWidgetScaffold(
    title: 'Source Repositories'.tl,
    body: const SourceRepositoriesPanel(),
  ),
);

Future<void> showAddWebsiteSource(BuildContext context) async {
  final fromRepository = await showDialog<bool>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Add Website Source'.tl),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, true),
          child: ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text('Source Repositories'.tl),
            subtitle: Text('Browse sources'.tl),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, false),
          child: ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: Text('Import Link or File'.tl),
          ),
        ),
      ],
    ),
  );
  if (fromRepository == null || !context.mounted) return;
  if (fromRepository) {
    await showSourceRepositories(context);
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => const SourceImportDialog(),
    );
  }
}

class ComicSourcesSliverList extends StatefulWidget {
  const ComicSourcesSliverList({super.key});

  @override
  State<ComicSourcesSliverList> createState() => _ComicSourcesSliverListState();
}

class _ComicSourcesSliverListState extends State<ComicSourcesSliverList> {
  void updateUI() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
    SourceRepositories.instance.addListener(updateUI);
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(updateUI);
    SourceRepositories.instance.removeListener(updateUI);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = ComicSource.all()
        .where((source) => source.filePath.isNotEmpty)
        .toList();
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => showSourceRepositories(context),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text('Source Repositories'.tl),
              ),
              TextButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const SourceImportDialog(),
                ),
                icon: const Icon(Icons.file_open_outlined),
                label: Text('Import Link or File'.tl),
              ),
              const _CheckUpdatesButton(),
              IconButton(
                tooltip: 'Help'.tl,
                icon: const Icon(Icons.help_outline),
                onPressed: () => launchUrlString(
                  'https://github.com/Venera-Works/Venera-Plus/blob/main/docs/api/comic_source.zh.md',
                ),
              ),
              const SourceInstallationSummary(compact: true),
            ],
          ).paddingHorizontal(12).paddingVertical(8),
        ),
        if (sources.isEmpty)
          SliverToBoxAdapter(
            child: SourceManagementEmptyState(
              icon: Icons.language_outlined,
              title: 'No Website Sources'.tl,
              description: 'Install from a repository, link or file.'.tl,
            ),
          ),
        for (var source in sources)
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
      ],
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        try {
          await ComicSourceManager().uninstallScript(source);
        } catch (error, stack) {
          Log.error('Delete comic source', error, stack);
          if (mounted) {
            context.showMessage(
              message: "${'Failed to delete comic source'.tl}: $error",
            );
          }
          return;
        }
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  Future<void> edit(ComicSource source) async {
    if (App.isDesktop) {
      var openedExternally = false;
      try {
        final result = await Process.run("code", [
          source.filePath,
        ], runInShell: true);
        openedExternally = result.exitCode == 0;
      } on ProcessException {
        // 外部编辑器无法启动时使用内置编辑器。
      }
      if (!mounted) return;
      if (openedExternally) {
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: Text("Reload Configs".tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel".tl),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: Text("Continue".tl),
              ),
            ],
          ),
        );
        return;
      }
    }

    final String script;
    try {
      script = await File(source.filePath).readAsString();
    } catch (error) {
      if (mounted) {
        context.showMessage(message: "${'Failed to load source'.tl}: $error");
      }
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      SourceScriptEditorRoute(
        script: script,
        onSave: (draft) =>
            ComicSourceManager().replaceScript(source, draft, validate: () {}),
      ),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() => isLoading = true);
    try {
      final result = await ComicSourcePage._checkSourceUpdates();
      if (!mounted) return;
      if (result.failures.isNotEmpty) {
        context.showMessage(message: result.failures.join('\n'));
      }
      if (result.updates.isNotEmpty) {
        await showUpdateDialog();
      } else if (result.failures.isEmpty) {
        context.showMessage(
          message: [
            'No updates'.tl,
            if (result.skipped > 0)
              'Skipped @count sources.'.tlParams({'count': result.skipped}),
          ].join('\n'),
        );
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> showUpdateDialog() async {
    final manager = ComicSourceManager();
    final updates = [
      for (final entry in manager.availableUpdates.entries)
        if (ComicSource.find(entry.key) case final ComicSource source)
          (source: source, version: entry.value),
    ];
    if (updates.isEmpty) return;
    final text = updates
        .map((update) => "${update.source.name}: ${update.version}")
        .join("\n");
    final confirmed = await showDialog<bool>(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () => context.pop(true),
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final token = CancelToken();
    final controller = showLoadingDialog(
      context,
      message: 'Updating'.tl,
      withProgress: true,
      closeOnCancel: false,
      onCancel: token.cancel,
    );
    var updated = 0;
    final failures = <String>[];
    try {
      for (final update in updates) {
        if (token.isCancelled) break;
        try {
          await ComicSourcePage._update(
            update.source,
            showLoading: false,
            cancelToken: token,
          );
          updated++;
        } catch (error) {
          if (identical(error, token.cancelError)) break;
          final reason = error is DioException ? 'Network error'.tl : error;
          failures.add('${update.source.name}: $reason');
        }
        controller.setProgress((updated + failures.length) / updates.length);
      }
    } finally {
      controller.close();
      manager.notifyStateChange();
    }
    if (!mounted) return;
    context.showMessage(
      message: [
        'Updated: @a, Failed: @b, Cancelled: @c'.tlParams({
          'a': updated,
          'b': failures.length,
          'c': updates.length - updated - failures.length,
        }),
        ...failures,
      ].join('\n'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: isLoading ? null : check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            onTap: () {
              setState(() {
                _expanded = !_expanded;
              });
            },
            leading: const Icon(Icons.extension_outlined),
            title: Text(source.name),
            subtitle: Text(
              [
                source.version,
                SourceRepositories.instance.originLabel(source.key),
                if (hasUpdate) '${'New Version'.tl}: $newVersion',
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Source actions'.tl,
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        widget.edit(source);
                      case 'update':
                        widget.update(source);
                      case 'delete':
                        widget.delete(source);
                      case 'origin':
                        showSourceOriginPicker(context, source);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit', child: Text('Edit'.tl)),
                    PopupMenuItem(value: 'update', child: Text('Update'.tl)),
                    PopupMenuItem(
                      value: 'origin',
                      child: Text('Manage source origin'.tl),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete'.tl)),
                  ],
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: context.colorScheme.outlineVariant,
                    width: 0.6,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(children: buildSourceSettings().toList()),
          ),
          SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
        ],
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          final options = item.value['options'] as List;
          final defaultValue = item.value['default'];
          final savedValue = source.data['settings'][key] ?? defaultValue;
          var index = options.indexWhere(
            (option) => option['value'] == savedValue,
          );
          if (index < 0) {
            index = options.indexWhere(
              (option) => option['value'] == defaultValue,
            );
          }
          if (index < 0) index = 0;
          final labels = options
              .map<String>(
                (option) => ((option['text'] ?? option['value']) as String).ts(
                  source.key,
                ),
              )
              .toList();
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: labels.isEmpty ? null : labels[index],
              selectedIndex: index,
              values: labels,
              onTap: (i) {
                source.data['settings'][key] = options[i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  static final _reLoginInProgress = <String>{};

  Future<void> _reLogin(ComicSource source) async {
    final account = source.data['account'];
    final login = source.account?.login;
    if (account is! List || login == null) {
      context.showMessage(message: 'No data'.tl);
      return;
    }
    if (!_reLoginInProgress.add(source.key)) return;
    final manager = ComicSourceManager();
    manager.notifyStateChange();
    try {
      final result = await login(account[0], account[1]);
      if (!mounted || !identical(source, this.source)) return;
      context.showMessage(
        message: result.error ? result.errorMessage! : 'Success'.tl,
      );
    } finally {
      _reLoginInProgress.remove(source.key);
      manager.notifyStateChange();
    }
  }

  Iterable<Widget> _buildAccount() sync* {
    final source = this.source;
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          if (mounted) setState(() {});
        },
      );
    }
    if (logged) {
      final reLoggingIn = _reLoginInProgress.contains(source.key);
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: reLoggingIn ? null : () => _reLogin(source),
          trailing: reLoggingIn
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: reLoggingIn
            ? null
            : () {
                if (_reLoginInProgress.contains(source.key)) return;
                source.data["account"] = null;
                source.account?.logout();
                source.saveData();
                ComicSourceManager().notifyStateChange();
              },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;
  bool _obscurePassword = true;
  bool _webviewLoginHandled = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Login".tl, style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 32),
                  if (widget.config.cookieFields == null)
                    TextField(
                      decoration: InputDecoration(
                        labelText: "Username".tl,
                        border: const OutlineInputBorder(),
                      ),
                      enabled: widget.config.login != null,
                      onChanged: (s) {
                        username = s;
                      },
                      autofillHints: const [AutofillHints.username],
                    ).paddingBottom(16),
                  if (widget.config.cookieFields == null)
                    TextField(
                      decoration: InputDecoration(
                        labelText: "Password".tl,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip:
                              (_obscurePassword
                                      ? 'Show password'
                                      : 'Hide password')
                                  .tl,
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: widget.config.login == null
                              ? null
                              : () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                        ),
                      ),
                      obscureText: _obscurePassword,
                      enabled: widget.config.login != null,
                      onChanged: (s) {
                        password = s;
                      },
                      onSubmitted: (s) => login(),
                      autofillHints: const [AutofillHints.password],
                    ).paddingBottom(16),
                  for (var field in widget.config.cookieFields ?? <String>[])
                    TextField(
                      decoration: InputDecoration(
                        labelText: field,
                        border: const OutlineInputBorder(),
                      ),
                      obscureText: true,
                      enabled: widget.config.validateCookies != null,
                      onChanged: (s) {
                        _cookies[field] = s;
                      },
                    ).paddingBottom(16),
                  if (widget.config.login == null &&
                      widget.config.cookieFields == null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text("Login with password is disabled".tl),
                        ),
                      ],
                    )
                  else
                    Button.filled(
                      isLoading: loading,
                      onPressed: login,
                      child: Text("Continue".tl),
                    ),
                  const SizedBox(height: 24),
                  if (widget.config.loginWebsite != null)
                    TextButton(
                      onPressed: () {
                        if (App.isLinux) {
                          loginWithWebview2();
                        } else {
                          loginWithWebview();
                        }
                      },
                      child: Text("Login with webview".tl),
                    ),
                  const SizedBox(height: 8),
                  if (widget.config.registerWebsite != null)
                    TextButton(
                      onPressed: () =>
                          launchUrlString(widget.config.registerWebsite!),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.link),
                          const SizedBox(width: 8),
                          Text("Create Account".tl),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    final available = await DesktopWebview.isAvailable();
    if (!mounted) return;
    if (!available) {
      context.showMessage(message: "Webview is not available".tl);
      return;
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (!success || !mounted || _webviewLoginHandled) return;
      _webviewLoginHandled = true;
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      if (ModalRoute.isCurrentOf(context) == true) context.pop();
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
