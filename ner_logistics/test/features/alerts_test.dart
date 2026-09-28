import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/features/alerts/alerts_repository.dart';
import 'package:ner_logistics/mock_data/models.dart';

void main() {
  test('alertFromRow maps a public.alerts row', () {
    final a = alertFromRow({
      'id': 'a1', 'title': 'Landslide', 'description': null, 'severity': 'critical',
      'status': 'acknowledged', 'source': 'rule', 'incident_id': 'i1',
      'created_at': '2026-09-27T10:00:00Z',
    });
    expect(a.severity, AlertSeverity.critical);
    expect(a.status, 'acknowledged');
    expect(a.description, '');
    expect(a.distance, 'Source: Field report');
    expect(a.incidentId, 'i1');
    expect(alertFromRow({'id': 'x', 'severity': 'bogus'}).severity, AlertSeverity.info);
  });
}
