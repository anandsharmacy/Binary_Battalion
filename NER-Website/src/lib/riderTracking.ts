/* ────────────────────────────────────────────────────────────────
   Live rider tracking for officers. Mirrors the Flutter
   LiveRiderRepository / LiveRidersController:
   - initial load: get_active_riders RPC (joined identity/vehicle/shipment)
   - live deltas: one Realtime channel on rider_locations + rider_profiles
   - polling fallback every 30 s while the channel is not subscribed
   RLS (can_see_rider) limits district/field officers to their district.
   Detours are not computed here; see routing.ts.
──────────────────────────────────────────────────────────────── */

import { useEffect, useRef, useState } from 'react';
import type { LatLng } from '@/data/geo';
import { supabase } from '@/lib/supabase';
import { isStale, STALE_MINUTES } from '@/lib/riderStale';

export { isStale, STALE_MINUTES };

export interface LiveRider {
  id: string;
  /** Short marker label: officer id, else first name. */
  label: string;
  name: string;
  officerId: string | null;
  phone: string | null;
  district: string | null;
  vehicleRegistration: string | null;
  vehicleType: string | null;
  onDuty: boolean;
  position: LatLng;
  speedKmph: number | null;
  headingDeg: number | null;
  batteryPercent: number | null;
  isMoving: boolean;
  /** ISO time of the last GPS fix. */
  recordedAt: string;
  shipmentId: string | null;
  shipmentNumber: string | null;
  destination: string | null;
  riskLevel: string | null;
  /** Last fix older than STALE_MINUTES (recomputed every tick). */
  stale: boolean;
}

interface ActiveRiderRow {
  user_id: string;
  full_name: string | null;
  officer_id: string | null;
  phone: string | null;
  district: string | null;
  vehicle_registration: string | null;
  vehicle_type: string | null;
  is_on_duty: boolean;
  latitude: number;
  longitude: number;
  speed_kmph: number | null;
  heading_deg: number | null;
  battery_percent: number | null;
  is_moving: boolean | null;
  recorded_at: string;
  shipment_id: string | null;
  shipment_number: string | null;
  destination_name: string | null;
  risk_level: string | null;
}

type LocationChange = Partial<Pick<ActiveRiderRow,
  'user_id' | 'latitude' | 'longitude' | 'speed_kmph' | 'heading_deg' | 'battery_percent' | 'is_moving' | 'recorded_at' | 'shipment_id'>>;
type ProfileChange = Partial<Pick<ActiveRiderRow, 'user_id' | 'is_on_duty' | 'vehicle_registration' | 'vehicle_type' | 'phone'>>;

function fromRow(r: ActiveRiderRow, now: number): LiveRider {
  const name = r.full_name?.trim() || 'Unnamed rider';
  return {
    id: r.user_id,
    label: r.officer_id || name.split(' ')[0],
    name,
    officerId: r.officer_id,
    phone: r.phone,
    district: r.district,
    vehicleRegistration: r.vehicle_registration,
    vehicleType: r.vehicle_type,
    onDuty: r.is_on_duty,
    position: [r.latitude, r.longitude],
    speedKmph: r.speed_kmph,
    headingDeg: r.heading_deg,
    batteryPercent: r.battery_percent,
    isMoving: Boolean(r.is_moving),
    recordedAt: r.recorded_at,
    shipmentId: r.shipment_id,
    shipmentNumber: r.shipment_number,
    destination: r.destination_name,
    riskLevel: r.risk_level,
    stale: isStale(r.recorded_at, now),
  };
}

/** Fresh on-duty riders first, then off-duty, then stale; newest fix first within each. */
function sortRiders(riders: LiveRider[]): LiveRider[] {
  const rank = (r: LiveRider) => (r.stale ? 2 : r.onDuty ? 0 : 1);
  return riders.sort((a, b) => rank(a) - rank(b) || Date.parse(b.recordedAt) - Date.parse(a.recordedAt));
}

const TICK_MS = 30_000;

export interface LiveRidersFeed {
  riders: LiveRider[];
  loading: boolean;
  error: string | null;
  /** True while the Realtime channel is subscribed; false means polling. */
  live: boolean;
  now: number;
}

