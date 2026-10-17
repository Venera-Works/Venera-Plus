import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/startup_timing.dart';
import 'package:venera_plus/foundation/translations.dart';

/// Draws a frame before starting initialization. The real app, including its
/// authorization page, is mounted only after local dependencies are ready.
class StartupPage extends StatefulWidget {
  const StartupPage({required this.initialize, required this.child, super.key});

  final Future<void> Function() initialize;
  final Widget child;

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  Future<bool>? _initialization;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      StartupTiming.mark('First loading frame');
      _initialize();
    });
  }

  void _initialize() {
    setState(() {
      _initialization = Future.sync(widget.initialize).then(
        (_) => true,
        onError: (Object error, StackTrace stack) {
          Log.error('Startup', error, stack);
          return false;
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _initialization,
      builder: (context, snapshot) {
        final complete = snapshot.connectionState == ConnectionState.done;
        if (complete && snapshot.data == true) return widget.child;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            scaffoldBackgroundColor: Colors.white,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: Colors.black,
          ),
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/app_icon.png', width: 64, height: 64),
                    const SizedBox(height: 16),
                    const Text('VeneraPlus'),
                    const SizedBox(height: 24),
                    if (complete && snapshot.data == false) ...[
                      Text(
                        'Unable to start the app. Please retry.'.tl,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _initialize,
                        child: Text('Retry'.tl),
                      ),
                    ] else
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
