import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/app_update/app_update.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text(
              "VeneraPlus is a free and open-source app for comic reading.".tl,
            ),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        SettingPartTitle(
          title: 'Updates'.tl,
          icon: Icons.system_update_outlined,
        ),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: FilledButton(
            style: actionButtonStyle,
            onPressed: isCheckingUpdate
                ? null
                : () async {
                    setState(() {
                      isCheckingUpdate = true;
                    });
                    try {
                      await appUpdatePrompt.check();
                    } finally {
                      if (mounted) setState(() => isCheckingUpdate = false);
                    }
                  },
            child: ButtonLoadingContent(
              isLoading: isCheckingUpdate,
              child: Text("Check".tl),
            ),
          ),
        ).toSliver(),
        SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
          onChanged: () {
            if (mounted) setState(() {});
          },
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: appdata.settings['checkUpdateOnStart'],
          child: SelectSetting(
            title: 'Update channel'.tl,
            settingKey: 'appUpdateChannel',
            optionTranslation: {'stable': 'Stable'.tl, 'beta': 'Beta'.tl},
          ),
        ),
        SettingPartTitle(title: 'Information'.tl, icon: Icons.info_outline),
        ListTile(
          title: Text('Changelog'.tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () => context.to(() => const ChangelogPage()),
        ).toSliver(),
        ListTile(
          title: Text('GitHub'.tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/Venera-Works/Venera-Plus");
          },
        ).toSliver(),
      ],
    );
  }
}

class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final Future<List<String>> _changelog = rootBundle
      .loadString("CHANGELOG.md")
      .then((data) => data.split(RegExp(r'(?=^## )', multiLine: true)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      child: SelectionArea(
        child: SmoothCustomScrollView(
          slivers: [
            SelectionContainer.disabled(
              child: SliverAppbar(title: Text("Changelog".tl)),
            ),
            FutureBuilder(
              future: _changelog,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text("Error".tl)),
                  );
                }
                if (!snapshot.hasData) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final sections = snapshot.data!;
                final styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                  h1: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  h2: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  h3: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  code: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSecondaryContainer,
                    backgroundColor: colorScheme.secondaryContainer,
                  ),
                );
                return SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList.separated(
                    itemCount: sections.length,
                    itemBuilder: (context, index) => MarkdownBody(
                      data: sections[index],
                      styleSheet: styleSheet,
                    ),
                    separatorBuilder: (context, index) =>
                        SizedBox(height: styleSheet.blockSpacing),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
