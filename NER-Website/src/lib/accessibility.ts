import { useEffect } from 'react';
import { supabase } from '@/lib/supabase';
import { MlSignedOutError, useMlQuery, type MlMeta } from '@/lib/ml';
import type { LatLng } from '@/data/geo';

/**
 * Corridor accessibility computed in the database (get_corridor_accessibility,
 * supabase/migrations/20260927100030_gis_accessibility.sql) from open road_incidents,
 * route geometry and the latest ML run. The server scopes incidents to the caller's
 * district (control room: all, or the district passed in).
 */

export type CorridorStatus = 'open' | 'restricted' | 'blocked';

export interface CorridorIncident {
  id: string;
  incident_type: string;
  severity: string;
  status: string;
  blocks: boolean;
  created_at: string;
  district: string | null;
  lat: number | null;
  lon: number | null;
}

export interface CorridorRow {
  route_id: string;
  route_number: string;
  name: string;
  origin: string | null;
  destination: string | null;
  status: CorridorStatus;
  has_geometry: boolean;
  length_m: number | null;
  open_length_pct: number | null;
  accessibility_pct: number | null;
  blocking_incidents: number;
  open_incidents: number;
  incidents: CorridorIncident[];
  ml: { n_segments: number; n_alert: number; mean_percentile: number | null; max_percentile: number | null } | null;
  geojson: { type: 'LineString'; coordinates: [number, number][] } | null;
}

export interface CorridorAccessibility {
  generated_at: string;
  scope: string;
  ml: MlMeta;
  routes: CorridorRow[];
}

export const STATUS_LABEL: Record<CorridorStatus, 'Open' | 'Restricted' | 'Blocked'> = {
  open: 'Open', restricted: 'Restricted', blocked: 'Blocked',
};

export async function fetchCorridorAccessibility(district?: string | null): Promise<CorridorAccessibility> {
  if (!supabase) throw new MlSignedOutError();
  const { data: session } = await supabase.auth.getSession();
  if (!session.session) throw new MlSignedOutError();
  const { data, error } = await supabase.rpc('get_corridor_accessibility', { p_district: district ?? null });
  if (error) throw new Error(error.message);
  return data as CorridorAccessibility;
}

/** Leaflet [lat, lng] path from the route's GeoJSON line. */
export const pathOf = (row: CorridorRow): LatLng[] | undefined =>
  row.geojson?.coordinates.map(([lng, lat]) => [lat, lng] as LatLng);

/** Length-weighted network accessibility; null when no route has geometry. */
export function networkAccessibility(rows: CorridorRow[]): number | null {
  const measured = rows.filter(r => r.accessibility_pct !== null && r.length_m);
  const total = measured.reduce((sum, r) => sum + r.length_m!, 0);
  if (!total) return null;
  return Math.round(measured.reduce((sum, r) => sum + r.accessibility_pct! * r.length_m!, 0) / total);
}

/** Loads corridor accessibility and refetches on incident changes and new ML runs. */
export function useCorridorAccessibility(district?: string | null) {
  const query = useMlQuery(() => fetchCorridorAccessibility(district), [district]);
  const { reload } = query;
  useEffect(() => {
    if (!supabase) return;
    const client = supabase;
    let timer: number | undefined;
    const channel = client
      .channel(`corridor-access-${Math.random().toString(36).slice(2)}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'road_incidents' }, () => {
        window.clearTimeout(timer);
        timer = window.setTimeout(reload, 800);
      })
      .subscribe();
    return () => { window.clearTimeout(timer); void client.removeChannel(channel); };
  }, [district, reload]);
  return query;
}
