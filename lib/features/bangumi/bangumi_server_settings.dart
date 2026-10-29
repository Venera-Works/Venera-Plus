import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/app_dio.dart';

import 'bangumi_server.dart';

class BangumiServerSetting extends StatelessWidget {
  const BangumiServerSetting({
    super.key,
    required this.saveSettings,
    required this.onChanged,
    this.enabled = true,
    this.probe = probeBangumiServer,
  });

  final Future<void> Function() saveSettings;
  final VoidCallback onChanged;
  final bool enabled;
  final BangumiServerProbe probe;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Bangumi server'.tl, style: Theme.of(context).textTheme.titleMedium),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            currentBangumiServer.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          OutlinedButton.icon(
            key: const Key('bangumi-server-list'),
            icon: const Icon(Icons.list),
            label: Text('Website list'.tl),
            onPressed: enabled
                ? () async {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => _BangumiServerList(
                        saveSettings: saveSettings,
                        onChanged: onChanged,
                        probe: probe,
                      ),
                    );
                  }
                : null,
          ),
        ],
      ),
    ],
  );
}

class _BangumiServerList extends StatefulWidget {
  const _BangumiServerList({
    required this.saveSettings,
    required this.onChanged,
    required this.probe,
  });

  final Future<void> Function() saveSettings;
  final VoidCallback onChanged;
  final BangumiServerProbe probe;

  @override
  State<_BangumiServerList> createState() => _BangumiServerListState();
}

