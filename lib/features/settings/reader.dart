import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/code.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/reader/brightness.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  Widget _sectionHeading(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
      ),
    ).toSliver();
  }

  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    final isEnabledSpecificSettings = appdata.settings
        .isComicSpecificSettingsEnabled(comicId, sourceKey);
    final useDeviceSpecificSettings =
        !isEnabledSpecificSettings &&
        appdata.settings.isDeviceSpecificSettingsEnabled();

    dynamic settingValue(String settingKey) {
      if (isEnabledSpecificSettings) {
        return appdata.settings.getReaderSetting(
          comicId!,
          sourceKey!,
          settingKey,
        );
      }
      return appdata.settings.getDeviceReaderSetting(settingKey);
    }

    final effectiveReaderMode = settingValue('readerMode') as String;
    final isGalleryMode = effectiveReaderMode.startsWith('gallery');
    final isContinuousMode = effectiveReaderMode.startsWith('continuous');
    final isHorizontalGalleryMode =
        effectiveReaderMode == 'galleryLeftToRight' ||
        effectiveReaderMode == 'galleryRightToLeft';
    final isVerticalFlowMode =
        effectiveReaderMode == 'waterfallTopToBottom' ||
        effectiveReaderMode == 'continuousTopToBottom';

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              _sectionHeading(context, 'Settings Scope'.tl),
              SwitchListTile(
                title: Text("Enable comic specific settings".tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                },
              ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    style: actionButtonStyle,
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                    },
                    child: Text(
                      "Clear specific reader settings for this comic".tl,
                    ),
                  ),
                ).toSliver(),
            ],
          ),
        if (comicId == null)
          SliverMainAxisGroup(
            slivers: [
              _sectionHeading(context, 'Settings Scope'.tl),
              SwitchListTile(
                title: Text("Enable device specific settings".tl),
                value: useDeviceSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    style: actionButtonStyle,
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
                    },
                    child: Text(
                      "Clear specific reader settings for this device".tl,
                    ),
                  ),
                ).toSliver(),
            ],
          ),
        _sectionHeading(context, 'Reading Mode and Layout'.tl),
        SelectSetting(
          title: "Reading mode".tl,
          settingKey: "readerMode",
          optionTranslation: {
            "waterfallTopToBottom": "Waterfall (Top to Bottom)".tl,
            "galleryLeftToRight": "Gallery (Left to Right)".tl,
            "galleryRightToLeft": "Gallery (Right to Left)".tl,
            "galleryTopToBottom": "Gallery (Top to Bottom)".tl,
            "continuousLeftToRight": "Continuous (Left to Right)".tl,
            "continuousRightToLeft": "Continuous (Right to Left)".tl,
            "continuousTopToBottom": "Continuous (Top to Bottom)".tl,
          },
          onChanged: () {
            setState(() {});
            final mode = settingValue('readerMode') as String;
            if (mode.startsWith('continuous')) {
              for (final key in [
                'readerScreenPicNumberForLandscape',
                'readerScreenPicNumberForPortrait',
              ]) {
                appdata.settings.setActiveReaderSetting(
                  comicId,
                  sourceKey,
                  key,
                  1,
                );
                widget.onChanged?.call(key);
              }
              appdata.saveData();
            }
            widget.onChanged?.call("readerMode");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: isGalleryMode,
          child: SliderSetting(
            title:
                "The number of pic in screen for landscape (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForLandscape",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("readerScreenPicNumberForLandscape");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: isGalleryMode,
          child: SliderSetting(
            title:
                "The number of pic in screen for portrait (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForPortrait",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              widget.onChanged?.call("readerScreenPicNumberForPortrait");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible:
              isGalleryMode &&
              (settingValue('readerScreenPicNumberForLandscape') > 1 ||
                  settingValue('readerScreenPicNumberForPortrait') > 1),
          child: SwitchSetting(
            title: "Show single image on first page".tl,
            settingKey: "showSingleImageOnFirstPage",
            onChanged: () {
              widget.onChanged?.call("showSingleImageOnFirstPage");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SwitchSetting(
          title: 'Split dual pages'.tl,
          subtitle:
              'Splits dual pages into separate pages in Gallery single-image mode and vertical flow modes. Does not split when displaying multiple images per screen.'
                  .tl,
          settingKey: 'splitDualPage',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('splitDualPage');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: settingValue('splitDualPage') == true,
          child: SwitchSetting(
            title: 'Swap split dual page order'.tl,
            subtitle:
                'Turn this on when the split page order does not match the reading direction'
                    .tl,
            settingKey: 'splitDualPageInvert',
            onChanged: () {
              widget.onChanged?.call('splitDualPageInvert');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SwitchSetting(
          title: 'Limit image width'.tl,
          subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
          settingKey: 'limitImageWidth',
          onChanged: () {
            widget.onChanged?.call('limitImageWidth');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: isVerticalFlowMode,
          child: SliderSetting(
            title: 'Side margins (each side)'.tl,
            settingsIndex: 'readerSideMargin',
            interval: 1,
            min: 0,
            max: 30,
            valueFormatter: (value) => '${value.toInt()}%',
            onChanged: () => widget.onChanged?.call('readerSideMargin'),
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _sectionHeading(context, 'Page Turning and Controls'.tl),
        SwitchSetting(
          title: "Tap to turn Pages".tl,
          settingKey: "enableTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("enableTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Reverse tap to turn Pages".tl,
          settingKey: "reverseTapToTurnPages",
          onChanged: () {
            widget.onChanged?.call("reverseTapToTurnPages");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "One-handed mode".tl,
          subtitle: "Tap anywhere for next page".tl,
          settingKey: "oneHandedMode",
          onChanged: () {
            widget.onChanged?.call("oneHandedMode");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Page animation".tl,
          settingKey: "enablePageAnimation",
          onChanged: () {
            widget.onChanged?.call("enablePageAnimation");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: 'Double tap to zoom'.tl,
          settingKey: 'enableDoubleTapToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableDoubleTapToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        if (App.isAndroid)
          SwitchSetting(
            title: 'Turn page by volume keys'.tl,
            settingKey: 'enableTurnPageByVolumeKey',
            onChanged: () {
              widget.onChanged?.call('enableTurnPageByVolumeKey');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        SliverAnimatedVisibility(
          visible: isContinuousMode,
          child: SliderSetting(
            title: "Mouse scroll speed".tl,
            settingsIndex: "readerScrollSpeed",
            interval: 0.1,
            min: 0.5,
            max: 3,
            onChanged: () {
              widget.onChanged?.call("readerScrollSpeed");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _sectionHeading(context, 'Automatic Reading'.tl),
        SliderSetting(
          title: "Auto page turning interval".tl,
          settingsIndex: "autoPageTurningInterval",
          interval: 1,
          min: 1,
          max: 20,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("autoPageTurningInterval");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: 'Skip unavailable images during automatic reading'.tl,
          settingKey: 'autoReadingSkipUnavailableImages',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('autoReadingSkipUnavailableImages');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        if (settingValue('autoReadingSkipUnavailableImages') == true)
          SliderSetting(
            title: 'Automatic reading image wait time'.tl,
            settingsIndex: 'autoReadingImageWaitSeconds',
            interval: 1,
            min: 1,
            max: 60,
            onChanged: () =>
                widget.onChanged?.call('autoReadingImageWaitSeconds'),
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        if (App.isMobile)
          SwitchSetting(
            title: 'Keep screen on during automatic reading'.tl,
            settingKey: 'autoReadingKeepScreenOn',
            onChanged: () => widget.onChanged?.call('autoReadingKeepScreenOn'),
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        _sectionHeading(context, 'Display and Reading Information'.tl),
        SwitchSetting(
          title: "Show Page Number".tl,
          settingKey: "showPageNumberInReader",
          onChanged: () {
            widget.onChanged?.call("showPageNumberInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Display time & battery info in reader".tl,
          settingKey: "enableClockAndBatteryInfoInReader",
          onChanged: () {
            widget.onChanged?.call("enableClockAndBatteryInfoInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: "Show system status bar".tl,
          settingKey: "showSystemStatusBar",
          onChanged: () {
            widget.onChanged?.call("showSystemStatusBar");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SwitchSetting(
          title: 'Show image pixel dimensions'.tl,
          settingKey: 'showImagePixelDimensions',
          onChanged: () => widget.onChanged?.call('showImagePixelDimensions'),
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        ReaderBrightnessControl(
          enabled: settingValue('readerBrightnessEnabled') == true,
          brightness: settingValue('readerBrightness'),
          onEnabledChanged: (enabled) {
            appdata.settings.setActiveReaderSetting(
              widget.comicId,
              widget.comicSource,
              'readerBrightnessEnabled',
              enabled,
            );
            setState(() {});
            appdata.saveData();
            widget.onChanged?.call('readerBrightnessEnabled');
          },
          onBrightnessChanged: (brightness) {
            appdata.settings.setActiveReaderSetting(
              widget.comicId,
              widget.comicSource,
              'readerBrightness',
              brightness,
            );
            setState(() {});
            widget.onChanged?.call('readerBrightness');
          },
          onBrightnessChangeEnd: (_) {
            appdata.saveData();
          },
        ).toSliver(),
        SwitchSetting(
          title: "E-Ink display refresh".tl,
          subtitle:
              "Flash the screen after page changes to reduce ghosting on E-Ink displays. Only applies to Gallery modes."
                  .tl,
          settingKey: "eInkRefreshEnabled",
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("eInkRefreshEnabled");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: settingValue('eInkRefreshEnabled') == true,
          child: Column(
            children: [
              SliderSetting(
                title: "Refresh flash duration".tl,
                settingsIndex: "eInkRefreshDuration",
                interval: 100,
                min: 100,
                max: 1500,
                valueFormatter: (value) => '${value.toInt()} ms',
                onChanged: () {
                  widget.onChanged?.call("eInkRefreshDuration");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              SliderSetting(
                title: "Refresh interval".tl,
                settingsIndex: "eInkRefreshInterval",
                interval: 1,
                min: 1,
                max: 10,
                valueFormatter: (value) => value.toInt().toString(),
                onChanged: () {
                  widget.onChanged?.call("eInkRefreshInterval");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
              SelectSetting(
                title: "Refresh flash style".tl,
                settingKey: "eInkRefreshStyle",
                optionTranslation: {
                  "black": "Black".tl,
                  "white": "White".tl,
                  "whiteThenBlack": "White then black".tl,
                },
                onChanged: () {
                  widget.onChanged?.call("eInkRefreshStyle");
                },
                comicId: isEnabledSpecificSettings ? widget.comicId : null,
                comicSource: isEnabledSpecificSettings
                    ? widget.comicSource
                    : null,
                useDeviceSettings: useDeviceSpecificSettings,
              ),
            ],
          ),
        ),
        _sectionHeading(context, 'Chapters and Comments'.tl),
        if (comicId == null)
          SwitchSetting(
            title: "Reverse default chapter order".tl,
            settingKey: "reverseChapterOrder",
            onChanged: () {
              widget.onChanged?.call("reverseChapterOrder");
            },
          ).toSliver(),
        SwitchSetting(
          title: "Show Chapter Comments".tl,
          settingKey: "showChapterComments",
          onChanged: () {
            if (settingValue('showChapterComments') != true) {
              appdata.settings.setActiveReaderSetting(
                comicId,
                sourceKey,
                'showChapterCommentsAtEnd',
                false,
              );
              appdata.saveData();
            }
            setState(() {});
            widget.onChanged?.call('showChapterComments');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible:
              isHorizontalGalleryMode &&
              settingValue('showChapterComments') == true,
          child: SwitchSetting(
            title: "Show Comments at Chapter End".tl,
            settingKey: "showChapterCommentsAtEnd",
            onChanged: () {
              widget.onChanged?.call("showChapterCommentsAtEnd");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _sectionHeading(context, 'Image Loading and Processing'.tl),
        SliderSetting(
          title: "Number of images preloaded".tl,
          settingsIndex: "preloadImageCount",
          interval: 1,
          min: 1,
          max: 16,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        CallbackSetting(
          title: "Custom Image Processing".tl,
          callback: () => context.to(() => _CustomImageProcessing()),
          actionTitle: "Edit".tl,
        ).toSliver(),
      ],
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState extends State<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  @override
  void dispose() {
    if (appdata.settings['customImageProcessing'] != current) {
      appdata.settings['customImageProcessing'] = current;
      appdata.saveData();
    }
    super.dispose();
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom Image Processing".tl),
        actions: [
          TextButton(
            style: actionButtonStyle,
            onPressed: () {
              current = defaultCustomImageProcessing;
              appdata.settings['customImageProcessing'] = current;
              resetKey++;
              setState(() {});
            },
            child: Text("Reset".tl),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchSetting(
            title: "Enable".tl,
            settingKey: "enableCustomImageProcessing",
          ),
          Expanded(
            child: Container(
              margin: EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colorScheme.outlineVariant),
              ),
              child: SizedBox.expand(
                child: CodeEditor(
                  key: ValueKey(resetKey),
                  initialValue: appdata.settings['customImageProcessing'],
                  onChanged: (value) {
                    current = value;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
