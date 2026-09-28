/* ────────────────────────────────────────────────────────────────
   Shipment board for district officers and the control room.
   - list:   list_shipments RPC (names resolved, scoped by the database)
   - live:   one Realtime channel on `shipments` (RLS-filtered) triggers a re-fetch;
             polling every 30 s while the channel is not subscribed
   - writes: create_shipment / assign_shipment / cancel_shipment RPCs. The table itself is
             read-only for clients, so every rule (district scope, who can be assigned,
             valid status changes) is enforced by the database, not by this file.
──────────────────────────────────────────────────────────────── */

import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '@/lib/supabase';

export type ShipmentStatus =
  | 'scheduled' | 'assigned' | 'accepted' | 'in_transit' | 'on_schedule' | 'delayed' | 'at_risk'
  | 'arrived' | 'completed' | 'cancelled';

export interface Shipment {
  id: string;
  shipment_number: string;
  status: ShipmentStatus;
  risk_level: string;
  cargo_description: string | null;
  cargo_weight_kg: number | null;
  origin: string | null;
  destination: string | null;
  route_number: string | null;
  district_id: string | null;
  district: string | null;
  rider_id: string | null;
  rider_name: string | null;
  rider_officer_id: string | null;
  estimated_arrival: string | null;
  created_at: string;
  updated_at: string;
  assigned_at: string | null;
  accepted_at: string | null;
  started_at: string | null;
  arrived_at: string | null;
  completed_at: string | null;
  declined_at: string | null;
  decline_reason: string | null;
  declined_by_name: string | null;
  cancel_reason: string | null;
  created_by_name: string | null;
}

export interface AssignableRider {
  user_id: string;
  full_name: string | null;
  officer_id: string | null;
  phone: string | null;
  home_district: string | null;
  current_district: string | null;
  is_on_duty: boolean;
  vehicle_type: string | null;
  vehicle_registration: string | null;
  open_shipments: number;
  last_fix_at: string | null;
}

export interface NewShipment {
  cargo_description?: string;
  cargo_weight_kg?: string;
  origin: string;
  destination: string;
  route_id?: string;
  estimated_arrival?: string;
  risk_level?: string;
  district_id?: string;
  rider_id?: string;
}

export type ShipmentTab = 'unassigned' | 'awaiting' | 'active' | 'delivered' | 'cancelled';

export const TAB_LABEL: Record<ShipmentTab, string> = {
  unassigned: 'Unassigned',
  awaiting: 'Awaiting rider',
  active: 'Active',
  delivered: 'Delivered',
  cancelled: 'Cancelled',
};

export function tabOf(s: Pick<Shipment, 'status'>): ShipmentTab {
  switch (s.status) {
    case 'scheduled': return 'unassigned';
    case 'assigned': return 'awaiting';
    case 'arrived':
    case 'completed': return 'delivered';
    case 'cancelled': return 'cancelled';
    default: return 'active';
  }
}

/** Label understood by StatusBadge. */
export function statusLabel(status: ShipmentStatus): string {
  switch (status) {
    case 'scheduled': return 'Unassigned';
    case 'assigned': return 'Awaiting rider';
    case 'accepted': return 'Accepted';
    case 'in_transit': return 'In transit';
    case 'on_schedule': return 'On Time';
    case 'delayed': return 'Delayed';
    case 'at_risk': return 'At Risk';
    case 'arrived': return 'Arrived';
    case 'completed': return 'Delivered';
    case 'cancelled': return 'Cancelled';
  }
}

/** Assign / reassign is only possible until the rider has accepted. */
export const canAssign = (s: Pick<Shipment, 'status'>) => s.status === 'scheduled' || s.status === 'assigned';
export const canCancel = (s: Pick<Shipment, 'status'>) => !['arrived', 'completed', 'cancelled'].includes(s.status);

async function call<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  if (!supabase) throw new Error('Not connected to the server.');
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

export const fetchShipments = () => call<Shipment[]>('list_shipments');
export const listAssignableRiders = () => call<AssignableRider[]>('list_assignable_riders');
export const createShipment = (p: NewShipment) => call<string>('create_shipment', { p });
export const assignShipment = (id: string, riderId: string) => call<void>('assign_shipment', { p_id: id, p_rider: riderId });
export const cancelShipment = (id: string, reason: string) =>
  call<void>('cancel_shipment', { p_id: id, p_reason: reason.trim() || null });

export interface RouteOption { id: string; route_number: string; name: string }
export interface DistrictOption { id: string; name: string; state: string | null }

export async function listRoutes(): Promise<RouteOption[]> {
  if (!supabase) return [];
  const { data, error } = await supabase.from('routes').select('id, route_number, name').order('route_number');
  if (error) throw new Error(error.message);
  return (data ?? []) as RouteOption[];
}

export async function listDistricts(): Promise<DistrictOption[]> {
  if (!supabase) return [];
  const { data, error } = await supabase.from('locations').select('id, name, state').eq('kind', 'district').order('name');
  if (error) throw new Error(error.message);
  return (data ?? []) as DistrictOption[];
}

export interface ShipmentFeed {
  shipments: Shipment[];
  loading: boolean;
  error: string | null;
  /** True while the Realtime channel is subscribed; false means polling. */
  live: boolean;
  reload: () => Promise<void>;
}

const POLL_MS = 30_000;

export function useShipments(): ShipmentFeed {
  const [shipments, setShipments] = useState<Shipment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [live, setLive] = useState(false);
  const alive = useRef(true);

  const reload = useCallback(async () => {
    try {
      const rows = await fetchShipments();
      if (!alive.current) return;
      setShipments(rows);
      setError(null);
    } catch (e) {
      if (alive.current) setError((e as Error).message);
    }
    if (alive.current) setLoading(false);
  }, []);

  useEffect(() => {
    alive.current = true;
    const client = supabase;
    if (!client) {
      setError('Supabase is not configured for this build.');
      setLoading(false);
      return;
    }
    let isLive = false;
    let timer: number | undefined;
    const soon = () => { window.clearTimeout(timer); timer = window.setTimeout(() => void reload(), 250); };

    void reload();
    const channel = client
      .channel(`shipments-${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'shipments' }, soon)
      .subscribe(status => {
        const was = isLive;
        isLive = status === 'SUBSCRIBED';
        if (alive.current) setLive(isLive);
        if (isLive && !was) soon(); // anything missed while (re)connecting
      });
    const poll = window.setInterval(() => { if (!isLive) void reload(); }, POLL_MS);

    return () => {
      alive.current = false;
      window.clearTimeout(timer);
      window.clearInterval(poll);
      void client.removeChannel(channel);
    };
  }, [reload]);

  return { shipments, loading, error, live, reload };
}
