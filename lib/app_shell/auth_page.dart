import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_plus/foundation/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (SchedulerBinding.instance.lifecycleState !=
          AppLifecycleState.paused) {
        _authenticate();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.security, size: 36),
              const SizedBox(height: 16),
              Text("Authentication Required".tl),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _authenticating ? null : _authenticate,
                child: Text(_error == null ? 'Continue'.tl : 'Retry'.tl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _authenticate() async {
    if (!mounted || _authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });

    var authorized = false;
    String? failure;
    try {
      authorized = await LocalAuthentication().authenticate(
        localizedReason: 'Please authenticate to continue'.tl,
      );
    } on LocalAuthException catch (error) {
      failure = switch (error.code) {
        LocalAuthExceptionCode.userCanceled => null,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled =>
          'Set up device authentication and try again.'.tl,
        LocalAuthExceptionCode.noBiometricHardware =>
          'Biometrics not supported'.tl,
        LocalAuthExceptionCode.temporaryLockout =>
          'Too many attempts. Try again later.'.tl,
        LocalAuthExceptionCode.biometricLockout =>
          'Unlock your device with its passcode and try again.'.tl,
        LocalAuthExceptionCode.timeout => 'Authentication timed out.'.tl,
        LocalAuthExceptionCode.uiUnavailable ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
          'Device authentication is unavailable.'.tl,
        _ => error.description ?? 'Authentication failed.'.tl,
      };
    } on PlatformException catch (error) {
      failure = error.message ?? 'Authentication failed.'.tl;
    } on MissingPluginException {
      failure = 'Device authentication is unavailable.'.tl;
    } finally {
      if (mounted) {
        setState(() {
          _authenticating = false;
          _error = failure;
        });
      }
    }
    if (mounted && authorized) {
      widget.onSuccessfulAuth?.call();
    }
  }
}