class _BangumiServerListState extends State<_BangumiServerList> {
  late List<BangumiServer> _servers;
  final _results = <String, BangumiProbeResult>{};
  final _cancelTokens = <CancelToken>[];
  int _testGeneration = 0;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _servers = bangumiServers;
    _testAll();
  }

  @override
  void dispose() {
    _cancelTests();
    super.dispose();
  }

  void _cancelTests() {
    _testGeneration++;
    for (final token in _cancelTokens) {
      token.cancel('Bangumi server list closed or refreshed');
    }
    _cancelTokens.clear();
  }

  void _testAll() {
    _cancelTests();
    final generation = _testGeneration;
    final servers = List<BangumiServer>.of(_servers);
    _results.clear();
    var next = 0;
    Future<void> worker() async {
      while (mounted &&
          generation == _testGeneration &&
          next < servers.length) {
        final server = servers[next++];
        final token = CancelToken();
        _cancelTokens.add(token);
        BangumiProbeResult result;
        try {
          result = await widget.probe(server, token);
        } catch (_) {
          if (token.isCancelled) return;
          result = const BangumiProbeResult(BangumiProbeStatus.unavailable);
        } finally {
          _cancelTokens.remove(token);
        }
        if (!mounted || generation != _testGeneration) return;
        setState(() => _results[server.apiUrl] = result);
      }
    }

    for (var index = 0; index < math.min(3, servers.length); index++) {
      unawaited(worker());
    }
  }

  String _resultLabel(BangumiProbeResult? result) {
    if (result == null) return 'Testing…'.tl;
    final label = switch (result.status) {
      BangumiProbeStatus.available => 'Available'.tl,
      BangumiProbeStatus.timeout => 'Timed out'.tl,
      BangumiProbeStatus.verificationRequired => 'Verification required'.tl,
      BangumiProbeStatus.invalidResponse => 'Incompatible API'.tl,
      BangumiProbeStatus.unavailable =>
        result.statusCode == null
            ? 'Unreachable'.tl
            : 'HTTP ${result.statusCode}',
    };
    return result.status == BangumiProbeStatus.available
        ? '$label · ${result.elapsed.inMilliseconds} ms'
        : label;
  }

  Future<bool> _save(List<BangumiServer> servers, String selected) async {
    if (_saving) return false;
    final previousSelected = appdata.settings['bangumiServer'];
    final previousCustom = appdata.settings['bangumiCustomServers'];
    setState(() {
      _saving = true;
      _error = null;
    });
    appdata.settings['bangumiServer'] = selected;
    appdata.settings['bangumiCustomServers'] = [
      for (final server in servers)
        if (!server.isPreset) server.toJson(),
    ];
    try {
      await widget.saveSettings();
      if (mounted) {
        setState(() => _servers = servers);
        widget.onChanged();
      }
      return true;
    } catch (error) {
      appdata.settings['bangumiServer'] = previousSelected;
      appdata.settings['bangumiCustomServers'] = previousCustom;
      if (mounted) {
        setState(
          () => _error = '${'Failed to save Bangumi settings'.tl}: $error',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _select(BangumiServer server) async {
    if (await _save(_servers, server.apiUrl) && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _edit([BangumiServer? previous]) async {
    final server = await showDialog<BangumiServer>(
      context: context,
      builder: (_) => _BangumiServerEditor(initial: previous),
    );
    if (server == null || !mounted) return;
    final duplicate = _servers.indexWhere(
      (item) => item.apiUrl == server.apiUrl,
    );
    if (duplicate >= 0 && _servers[duplicate].apiUrl != previous?.apiUrl) {
      setState(() => _error = 'This API address is already in the list'.tl);
      return;
    }
    final servers = List<BangumiServer>.of(_servers);
    if (previous == null) {
      servers.add(server);
    } else {
      servers[servers.indexOf(previous)] = server;
    }
    final selected = currentBangumiServer.apiUrl == previous?.apiUrl
        ? server.apiUrl
        : currentBangumiServer.apiUrl;
    if (await _save(servers, selected) && mounted) {
      setState(_testAll);
    }
  }

  Future<void> _delete(BangumiServer server) async {
    final selected = currentBangumiServer.apiUrl == server.apiUrl
        ? bangumiOfficialServer.apiUrl
        : currentBangumiServer.apiUrl;
    if (await _save(
          _servers.where((item) => item != server).toList(),
          selected,
        ) &&
        mounted) {
      setState(_testAll);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Bangumi website list'.tl),
    content: SizedBox(
      width: 520,
      height: math.min(400, MediaQuery.sizeOf(context).height * 0.55),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final server in _servers)
                  ListTile(
                    key: ValueKey('bangumi-server-${server.apiUrl}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      currentBangumiServer.apiUrl == server.apiUrl
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Wrap(
                      spacing: 8,
                      children: [
                        Text(server.name),
                        Text(
                          _resultLabel(_results[server.apiUrl]),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    subtitle: Text(
                      server.apiUrl == bangumiOfficialServer.apiUrl
                          ? 'Official'.tl
                          : server.isPreset
                          ? 'Mirror'.tl
                          : 'Custom'.tl,
                    ),
                    onTap: _saving ? null : () => _select(server),
                    trailing: server.isPreset
                        ? null
                        : PopupMenuButton<String>(
                            enabled: !_saving,
                            onSelected: (action) => action == 'edit'
                                ? _edit(server)
                                : _delete(server),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit'.tl),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'.tl),
                              ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('bangumi-server-retest'),
        onPressed: _saving ? null : () => setState(_testAll),
        child: Text('Test again'.tl),
      ),
      TextButton(
        key: const Key('bangumi-server-add'),
        onPressed: _saving ? null : () => _edit(),
        child: Text('Add'.tl),
      ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: Text('Close'.tl),
      ),
    ],
  );
}

class _BangumiServerEditor extends StatefulWidget {
  const _BangumiServerEditor({this.initial});

  final BangumiServer? initial;

  @override
  State<_BangumiServerEditor> createState() => _BangumiServerEditorState();
}

class _BangumiServerEditorState extends State<_BangumiServerEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _api = TextEditingController(text: widget.initial?.apiUrl ?? '');
  late final _images = TextEditingController(
    text: widget.initial?.imageUrl ?? '',
  );
  late final _token = TextEditingController(
    text: widget.initial?.tokenUrl ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    _images.dispose();
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    // A known domain selects its stored endpoint mapping; custom hosts stay literal.
    for (final preset in bangumiPresetServers) {
      if (_api.text.trim().toLowerCase() == preset.name &&
          _images.text.trim().isEmpty &&
          _token.text.trim().isEmpty) {
        Navigator.of(context).pop(preset);
        return;
      }
    }
    final server = BangumiServer.fromJson({
      'name': _name.text,
      'apiUrl': _api.text,
      'imageUrl': _images.text,
      'tokenUrl': _token.text,
    });
    if (server == null) {
      setState(
        () => _error =
            'Enter valid HTTPS addresses without query parameters or fragments'
                .tl,
      );
      return;
    }
    Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      (widget.initial == null ? 'Add Bangumi server' : 'Edit Bangumi server')
          .tl,
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('bangumi-server-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Name or domain (optional)'.tl,
              ),
            ),
            TextField(
              key: const Key('bangumi-server-api'),
              controller: _api,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API address'.tl,
                hintText: 'bgmapi.anibt.net',
              ),
            ),
            TextField(
              key: const Key('bangumi-server-images'),
              controller: _images,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Image proxy (optional)'.tl,
                helperText:
                    'Leave empty to use image addresses returned by the API'.tl,
                helperMaxLines: 3,
              ),
            ),
            TextField(
              key: const Key('bangumi-server-token-page'),
              controller: _token,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Access Token page (optional)'.tl,
                helperText:
                    'Leave empty to use the official Access Token page'.tl,
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            Text('The selected API server receives your Access Token.'.tl),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text('Cancel'.tl),
      ),
      TextButton(
        key: const Key('bangumi-server-save'),
        onPressed: _submit,
        child: Text('Save'.tl),
      ),
    ],
  );
}
