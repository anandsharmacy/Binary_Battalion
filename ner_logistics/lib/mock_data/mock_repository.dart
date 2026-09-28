import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mock_deliveries.dart';
import 'mock_officers.dart' as officer_mocks;
import 'models.dart';

/// Shared in-memory app state (offline queue, assignments) for screens that
/// need to coordinate. It starts empty; there is no sample data.
class MockAppState {
  final Officer activeOfficer;
  final TripPhase tripPhase;
  final bool postReroute;
  final bool riskUpgraded;
  final bool isOffline;
  final List<DeliveryAssignment> riderAssignments;
  final List<ProofOfDelivery> queuedProofs;
  final List<RiderIssueReport> queuedIssues;
  final List<RiderLocationPing> queuedLocationPings;

  const MockAppState({
    required this.activeOfficer,
    required this.tripPhase,
    required this.postReroute,
    required this.riskUpgraded,
    required this.isOffline,
    required this.riderAssignments,
    required this.queuedProofs,
    required this.queuedIssues,
    required this.queuedLocationPings,
  });

  factory MockAppState.initial() => MockAppState(
      activeOfficer: officer_mocks.fieldOfficer,
        tripPhase: TripPhase.active,
        postReroute: false,
        riskUpgraded: false,
        isOffline: false,
        riderAssignments: List.unmodifiable(mockRiderDeliveries),
        queuedProofs: const [],
        queuedIssues: const [],
        queuedLocationPings: const [],
      );

  DeliveryAssignment? get activeRiderAssignment => riderAssignments
      .cast<DeliveryAssignment?>()
      .firstWhere(
        (assignment) => assignment!.status != RiderTripStatus.completed &&
            assignment.status != RiderTripStatus.cancelled,
        orElse: () => null,
      );

  int get riderQueueCount => queuedProofs.length +
      queuedIssues.length +
      queuedLocationPings.length;

  MockAppState copyWith({
    TripPhase? tripPhase,
    bool? postReroute,
    bool? riskUpgraded,
    bool? isOffline,
    List<DeliveryAssignment>? riderAssignments,
    List<ProofOfDelivery>? queuedProofs,
    List<RiderIssueReport>? queuedIssues,
    List<RiderLocationPing>? queuedLocationPings,
  }) {
    return MockAppState(
      activeOfficer: activeOfficer,
      tripPhase: tripPhase ?? this.tripPhase,
      postReroute: postReroute ?? this.postReroute,
      riskUpgraded: riskUpgraded ?? this.riskUpgraded,
      isOffline: isOffline ?? this.isOffline,
      riderAssignments: riderAssignments ?? this.riderAssignments,
      queuedProofs: queuedProofs ?? this.queuedProofs,
      queuedIssues: queuedIssues ?? this.queuedIssues,
      queuedLocationPings: queuedLocationPings ?? this.queuedLocationPings,
    );
  }
}

class MockRepository extends StateNotifier<MockAppState> {
  MockRepository([MockAppState? initial]) : super(initial ?? MockAppState.initial());

  void setOffline(bool value) {
    state = state.copyWith(isOffline: value);
  }

  void toggleOffline() {
    setOffline(!state.isOffline);
  }

  void triggerRisk() {
    if (state.postReroute || state.tripPhase != TripPhase.active) return;
    state = state.copyWith(
      tripPhase: TripPhase.interrupt,
      riskUpgraded: false,
    );
  }

  void setTripPhase(TripPhase phase) {
    state = state.copyWith(tripPhase: phase);
  }

  void dismissRisk() {
    state = state.copyWith(
      tripPhase: TripPhase.active,
      riskUpgraded: true,
    );
  }

  void completeReroute() {
    state = state.copyWith(
      tripPhase: TripPhase.active,
      postReroute: true,
      riskUpgraded: false,
    );
  }

  void decideAssignment(String assignmentId, AssignmentDecision decision) {
    final assignments = state.riderAssignments.map((assignment) {
      if (assignment.id != assignmentId) return assignment;
      return assignment.copyWith(
        decision: decision,
        status: decision == AssignmentDecision.accepted
            ? RiderTripStatus.accepted
            : assignment.status,
      );
    }).toList(growable: false);
    state = state.copyWith(riderAssignments: List.unmodifiable(assignments));
  }

  void setRiderTripStatus(RiderTripStatus status) {
    final active = state.activeRiderAssignment;
    if (active == null) return;
    final assignments = state.riderAssignments.map((assignment) {
      return assignment.id == active.id
          ? assignment.copyWith(status: status)
          : assignment;
    }).toList(growable: false);
    state = state.copyWith(riderAssignments: List.unmodifiable(assignments));
  }

  void queueProof(ProofOfDelivery proof) {
    state = state.copyWith(
      queuedProofs: List.unmodifiable([...state.queuedProofs, proof]),
    );
  }

  void queueIssue(RiderIssueReport issue) {
    state = state.copyWith(
      queuedIssues: List.unmodifiable([...state.queuedIssues, issue]),
    );
  }

  void queueLocationPing(RiderLocationPing ping) {
    state = state.copyWith(
      queuedLocationPings:
          List.unmodifiable([...state.queuedLocationPings, ping]),
    );
  }

  void markRiderProofSubmitted() {
    final active = state.activeRiderAssignment;
    if (active == null) return;
    final assignments = state.riderAssignments.map((assignment) {
      return assignment.id == active.id
          ? assignment.copyWith(proofSubmitted: true)
          : assignment;
    }).toList(growable: false);
    state = state.copyWith(riderAssignments: List.unmodifiable(assignments));
  }
}

final mockRepositoryProvider =
    StateNotifierProvider<MockRepository, MockAppState>(
  (ref) => MockRepository(),
);
