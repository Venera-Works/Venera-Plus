import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  group('One-handed mode settings', () {
    test('oneHandedMode setting defaults to false', () {
      expect(appdata.settings['oneHandedMode'], isFalse);
    });
  });
}
