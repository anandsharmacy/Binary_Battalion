import 'package:latlong2/latlong.dart';

/// A trip routed live through OSRM.
///
/// Only the endpoints, the hazard location and the vehicle's position are
/// trip data — geometry, distances, ETAs, km markers and turn
/// instructions all come from the routing engine.
class RouteScenario {
  final String id;
  final String originLabel;
  final String destinationLabel;
  final List<LatLng> waypoints;

  /// Predicted hazard on the route (snapped onto the route at runtime).
  final LatLng? hazardPoint;
  final double hazardHalfSpanM;
  final String hazardLabel;
  final int hazardConfidence;

  /// Earlier, lower-severity caution segment.
  final LatLng? cautionPoint;
  final double cautionHalfSpanM;
  final String cautionLabel;

  /// Vehicle position: metres before the hazard, or a fraction of the route
  /// when there is no hazard.
  final double vehicleBeforeHazardM;
  final double vehicleFraction;

  /// How far along the detour the vehicle is once it follows the reroute.
  final double postRerouteAdvanceM;

  const RouteScenario({
    required this.id,
    required this.originLabel,
    required this.destinationLabel,
    required this.waypoints,
    this.hazardPoint,
    this.hazardHalfSpanM = 1500,
    this.hazardLabel = '',
    this.hazardConfidence = 0,
    this.cautionPoint,
    this.cautionHalfSpanM = 2000,
    this.cautionLabel = '',
    this.vehicleBeforeHazardM = 12000,
    this.vehicleFraction = 0,
    this.postRerouteAdvanceM = 3000,
  });

  LatLng get destination => waypoints.last;
}
