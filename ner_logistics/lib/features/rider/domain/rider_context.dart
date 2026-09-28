/// Rider dashboard context returned by `public.get_my_rider_context()`.
class RiderContext {
  final String? fullName;
  final String? officerId;
  final String? phone;
  final String? district;
  final String? vehicleRegistration;
  final String? vehicleType;
  final double? capacityKg;
  final String? emergencyContact;
  final bool isOnDuty;
  final String? activeShipmentId;
  final List<RiderShipment> shipments;

  const RiderContext({
    this.fullName,
    this.officerId,
    this.phone,
    this.district,
    this.vehicleRegistration,
    this.vehicleType,
    this.capacityKg,
    this.emergencyContact,
    this.isOnDuty = false,
    this.activeShipmentId,
    this.shipments = const [],
  });

  /// Assignments waiting for the rider's accept or decline.
  List<RiderShipment> get pending => shipments.where((s) => s.isPending).toList(growable: false);

  /// The shipment the rider is working on: one in transit, else one just
  /// arrived (waiting to be completed), else the next accepted one.
  RiderShipment? get tripShipment {
    for (final want in [
      (RiderShipment s) => s.isInTransit,
      (RiderShipment s) => s.isArrived,
      (RiderShipment s) => s.isAccepted,
    ]) {
      for (final s in shipments) {
        if (want(s)) return s;
      }
    }
    return null;
  }

  /// The shipment location pings should be attached to: the explicitly
  /// active one, else the trip shipment. Never one still waiting for an
  /// answer, since the rider has not agreed to carry it yet.
  RiderShipment? get activeShipment {
    for (final s in shipments) {
      if (s.id == activeShipmentId && !s.isPending) return s;
    }
    return tripShipment;
  }

  factory RiderContext.fromJson(Map<String, dynamic> j) {
    final profile = (j['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rider = (j['rider'] as Map?)?.cast<String, dynamic>() ?? const {};
    final shipments = (j['shipments'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => RiderShipment.fromJson(m.cast<String, dynamic>()))
        .toList();
    return RiderContext(
      fullName: profile['full_name'] as String?,
      officerId: profile['officer_id'] as String?,
      phone: (rider['phone'] ?? profile['phone']) as String?,
      district: j['district'] as String?,
      vehicleRegistration: rider['vehicle_registration'] as String?,
      vehicleType: rider['vehicle_type'] as String?,
      capacityKg: (rider['capacity_kg'] as num?)?.toDouble(),
      emergencyContact: rider['emergency_contact'] as String?,
      isOnDuty: rider['is_on_duty'] == true,
      activeShipmentId: rider['active_shipment_id'] as String?,
      shipments: shipments,
    );
  }

  RiderContext copyWith({bool? isOnDuty}) => RiderContext(
        fullName: fullName,
        officerId: officerId,
        phone: phone,
        district: district,
        vehicleRegistration: vehicleRegistration,
        vehicleType: vehicleType,
        capacityKg: capacityKg,
        emergencyContact: emergencyContact,
        isOnDuty: isOnDuty ?? this.isOnDuty,
        activeShipmentId: activeShipmentId,
        shipments: shipments,
      );
}

class RiderShipment {
  final String id;
  final String shipmentNumber;
  final String status;
  final String? riskLevel;
  final String? cargoDescription;
  final double? cargoWeightKg;
  final String? origin;
  final String? destination;
  final double? destinationLat;
  final double? destinationLng;
  final String? routeNumber;
  final DateTime? estimatedArrival;
  final String? delayDescription;
  final String? currentLocationText;
  final DateTime? assignedAt;
  final DateTime? acceptedAt;
  final DateTime? startedAt;
  final DateTime? arrivedAt;

  const RiderShipment({
    required this.id,
    required this.shipmentNumber,
    required this.status,
    this.riskLevel,
    this.cargoDescription,
    this.cargoWeightKg,
    this.origin,
    this.destination,
    this.destinationLat,
    this.destinationLng,
    this.routeNumber,
    this.estimatedArrival,
    this.delayDescription,
    this.currentLocationText,
    this.assignedAt,
    this.acceptedAt,
    this.startedAt,
    this.arrivedAt,
  });

  factory RiderShipment.fromJson(Map<String, dynamic> j) => RiderShipment(
        id: j['id'] as String,
        shipmentNumber: (j['shipment_number'] as String?) ?? '—',
        status: (j['status'] as String?) ?? 'scheduled',
        riskLevel: j['risk_level'] as String?,
        cargoDescription: j['cargo_description'] as String?,
        cargoWeightKg: (j['cargo_weight_kg'] as num?)?.toDouble(),
        origin: j['origin'] as String?,
        destination: j['destination'] as String?,
        destinationLat: (j['destination_lat'] as num?)?.toDouble(),
        destinationLng: (j['destination_lng'] as num?)?.toDouble(),
        routeNumber: j['route_number'] as String?,
        estimatedArrival: j['estimated_arrival'] == null
            ? null
            : DateTime.tryParse(j['estimated_arrival'] as String),
        delayDescription: j['delay_description'] as String?,
        currentLocationText: j['current_location_text'] as String?,
        assignedAt: _time(j['assigned_at']),
        acceptedAt: _time(j['accepted_at']),
        startedAt: _time(j['started_at']),
        arrivedAt: _time(j['arrived_at']),
      );

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

  /// Waiting for the rider to accept or decline.
  bool get isPending => status == 'assigned';

  /// Accepted, trip not started yet.
  bool get isAccepted => status == 'accepted';

  /// Rider is on the way (the officer may also flag it delayed / at risk).
  bool get isInTransit => const {'in_transit', 'on_schedule', 'delayed', 'at_risk'}.contains(status);

  /// Reached the destination; the rider still has to complete the delivery.
  bool get isArrived => status == 'arrived';


  String get statusLabel => switch (status) {
        'assigned' => 'Awaiting your response',
        'in_transit' => 'In transit',
        'at_risk' => 'At risk',
        _ => status.isEmpty ? '—' : '${status[0].toUpperCase()}${status.substring(1)}',
      };
}
