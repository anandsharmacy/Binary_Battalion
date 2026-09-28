import '../domain/rider.dart';
import '../domain/rider_data_repository.dart';

/// Rider data source used until a backend-backed [RiderDataRepository] exists.
/// It has no records, so the rider panel shows "Rider profile unavailable".
class NoRiderDataSource implements RiderDataRepository {
  const NoRiderDataSource();

  @override
  Future<List<Rider>> fetchRiders() async => const [];

  @override
  Future<Rider?> riderForUser({required String userId, String? officerId, String? email}) async => null;

  @override
  Future<RiderRoute?> assignedRoute(String riderId) async => null;

  @override
  Future<RouteIncident?> incidentOnRoute(String routeId) async => null;
}
