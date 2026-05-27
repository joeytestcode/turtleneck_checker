import 'package:flutter_test/flutter_test.dart';
import 'package:turtleneck_checker/main.dart';

void main() {
  group('calculateCva', () {
    test('measures the acute angle between the C7 horizontal and C7-tragus line', () {
      const c7 = AnalysisPoint(x: 0.40, y: 0.70, label: 'C7');
      const tragus = AnalysisPoint(x: 0.60, y: 0.50, label: 'Tragus');

      expect(calculateCva(tragus, c7), 45.0);
    });

    test('returns the same CVA for mirrored left-facing and right-facing profiles', () {
      const c7 = AnalysisPoint(x: 0.60, y: 0.70, label: 'C7');
      const tragus = AnalysisPoint(x: 0.40, y: 0.50, label: 'Tragus');

      expect(calculateCva(tragus, c7), 45.0);
    });

    test('is zero when the tragus is on the same horizontal line as C7', () {
      const c7 = AnalysisPoint(x: 0.35, y: 0.55, label: 'C7');
      const tragus = AnalysisPoint(x: 0.65, y: 0.55, label: 'Tragus');

      expect(calculateCva(tragus, c7), 0.0);
    });
  });
}