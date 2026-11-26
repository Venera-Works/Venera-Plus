import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'setting_components.dart';

class StorageSettings extends StatefulWidget {
  const StorageSettings({super.key});

  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Storage'.tl)),
        SettingPartTitle(title: 'Local Comics'.tl, icon: Icons.folder_outlined),
        ListTile(
          title: Text('Storage Path'.tl),
          subtitle: Text(LocalManager().path, softWrap: false),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: LocalManager().path));
              context.showMessage(message: 'Path copied to clipboard'.tl);
            },
          ),
        ).toSliver(),
        CallbackSetting(
          title: 'Change Storage Path'.tl,
          actionTitle: 'Set'.tl,
          callback: () async {
            String? path;
            if (App.isAndroid) {
              path = (await DirectoryPicker().pickDirectory())?.path;
            } else if (App.isIOS) {
              path = await selectDirectoryIOS();
            } else {
              path = await selectDirectory();
            }
            if (path == null || !mounted) return;
            final loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            final error = await LocalManager().setNewPath(path);
            loadingDialog.close();
            if (!mounted) return;
            if (error != null) {
              context.showMessage(message: error);
            } else {
              context.showMessage(message: 'Path set successfully'.tl);
              setState(() {});
            }
          },
        ).toSliver(),
        SettingPartTitle(title: 'Downloads'.tl, icon: Icons.download_outlined),
        SliderSetting(
          title: 'Download Threads'.tl,
          settingsIndex: 'downloadThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
        SwitchSetting(
          title: 'Skip unavailable images when downloading'.tl,
          settingKey: 'skipUnavailableDownloadImages',
        ).toSliver(),
        SettingPartTitle(
          title: 'Cache'.tl,
          icon: Icons.cleaning_services_outlined,
        ),
        ListTile(
          title: Text('Cache Size'.tl),
          subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
        ).toSliver(),
        CallbackSetting(
          title: 'Clear Cache'.tl,
          actionTitle: 'Clear'.tl,
          callback: () async {
            final loadingDialog = showLoadingDialog(
              App.rootContext,
              barrierDismissible: false,
              allowCancel: false,
            );
            await CacheManager().clear();
            loadingDialog.close();
            if (!mounted) return;
            context.showMessage(message: 'Cache cleared'.tl);
            setState(() {});
          },
        ).toSliver(),
        CallbackSetting(
          title: 'Cache Limit'.tl,
          subtitle: "${appdata.settings['cacheSize']} MB",
          callback: () {
            showInputDialog(
              context: context,
              title: 'Set Cache Limit'.tl,
              hintText: 'Size in MB'.tl,
              inputValidator: RegExp(r'^\d+$'),
              onConfirm: (value) {
                final limit = int.parse(value);
                appdata.settings['cacheSize'] = limit;
                appdata.saveData();
                setState(() {});
                CacheManager().setLimitSize(limit);
                return null;
              },
            );
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
      ],
    );
  }
}
