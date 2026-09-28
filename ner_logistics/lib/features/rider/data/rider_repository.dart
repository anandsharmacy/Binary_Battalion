import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../domain/rider_context.dart';
import '../domain/rider_location_point.dart';

/// Rider-side Supabase access. Everything goes through SECURITY DEFINER RPCs
/// defined in `supabase/migrations/20260912000002_rider_tracking.sql` so the
/// role check and idempotency live server-side.
class RiderRepository {
  RiderRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 15);

  /// Uploads a batch (oldest first). Returns the number of points accepted.
  /// Safe to retry: `client_id` de-duplicates on the server.
  Future<int> syncLocations(List<RiderLocationPoint> points) async {
    if (points.isEmpty) return 0;
    final res = await _client
        .rpc('sync_rider_locations', params: {
          'p_points': points.map((p) => p.toRpcJson()).toList(),
        })
        .timeout(_timeout);
    return (res as num?)?.toInt() ?? points.length;
  }

  Future<void> setDuty(bool onDuty, {String? vehicleRegistration, String? vehicleType}) async {
    await _client.rpc('set_rider_duty', params: {
      'p_on_duty': onDuty,
      if (vehicleRegistration != null) 'p_vehicle_registration': vehicleRegistration,
      if (vehicleType != null) 'p_vehicle_type': vehicleType,
    }).timeout(_timeout);
  }

  /// Accept or decline an assignment. Declining needs a reason and hands the
  /// shipment back to the officer. The database enforces that it is yours and
  /// still waiting for an answer.
  Future<void> respondToShipment(String id, bool accept, {String? reason}) async {
    await _client.rpc('respond_to_shipment', params: {
      'p_id': id,
      'p_accept': accept,
      if (reason != null) 'p_reason': reason,
    }).timeout(_timeout);
  }

  /// Move a shipment forward: `in_transit` (start trip), `arrived`, `completed`.
  /// The database rejects any other jump.
  Future<void> advanceShipment(String id, String status) async {
    await _client.rpc('advance_shipment', params: {
      'p_id': id,
      'p_status': status,
    }).timeout(_timeout);
  }

  Future<RiderContext?> fetchContext() async {
    final res = await _client.rpc('get_my_rider_context').timeout(_timeout);
    if (res == null) return null;
    return RiderContext.fromJson(Map<String, dynamic>.from(res as Map));
  }
}

final riderRepositoryProvider = Provider<RiderRepository>(
  (ref) => RiderRepository(ref.watch(supabaseClientProvider)),
);

/// Rider profile, vehicle and assigned shipments from Supabase.
/// Refresh with `ref.invalidate(riderContextProvider)`.
final riderContextProvider = FutureProvider<RiderContext?>(
  (ref) => ref.watch(riderRepositoryProvider).fetchContext(),
);

/// Watches this rider's shipment rows and refreshes [riderContextProvider] on
/// every change, so a new assignment shows up without pulling to refresh.
/// Watch it from the rider shell to keep it alive. (A reassignment away from
/// this rider produces no event, so the shell also refreshes on a timer.)
final riderShipmentSyncProvider = StreamProvider.autoDispose<void>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final uid = client.auth.currentUser?.id;
  if (uid == null) return const Stream<void>.empty();
  return client
      .from('shipments')
      .stream(primaryKey: ['id'])
      .eq('rider_id', uid)
      .map((_) => ref.invalidate(riderContextProvider));
});
