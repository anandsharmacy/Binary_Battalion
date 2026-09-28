// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/mock_data/mock_repository.dart';
import 'package:ner_logistics/mock_data/models.dart';

import 'fixtures/sample_data.dart';

void main() {
  test('risk flow updates shared local state', () {
    final repository = MockRepository();

    repository.triggerRisk();
    expect(repository.state.tripPhase, TripPhase.interrupt);

    repository.dismissRisk();
    expect(repository.state.tripPhase, TripPhase.active);
    expect(repository.state.riskUpgraded, isTrue);

    repository.setTripPhase(TripPhase.calculating);
    repository.completeReroute();
    expect(repository.state.postReroute, isTrue);
    expect(repository.state.riskUpgraded, isFalse);
  });

  test('rider assignment and proof actions update shared state', () {
    final repository =
        MockRepository(MockAppState.initial().copyWith(riderAssignments: sampleDeliveries));

    repository.decideAssignment('ASN-4828', AssignmentDecision.accepted);
    expect(repository.state.riderAssignments.last.decision,
        AssignmentDecision.accepted);

    repository.setRiderTripStatus(RiderTripStatus.paused);
    expect(repository.state.activeRiderAssignment?.status,
        RiderTripStatus.paused);

    repository.queueProof(ProofOfDelivery(
      id: 'POD-TEST',
      type: DeliveryProofType.photo,
      recipient: 'Test recipient',
      timestamp: DateTime(2026, 9, 12),
    ));
    expect(repository.state.riderQueueCount, 1);
  });
}
