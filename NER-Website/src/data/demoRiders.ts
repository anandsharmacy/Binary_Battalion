/* ────────────────────────────────────────────────────────────────
   Rider dataset for the website. The demo riders were removed, so
   DEMO_RIDERS / DEMO_RIDER_ROUTES are empty until real rider data is
   connected; the types and helpers below stay for that.
──────────────────────────────────────────────────────────────── */

import type { Severity } from '@/data/demo';
import type { LatLng } from '@/data/geo';

export type RiderStatus = 'Active' | 'Inactive';
export type RiderVehicleType = 'Bike' | 'Scooter';

export interface DemoRider {
  id: string;
  name: string;
  phone: string;
  state: string;
  district: string;
  vehicleType: RiderVehicleType;
  rating: number;
  status: RiderStatus;
  /** Reported delay, e.g. "+20m". Unset when the rider is on schedule. */
  delay?: string;
  /** Shipment risk. Unset when nothing is flagged. */
  risk?: Severity;
}

export const DEMO_RIDERS: DemoRider[] = [];

/* ── Map geometry ───────────────────────────────────────────────
   One route per rider. Waypoints are named so the "Current Location"
   column can follow the rider as it moves. */

export interface RiderWaypoint {
  at: LatLng;
  label: string;
}

export interface RiderBlockedSection {
  /** Index of the waypoint where the blocked stretch begins. */
  from: number;
  /** Index of the waypoint where the road is passable again. */
  to: number;
  /** Alternate waypoints joining path[from] to path[to]. */
  detour: RiderWaypoint[];
  reason: string;
}

export interface RiderRoute {
  riderId: string;
  path: RiderWaypoint[];
  blocked?: RiderBlockedSection;
}

export const DEMO_RIDER_ROUTES: Record<string, RiderRoute> = {};

/* ── Derived views (State → District → Rider) ─────────────────── */

export interface DistrictRiders<T extends DemoRider = DemoRider> {
  district: string;
  state: string;
  riders: T[];
}

export interface StateRiders<T extends DemoRider = DemoRider> {
  state: string;
  districts: DistrictRiders<T>[];
  riders: T[];
}

/** Groups riders as State → District → Rider, preserving dataset order. */
export function groupRidersByState<T extends DemoRider>(riders: T[]): StateRiders<T>[] {
  const states: StateRiders<T>[] = [];
  riders.forEach(rider => {
    let state = states.find(s => s.state === rider.state);
    if (!state) {
      state = { state: rider.state, riders: [], districts: [] };
      states.push(state);
    }
    state.riders.push(rider);
    let district = state.districts.find(d => d.district === rider.district);
    if (!district) {
      district = { district: rider.district, state: rider.state, riders: [] };
      state.districts.push(district);
    }
    district.riders.push(rider);
  });
  return states;
}

export interface RiderCounts {
  riders: number;
  active: number;
  inactive: number;
}

function countRiders(riders: DemoRider[]): RiderCounts {
  return {
    riders: riders.length,
    active: riders.filter(r => r.status === 'Active').length,
    inactive: riders.filter(r => r.status === 'Inactive').length,
  };
}

/** Per-state rider counts, derived from the rider list. */
export function stateRiderCounts(riders: DemoRider[]): ({ state: string } & RiderCounts)[] {
  return groupRidersByState(riders).map(group => ({ state: group.state, ...countRiders(group.riders) }));
}

/** Per-district rider counts, derived from the rider list. */
export function districtRiderCounts(riders: DemoRider[]): ({ district: string; state: string } & RiderCounts)[] {
  return groupRidersByState(riders).flatMap(group =>
    group.districts.map(district => ({ district: district.district, state: district.state, ...countRiders(district.riders) })),
  );
}

/** State → District → Rider filter. Omit district for a whole state; omit both for everyone. */
export function filterRiders<T extends DemoRider>(riders: T[], state?: string | null, district?: string | null): T[] {
  return riders.filter(r => (!state || r.state === state) && (!district || r.district === district));
}

/** Logistics KPI values, derived from the rider list. */
export function riderKpis(riders: DemoRider[]) {
  return {
    active: riders.filter(r => r.status === 'Active').length,
    delayed: riders.filter(r => Boolean(r.delay)).length,
    atRisk: riders.filter(r => r.risk === 'CRITICAL' || r.risk === 'HIGH').length,
    inactive: riders.filter(r => r.status === 'Inactive').length,
  };
}

export function riderRoute(riderId: string): RiderRoute | null {
  return DEMO_RIDER_ROUTES[riderId] ?? null;
}