export function useLiveRiders(): LiveRidersFeed {
  const byId = useRef(new Map<string, LiveRider>());
  const [riders, setRiders] = useState<LiveRider[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [live, setLive] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const client = supabase;
    if (!client) {
      setError('Supabase is not configured for this build.');
      setLoading(false);
      return;
    }
    let cancelled = false;
    let isLive = false;
    let refetchTimer: number | undefined;
    const commit = () => setRiders(sortRiders([...byId.current.values()]));

    const load = async () => {
      const { data, error: rpcError } = await client.rpc('get_active_riders', { p_stale_minutes: STALE_MINUTES });
      if (cancelled) return;
      if (rpcError) {
        setError(rpcError.message);
      } else {
        const t = Date.now();
        byId.current = new Map((data as ActiveRiderRow[]).map(r => [r.user_id, fromRow(r, t)]));
        setError(null);
        commit();
      }
      setLoading(false);
    };
    // New rider or new shipment: the joined details only come from the RPC.
    const refetchSoon = () => {
      window.clearTimeout(refetchTimer);
      refetchTimer = window.setTimeout(load, 2000);
    };

    const onLocation = (row: LocationChange) => {
      const cur = row.user_id ? byId.current.get(row.user_id) : undefined;
      if (!cur || !row.recorded_at || row.latitude == null || row.longitude == null) {
        if (row.user_id) refetchSoon();
        return;
      }
      if (Date.parse(row.recorded_at) < Date.parse(cur.recordedAt)) return;
      if ((row.shipment_id ?? null) !== cur.shipmentId) refetchSoon();
      byId.current.set(cur.id, {
        ...cur,
        position: [row.latitude, row.longitude],
        speedKmph: row.speed_kmph ?? null,
        headingDeg: row.heading_deg ?? null,
        batteryPercent: row.battery_percent ?? null,
        isMoving: Boolean(row.is_moving),
        recordedAt: row.recorded_at,
        stale: isStale(row.recorded_at, Date.now()),
      });
      commit();
    };
    const onProfile = (row: ProfileChange) => {
      const cur = row.user_id ? byId.current.get(row.user_id) : undefined;
      if (!cur) {
        if (row.user_id) refetchSoon();
        return;
      }
      byId.current.set(cur.id, {
        ...cur,
        onDuty: Boolean(row.is_on_duty),
        vehicleRegistration: row.vehicle_registration ?? cur.vehicleRegistration,
        vehicleType: row.vehicle_type ?? cur.vehicleType,
        phone: row.phone ?? cur.phone,
      });
      commit();
    };

    void load();
    const channel = client
      .channel(`live-riders-${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rider_locations' }, p => onLocation(p.new as LocationChange))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rider_profiles' }, p => onProfile(p.new as ProfileChange))
      .subscribe(status => {
        if (cancelled) return;
        const wasLive = isLive;
        isLive = status === 'SUBSCRIBED';
        setLive(isLive);
        if (isLive && !wasLive) void load(); // anything missed while (re)connecting
      });

    // Refreshes staleness and "x min ago"; polls while Realtime is down.
    const tick = window.setInterval(() => {
      const t = Date.now();
      setNow(t);
      byId.current.forEach((r, id) => {
        const stale = isStale(r.recordedAt, t);
        if (stale !== r.stale) byId.current.set(id, { ...r, stale });
      });
      commit();
      if (!isLive) void load();
    }, TICK_MS);

    return () => {
      cancelled = true;
      window.clearTimeout(refetchTimer);
      window.clearInterval(tick);
      void client.removeChannel(channel);
    };
  }, []);

  return { riders, loading, error, live, now };
}

/** Chronological breadcrumb trail for one rider from rider_location_history (RLS/scope-checked). */
export async function fetchRiderTrail(userId: string, hours = 2): Promise<LatLng[]> {
  if (!supabase) return [];
  const { data, error } = await supabase.rpc('get_rider_trail', {
    p_user_id: userId,
    p_since: new Date(Date.now() - hours * 3_600_000).toISOString(),
    p_limit: 500,
  });
  if (error) throw new Error(error.message);
  return (data as { latitude: number; longitude: number }[]).reverse().map(p => [p.latitude, p.longitude]);
}
