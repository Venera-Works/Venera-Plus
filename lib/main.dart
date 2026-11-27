import 'foundation/app_exit.dart';
import 'components/window_hotkey_scope.dart';
import 'foundation/window_hotkey_controller.dart';
import 'features/local_comics/local_comics.dart';
import 'dart:async';
import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera_plus/app_runtime/app_runtime.dart';
import 'package:venera_plus/app_shell/app_shell.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:window_manager/window_manager.dart';
import 'components/button.dart';
import 'components/gesture.dart';
import 'components/js_ui.dart';
import 'components/message.dart';
import 'components/window_frame.dart';
import 'foundation/app.dart';
import 'foundation/appdata.dart';
import 'foundation/context.dart';
import 'foundation/js_engine.dart';
import 'foundation/startup_timing.dart';
import 'features/sync/sync.dart';

void main(List<String> args) {
  if (args.contains('--headless')) {
    runHeadlessMode(args);
    return;
  }
  if (runWebViewTitleBarWidget(args)) return;
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        StartupTiming.start();
        registerShowMessageHandler((context, message) {
          showToast(message: message, context: context);
        });
        JsEngine.configureUiMessageHandler(JsUiApi());
        if (App.isAndroid) {
          runApp(
            StartupPage(
              initialize: () => init(deferBackgroundTasks: true),
              child: const MyApp(),
            ),
          );
        } else {
          try {
            await init(deferBackgroundTasks: true);
          } catch (error, stack) {
            Log.error('Startup', error, stack);
            runApp(StartupFailureApp(error: error, stack: stack));
            if (App.isDesktop) {
              await windowManager.ensureInitialized();
              await windowManager.setTitleBarStyle(TitleBarStyle.normal);
              await windowManager.setMinimumSize(const Size(500, 400));
              await windowManager.show();
            }
            return;
          }
          runApp(const MyApp());
        }
        if (App.isDesktop) {
          await windowManager.ensureInitialized();
          windowManager.waitUntilReadyToShow().then((_) async {
            await windowManager.setTitleBarStyle(
              TitleBarStyle.hidden,
              windowButtonVisibility: App.isMacOS,
            );
            if (App.isLinux) {
              await windowManager.setBackgroundColor(Colors.transparent);
            }
            await windowManager.setMinimumSize(const Size(500, 600));
            var placement = await WindowPlacement.loadFromFile();
            if (App.isLinux) {
              await windowManager.show();
              await placement.applyToWindow();
            } else {
              await placement.applyToWindow();
              await windowManager.show();
            }

            WindowPlacement.loop();
          });
        }
      },
      (error, stack) {
        Log.error("Unhandled Exception", error, stack);
      },
    );
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  AndroidDownloads? _downloads;
  WindowHotkeyController? _windowHotkey;
  @override
  void initState() {
    if (App.isAndroid) {
      _downloads = AndroidDownloads(manager: LocalManager())..start();
    }
    if (App.isWindows) {
      _windowHotkey = createWindowsHotkeyController();
      unawaited(_windowHotkey!.start());
    }
    configureAppExitPreparation(() async {
      final release = await _windowHotkey?.hold();
      try {
        await prepareReadingDataForExit();
      } finally {
        release?.call();
      }
    });
    App.registerForceRebuild(forceRebuild);
    isAuthPageActive = appdata.settings['authorizationRequired'] == true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      StartupTiming.mark('Local app ready');
      startBackgroundTasks();
      checkUpdates();
      if (!appdata.settings['authorizationRequired']) startAppLinkHandlers();
    });
    super.initState();
  }

  late bool isAuthPageActive;

  OverlayEntry? hideContentOverlay;

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted && appdata.settings['language'] == 'system') {
      forceRebuild();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_downloads?.close());
      unawaited(shutdownRemoteComicLibraryRuntime());
    }
    if (state == AppLifecycleState.resumed) {
      DataSync().checkForAutomaticSync();
      checkRemoteComicLibrariesForAutomaticSync();
    }
    if (!App.isMobile || !appdata.settings['authorizationRequired']) {
      return;
    }
    if (state == AppLifecycleState.inactive && hideContentOverlay == null) {
      hideContentOverlay = OverlayEntry(
        builder: (context) {
          return Positioned.fill(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: App.rootContext.colorScheme.surface,
            ),
          );
        },
      );
      Overlay.of(App.rootContext).insert(hideContentOverlay!);
    } else if (hideContentOverlay != null &&
        state == AppLifecycleState.resumed) {
      hideContentOverlay!.remove();
      hideContentOverlay = null;
    }
    if (state == AppLifecycleState.hidden &&
        !isAuthPageActive &&
        !IO.isSelectingFiles) {
      isAuthPageActive = true;
      App.rootContext.to(
        () => AuthPage(
          onSuccessfulAuth: () {
            App.rootContext.pop();
            isAuthPageActive = false;
          },
        ),
      );
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    unawaited(_downloads?.close());
    unawaited(_windowHotkey?.close());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(shutdownRemoteComicLibraryRuntime());
    super.dispose();
  }

  void forceRebuild() {
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
    setState(() {});
  }

  Color translateColorSetting() {
    return switch (appdata.settings['color']) {
      'red' => Colors.red,
      'pink' => Colors.pink,
      'purple' => Colors.purple,
      'green' => Colors.green,
      'orange' => Colors.orange,
      'blue' => Colors.blue,
      'yellow' => Colors.yellow,
      'cyan' => Colors.cyan,
      _ => Colors.blue,
    };
  }

  ThemeData getTheme(
    Color primary,
    Color? secondary,
    Color? tertiary,
    Brightness brightness,
  ) {
    String? font;
    List<String>? fallback;
    if (App.isLinux || App.isWindows) {
      font = 'Noto Sans CJK';
      fallback = [
        'Segoe UI',
        'Noto Sans SC',
        'Noto Sans TC',
        'Noto Sans',
        'Microsoft YaHei',
        'PingFang SC',
        'Arial',
        'sans-serif',
      ];
    }
    final colorScheme = SeedColorScheme.fromSeeds(
      primaryKey: primary,
      secondaryKey: secondary,
      tertiaryKey: tertiary,
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    );
    const clickableStyle = ButtonStyle(
      mouseCursor: WidgetStateMouseCursor.clickable,
    );
    final buttonStyle = actionButtonStyle.copyWith(
      mouseCursor: WidgetStateMouseCursor.clickable,
      textStyle: WidgetStatePropertyAll(
        actionButtonStyle.textStyle
            ?.resolve({})
            ?.copyWith(fontFamily: font, fontFamilyFallback: fallback),
      ),
    );
    return ThemeData(
      colorScheme: colorScheme,
      fontFamily: font,
      fontFamilyFallback: fallback,
      buttonTheme: const ButtonThemeData(alignedDropdown: true),
      filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
      elevatedButtonTheme: const ElevatedButtonThemeData(style: clickableStyle),
      outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
      textButtonTheme: TextButtonThemeData(style: buttonStyle),
      iconButtonTheme: const IconButtonThemeData(style: clickableStyle),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        // A stateful default border lets fields opt out with InputBorder.none.
        border: WidgetStateInputBorder.resolveWith((states) {
          final focused = states.contains(WidgetState.focused);
          final color = switch (states) {
            _ when states.contains(WidgetState.disabled) =>
              colorScheme.onSurface.withValues(alpha: 0.12),
            _ when states.contains(WidgetState.error) => colorScheme.error,
            _ when focused => colorScheme.primary,
            _ => colorScheme.outlineVariant,
          };
          return OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: color, width: focused ? 2 : 1),
          );
        }),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: brightness == Brightness.dark
              ? BorderSide(color: colorScheme.outlineVariant)
              : BorderSide.none,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerHigh,
        elevation: 4,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(
              alpha: brightness == Brightness.dark ? 1.0 : 0.6,
            ),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      cardTheme: CardThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (appdata.settings['authorizationRequired']) {
      home = AuthPage(
        onSuccessfulAuth: () {
          App.rootContext.toReplacement(() => const MainPage());
          isAuthPageActive = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) startAppLinkHandlers();
          });
        },
      );
    } else {
      home = const MainPage();
    }
    return DynamicColorBuilder(
      builder: (light, dark) {
        Color? primary, secondary, tertiary;
        if (appdata.settings['color'] != 'system' ||
            light == null ||
            dark == null) {
          primary = translateColorSetting();
        } else {
          primary = light.primary;
          secondary = light.secondary;
          tertiary = light.tertiary;
        }
        return MaterialApp(
          title: "VeneraPlus",
          home: home,
          debugShowCheckedModeBanner: false,
          theme: getTheme(primary, secondary, tertiary, Brightness.light),
          navigatorKey: App.rootNavigatorKey,
          darkTheme: getTheme(primary, secondary, tertiary, Brightness.dark),
          themeMode: switch (appdata.settings['theme_mode']) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          },
          color: Colors.transparent,
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          locale: App.locale,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('zh', 'TW'),
            Locale('en', 'US'),
            Locale('en'),
          ],
          builder: (context, widget) {
            if (_windowHotkey case final controller?) {
              widget = WindowHotkeyScope(
                controller: controller,
                child: widget!,
              );
            }
            ErrorWidget.builder = (details) {
              Log.error(
                "Unhandled Exception",
                "${details.exception}\n${details.stack}",
              );
              return Material(
                child: Center(child: Text(details.exception.toString())),
              );
            };
            if (widget != null) {
              /// 如果无法检测到状态栏高度设定指定高度
              /// https://github.com/flutter/flutter/issues/161086
              var isPaddingCheckError =
                  MediaQuery.of(context).viewPadding.top <= 0 ||
                  MediaQuery.of(context).viewPadding.top > 200;

              if (isPaddingCheckError && Platform.isAndroid) {
                widget = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewPadding: const EdgeInsets.only(top: 15, bottom: 15),
                    padding: const EdgeInsets.only(top: 15, bottom: 15),
                  ),
                  child: widget,
                );
              }

              widget = OverlayWidget(widget);
              if (App.isDesktop) {
                widget = Shortcuts(
                  shortcuts: {
                    LogicalKeySet(LogicalKeyboardKey.escape):
                        VoidCallbackIntent(App.maybePop),
                  },
                  child: MouseBackDetector(
                    onTapDown: App.maybePop,
                    child: WindowFrame(
                      widget,
                      debugAction: reloadComicSourcesForDebug,
                    ),
                  ),
                );
              }
              return _SystemUiProvider(
                Material(
                  color: App.isLinux ? Colors.transparent : null,
                  child: widget,
                ),
              );
            }
            throw ('widget is null');
          },
        );
      },
    );
  }
}

class _SystemUiProvider extends StatelessWidget {
  const _SystemUiProvider(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var brightness = Theme.of(context).brightness;
    SystemUiOverlayStyle systemUiStyle;
    if (brightness == Brightness.light) {
      systemUiStyle = SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      );
    } else {
      systemUiStyle = SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiStyle,
      child: child,
    );
  }
}
