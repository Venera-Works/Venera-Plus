import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';

void main() {
  group('normalizeSyncDeviceName', () {
    test('replaces separators and control characters within one segment', () {
      final name = normalizeSyncDeviceName('Pixel/7\\Desk\nName');

      expect(name, 'Pixel_7_Desk_Name');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains('\\')));
      expect(name, isNot(contains('\n')));
      expect(
        normalizeSyncDeviceName('room%2foutside#fragment'),
        'room_2foutside_fragment',
      );
    });

    test('removes trailing dots and spaces', () {
      expect(normalizeSyncDeviceName('Office.. '), 'Office');
    });

    test('rejects empty and dot path segments', () {
      for (final value in ['', ' ', '.', '..', '...']) {
        expect(() => normalizeSyncDeviceName(value), throwsFormatException);
      }
    });

    test('prefixes filesystem-reserved device names', () {
      expect(normalizeSyncDeviceName('CON'), '_CON');
    });
  });
}
