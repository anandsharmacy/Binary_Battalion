// Sample records for tests only. These used to ship in the app as demo data;
// the app now starts with no records, so tests supply their own.
import 'package:latlong2/latlong.dart';
import 'package:ner_logistics/features/tracking/domain/live_rider.dart';
import 'package:ner_logistics/mock_data/models.dart';
import 'package:ner_logistics/shared/map/map_models.dart';
import 'package:ner_logistics/shared/map/ner_geo.dart';

const List<Incident> sampleIncidents = [
  Incident(
    id: 'INC-2026-041',
    type: IncidentType.flood,
    typeLabel: 'Flash Flood',
    location: 'Barpeta',
    route: 'NH-27',
    severity: Priority.critical,
    reporter: 'Citizen SMS',
    time: '8 min ago',
    verified: false,
    assignedOfficer: '—',
    statusLabel: 'Pending',
  ),
  Incident(
    id: 'INC-2026-042',
    type: IncidentType.roadBlockage,
    typeLabel: 'Convoy At Risk',
    location: 'NH-2 Zone',
    route: 'NH-2',
    severity: Priority.high,
    reporter: 'Fleet system',
    time: '18 min ago',
    verified: false,
    assignedOfficer: '—',
    statusLabel: 'Pending',
  ),
  Incident(
    id: 'INC-2026-043',
    type: IncidentType.infraDamage,
    typeLabel: 'Bridge Damage',
    location: 'Tawang',
    route: 'NH-13',
    severity: Priority.critical,
    reporter: 'FO D. Wangmo',
    time: '40 min ago',
    verified: true,
    assignedOfficer: 'Response Team B',
    statusLabel: 'Escalated',
  ),
  Incident(
    id: 'INC-2026-044',
    type: IncidentType.landslide,
    typeLabel: 'Landslide',
    location: 'NH-306 Km 54',
    route: 'NH-306',
    severity: Priority.high,
    reporter: 'FO K. Rabha',
    time: '1 hr ago',
    verified: true,
    assignedOfficer: 'K. Rabha',
    statusLabel: 'Active',
  ),
  Incident(
    id: 'INC-2026-045',
    type: IncidentType.roadBlockage,
    typeLabel: 'Road Blockage',
    location: 'NH-6 Km 120',
    route: 'NH-6',
    severity: Priority.medium,
    reporter: 'Fleet system',
    time: '1 hr 20 min ago',
    verified: true,
    assignedOfficer: 'A. Das',
    statusLabel: 'Active',
  ),
  Incident(
    id: 'INC-2026-038',
    type: IncidentType.flood,
    typeLabel: 'Waterlogging',
    location: 'Guwahati GS Road',
    route: 'NH-27',
    severity: Priority.medium,
    reporter: 'Citizen app',
    time: 'Yesterday',
    verified: true,
    assignedOfficer: 'A. Das',
    statusLabel: 'Resolved',
  ),
  Incident(
    id: 'INC-2026-039',
    type: IncidentType.other,
    typeLabel: 'Fallen Tree',
    location: 'Jorhat bypass',
    route: 'NH-37',
    severity: Priority.low,
    reporter: 'Citizen app',
    time: 'Yesterday',
    verified: true,
    assignedOfficer: 'K. Rabha',
    statusLabel: 'Resolved',
  ),
];

const List<FleetVehicle> sampleFleet = [
  FleetVehicle(id: 'TRK-1042', route: 'NH-29', destination: 'Kohima', statusLabel: 'Delayed', risk: Priority.high, eta: '+2h'),
  FleetVehicle(id: 'TRK-1088', route: 'NH-2', destination: 'Kohima', statusLabel: 'At risk', risk: Priority.critical, eta: '—'),
  FleetVehicle(id: 'TRK-1015', route: 'NH-29', destination: 'Dimapur', statusLabel: 'Moving', risk: Priority.low, eta: '16:05'),
  FleetVehicle(id: 'TRK-0994', route: 'NH-39', destination: 'Chumukedima', statusLabel: 'Moving', risk: Priority.low, eta: '11:20'),
  FleetVehicle(id: 'LG-102', route: 'NH-2', destination: 'Kohima', statusLabel: 'At Risk', risk: Priority.high, eta: '4:40 PM'),
  FleetVehicle(id: 'LG-115', route: 'NH-27', destination: 'Tezpur', statusLabel: 'Stopped', risk: Priority.critical, eta: 'Suspended'),
  FleetVehicle(id: 'LG-089', route: 'NH-13', destination: 'Itanagar', statusLabel: 'Stopped', risk: Priority.critical, eta: 'Suspended'),
  FleetVehicle(id: 'LG-134', route: 'NH-40', destination: 'Shillong', statusLabel: 'On Time', risk: Priority.low, eta: '2:15 PM'),
];

