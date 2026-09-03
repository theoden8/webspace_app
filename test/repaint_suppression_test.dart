import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/repaint_suppression.dart';

void main() {
  setUp(RepaintSuppression.reset);
  tearDown(RepaintSuppression.reset);

  group('RepaintSuppression', () {
    test('suppresses nothing by default', () {
      expect(RepaintSuppression.suppresses('resume'), isFalse);
      expect(RepaintSuppression.triggers, isEmpty);
    });

    test('drops exactly the named triggers', () {
      RepaintSuppression.setFromSpec('resume,metrics-resume');
      expect(RepaintSuppression.suppresses('resume'), isTrue);
      expect(RepaintSuppression.suppresses('metrics-resume'), isTrue);
      expect(RepaintSuppression.suppresses('reload'), isFalse,
          reason: 'an unnamed trigger must keep working, or the scenario '
              'proves nothing about the one under test');
    });

    test('tolerates spacing and empty entries in the spec', () {
      RepaintSuppression.setFromSpec(' resume , , metrics-resume ');
      expect(RepaintSuppression.triggers, {'resume', 'metrics-resume'});
    });

    test('an absent or blank spec suppresses nothing', () {
      RepaintSuppression.setFromSpec('resume');
      RepaintSuppression.setFromSpec(null);
      expect(RepaintSuppression.triggers, isEmpty);
      RepaintSuppression.setFromSpec('   ');
      expect(RepaintSuppression.triggers, isEmpty);
    });
  });
}
