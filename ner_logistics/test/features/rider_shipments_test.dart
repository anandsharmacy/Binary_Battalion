import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/features/rider/domain/rider_context.dart';

Map<String, dynamic> _shipment(String id, String status, {String number = 'SHP-1'}) => {
      'id': id,
      'shipment_number': number,
      'status': status,
      'risk_level': 'medium',
      'cargo_description': 'Medical kits',
      'origin': 'Golaghat depot',
      'destination': 'Bokakhat PHC',
      'assigned_at': '2026-09-29T08:00:00Z',
    };

RiderContext _ctx(List<Map<String, dynamic>> shipments, {String? active}) => RiderContext.fromJson({
      'profile': {'full_name': 'Rahul'},
      'rider': {'is_on_duty': true, 'active_shipment_id': active},
      'shipments': shipments,
    });

void main() {
  test('parses the assignment lifecycle from get_my_rider_context', () {
    final s = RiderShipment.fromJson(_shipment('a', 'assigned')..['accepted_at'] = '2026-09-29T08:05:00Z');
    expect(s.isPending, isTrue);
    expect(s.assignedAt, DateTime.utc(2026, 9, 29, 8));
    expect(s.acceptedAt, DateTime.utc(2026, 9, 29, 8, 5));
    expect(s.startedAt, isNull);
    expect(s.statusLabel, 'Awaiting your response');
  });

  test('status helpers cover the whole flow', () {
    expect(RiderShipment.fromJson(_shipment('a', 'accepted')).isAccepted, isTrue);
    for (final st in ['in_transit', 'on_schedule', 'delayed', 'at_risk']) {
      expect(RiderShipment.fromJson(_shipment('a', st)).isInTransit, isTrue, reason: st);
    }
    expect(RiderShipment.fromJson(_shipment('a', 'arrived')).isArrived, isTrue);
    expect(RiderShipment.fromJson(_shipment('a', 'in_transit')).isPending, isFalse);
  });

  test('pending lists only unanswered assignments', () {
    final ctx = _ctx([_shipment('a', 'assigned'), _shipment('b', 'accepted'), _shipment('c', 'assigned')]);
    expect(ctx.pending.map((s) => s.id), ['a', 'c']);
  });

  test('trip shipment prefers in transit, then arrived, then accepted; never pending', () {
    expect(_ctx([_shipment('p', 'assigned')]).tripShipment, isNull);
    expect(_ctx([_shipment('p', 'assigned'), _shipment('acc', 'accepted')]).tripShipment?.id, 'acc');
    expect(_ctx([_shipment('acc', 'accepted'), _shipment('arr', 'arrived')]).tripShipment?.id, 'arr');
    expect(_ctx([_shipment('arr', 'arrived'), _shipment('go', 'in_transit'), _shipment('acc', 'accepted')]).tripShipment?.id, 'go');
  });

  test('location pings never attach to an assignment the rider has not accepted', () {
    // The rider profile may still point at a shipment that was reassigned back to "assigned".
    final ctx = _ctx([_shipment('p', 'assigned'), _shipment('go', 'in_transit')], active: 'p');
    expect(ctx.activeShipment?.id, 'go');
    expect(_ctx([_shipment('p', 'assigned')]).activeShipment, isNull);
    expect(_ctx([_shipment('acc', 'accepted'), _shipment('go', 'in_transit')], active: 'acc').activeShipment?.id, 'acc');
  });
}
