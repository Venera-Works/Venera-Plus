import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/init.dart';

void main() {
  test(
    'initialization failure releases dependent tasks and permits retry',
    () async {
      final component = _Component();
      final waiting = expectLater(component.ensureInit(), throwsStateError);
      await expectLater(component.init(), throwsStateError);
      await waiting;

      component.fail = false;
      final retried = component.ensureInit();
      await component.init();
      await retried;
      expect(component.calls, 2);
    },
  );
}

class _Component with Init {
  var fail = true;
  var calls = 0;

  @override
  Future<void> doInit() async {
    calls++;
    if (fail) throw StateError('Local initialization failed');
  }
}