const List<DeliveryAssignment> sampleDeliveries = [
  DeliveryAssignment(
    id: 'ASN-4821',
    tripId: 'TRP-R-4821',
    riderId: 'NER-RD-1184',
    vehicleId: 'TRK-NE-2047',
    cargo: 'Essential medicines · 2.4 tonnes',
    priority: Priority.critical,
    origin: 'Guwahati Medical Depot',
    destination: 'Nongpoh Civil Hospital',
    recipient: 'Dr. M. Khongwir',
    window: 'Today · 13:00–15:00',
    risk: RiskLevel.caution,
    eta: '14:12',
    distanceRemaining: '42 km',
    progress: 58,
    status: RiderTripStatus.enRoute,
    decision: AssignmentDecision.accepted,
  ),
  DeliveryAssignment(
    id: 'ASN-4828',
    tripId: 'TRP-R-4828',
    riderId: 'NER-RD-1184',
    vehicleId: 'TRK-NE-2047',
    cargo: 'Relief materials · 1.1 tonnes',
    priority: Priority.high,
    origin: 'Nongpoh Warehouse',
    destination: 'Umsning Relief Camp',
    recipient: 'District Relief Cell',
    window: 'Today · 16:30–18:00',
    risk: RiskLevel.clear,
    eta: '17:05',
    distanceRemaining: '18 km',
    progress: 0,
    status: RiderTripStatus.assigned,
    decision: AssignmentDecision.pending,
  ),
];

const List<MapZone> sampleSafeZones = [
  MapZone(center: LatLng(26.1800, 91.7500), radiusMeters: 4000, kind: MapZoneKind.safe, label: 'Guwahati relief camp'),
  MapZone(center: NerGeo.nongpoh, radiusMeters: 3000, kind: MapZoneKind.safe, label: 'Nongpoh staging area'),
  MapZone(center: LatLng(25.8900, 93.7400), radiusMeters: 3000, kind: MapZoneKind.safe, label: 'Dimapur safe yard'),
  MapZone(center: NerGeo.jowai, radiusMeters: 2500, kind: MapZoneKind.safe, label: 'Jowai holding yard'),
];

const List<MapZone> sampleFloodZones = [
  MapZone(center: LatLng(26.3500, 91.0000), radiusMeters: 18000, kind: MapZoneKind.flood, label: 'Barpeta floodplain'),
  MapZone(center: LatLng(26.2500, 92.3400), radiusMeters: 15000, kind: MapZoneKind.flood, label: 'Morigaon lowlands'),
  MapZone(center: LatLng(26.1300, 91.8000), radiusMeters: 5000, kind: MapZoneKind.flood, label: 'Guwahati low-lying wards'),
];

const List<MapZone> sampleLandslideZones = [
  MapZone(center: LatLng(25.5000, 92.0500), radiusMeters: 12000, kind: MapZoneKind.landslide, label: 'Shillong–Jowai slopes'),
  MapZone(center: LatLng(25.4829, 92.1977), radiusMeters: 3000, kind: MapZoneKind.landslide, label: 'Jowai NH-6 cut slopes'),
  MapZone(center: LatLng(25.9450, 91.8750), radiusMeters: 2500, kind: MapZoneKind.landslide, label: 'Umling–Nongpoh slope'),
  MapZone(center: LatLng(25.6600, 94.0500), radiusMeters: 10000, kind: MapZoneKind.landslide, label: 'Kohima ridge'),
  MapZone(center: LatLng(27.4500, 92.1500), radiusMeters: 12000, kind: MapZoneKind.landslide, label: 'Sela approach'),
];

const List<AppAlert> sampleAlerts = [
  AppAlert(
    id: 'ALT-1',
    severity: AlertSeverity.critical,
    title: 'Landslide on NH-6',
    description: 'Debris across both lanes near Km 150.',
    distance: '4.2 km ahead',
    time: '5 min ago',
    recommendedAction: 'Hold convoys at Jowai until cleared.',
    incidentId: 'INC-2026-044',
  ),
];

final List<LiveRider> sampleLiveRiders = [
  LiveRider(
    userId: 'r1',
    fullName: 'Asha Devi',
    vehicleRegistration: 'AS01 AB 1234',
    latitude: 26.14,
    longitude: 91.74,
    recordedAt: DateTime.utc(2026, 1, 1, 10),
    isOnDuty: true,
  ),
  LiveRider(
    userId: 'r2',
    fullName: 'Bikram Singh',
    vehicleRegistration: 'ML05 CD 5678',
    latitude: 25.57,
    longitude: 91.88,
    recordedAt: DateTime.utc(2026, 1, 1, 10),
    isOnDuty: true,
  ),
];
