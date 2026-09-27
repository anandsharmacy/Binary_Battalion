import { ROAD_CONDITIONS, type Incident, type IncidentStatus, type IncidentType, type RoadCondition, type Severity } from '@/data/demo';
import { supabase } from '@/lib/supabase';
import { notify } from '@/lib/notify';
import { LiveTable, errorText, myUserId, officerLabel, resolveOfficer } from '@/lib/liveTable';

/** An evidence file. `dataUrl` is a short-lived signed URL (or a local preview while uploading). */
export type IncidentEvidence = NonNullable<Incident['evidence']>[number] & { path?: string };

export type StoredIncident = Incident & {
  evidence: IncidentEvidence[];
  /** Reporter and assignee user ids (the display names are in reportedBy / assignedOfficer). */
  reporterId: string | null;
  assignedTo: string | null;
  districtId: string | null;
};

/** public.road_incidents (see supabase/migrations/20260927100060_field_reporting.sql). */
export interface IncidentRow {
  id: string;
  client_id?: string | null;
  incident_type: string;
  severity: string;
  description?: string | null;
  title?: string | null;
  location_text?: string | null;
  route_text?: string | null;
  lat?: number | null;
  lng?: number | null;
  district_id?: string | null;
  reporter_id?: string | null;
  assigned_to?: string | null;
  status?: string;
  verification?: string;
  evidence_paths?: string[];
  landmark?: string | null;
  road_condition?: string | null;
  vehicles_affected?: number | null;
  estimated_blockage?: string | null;
  created_at?: string;
}

const TYPE_TO_DB: Record<string, string> = {
  Flood: 'flood', Landslide: 'landslide', 'Road Blockage': 'road_blockage', Accident: 'accident',
  'Infrastructure Damage': 'infrastructure_damage', 'Vehicle Breakdown': 'vehicle',
};
const TYPE_FROM_DB: Record<string, string> = {
  ...Object.fromEntries(Object.entries(TYPE_TO_DB).map(([k, v]) => [v, k])),
  weather: 'Weather', safety: 'Safety', other: 'Other',
};
export const SEVERITY_TO_DB: Record<Severity, string> = { CRITICAL: 'critical', HIGH: 'high', MODERATE: 'moderate', LOW: 'info' };
export const SEVERITY_FROM_DB: Record<string, Severity> = { critical: 'CRITICAL', high: 'HIGH', moderate: 'MODERATE', info: 'LOW' };
const STATUS_TO_DB: Record<IncidentStatus, string> = {
  PENDING_VERIFICATION: 'reported', UNDER_REVIEW: 'under_review', ACTIVE: 'active', ESCALATED: 'escalated', RESOLVED: 'resolved',
};
const STATUS_FROM_DB: Record<string, IncidentStatus> = {
  reported: 'PENDING_VERIFICATION', under_review: 'UNDER_REVIEW', verified: 'ACTIVE', active: 'ACTIVE', assigned: 'ACTIVE',
  escalated: 'ESCALATED', resolved: 'RESOLVED', rejected: 'RESOLVED',
};
const ROAD_TO_DB: Record<RoadCondition, string> = {
  'Fully Blocked': 'fully_blocked', 'Partially Accessible': 'partially_accessible', 'Passable with caution': 'passable_with_caution',
};
const ROAD_FROM_DB = Object.fromEntries(ROAD_CONDITIONS.map(c => [ROAD_TO_DB[c], c])) as Record<string, RoadCondition>;
const RISK: Record<Severity, number> = { CRITICAL: 90, HIGH: 70, MODERATE: 45, LOW: 20 };
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export const formatTime = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' }) : '';

function mimeOf(path: string) {
  const ext = path.split('.').pop()?.toLowerCase() ?? '';
  if (['mp4', 'mov', 'webm'].includes(ext)) return ext === 'mov' ? 'video/quicktime' : `video/${ext}`;
  return `image/${ext === 'jpg' ? 'jpeg' : ext || 'jpeg'}`;
}

// Signed URLs for private evidence, fetched in batches as rows arrive.
const signed = new Map<string, string>();
const pending = new Set<string>();
const localPreviews = new Map<string, IncidentEvidence[]>();

function toIncident(row: IncidentRow): StoredIncident {
  const severity = SEVERITY_FROM_DB[row.severity] ?? 'MODERATE';
  const paths = row.evidence_paths ?? [];
  const hasCoords = row.lat != null && row.lng != null;
  return {
    id: row.id,
    type: (TYPE_FROM_DB[row.incident_type] ?? cap(row.incident_type)) as IncidentType,
    location: row.location_text || (hasCoords ? `${row.lat!.toFixed(5)}, ${row.lng!.toFixed(5)}` : 'Location not provided'),
    route: row.route_text || 'Route not provided',
    severity,
    reportedBy: officerLabel(row.reporter_id) ?? 'Unknown',
    reportedTime: formatTime(row.created_at),
    reportedAt: row.created_at,
    verification: cap(row.verification ?? 'pending') as Incident['verification'],
    assignedOfficer: officerLabel(row.assigned_to),
    status: STATUS_FROM_DB[row.status ?? 'reported'] ?? 'PENDING_VERIFICATION',
    description: row.description || 'No description provided.',
    gpsCoords: hasCoords ? `${row.lat!.toFixed(6)}, ${row.lng!.toFixed(6)}` : 'Not captured',
    riskScore: RISK[severity],
    affectedLogistics: row.vehicles_affected ?? 0,
    estimatedDisruption: row.estimated_blockage || 'Not estimated',
    landmark: row.landmark ?? null,
    roadCondition: row.road_condition ? ROAD_FROM_DB[row.road_condition] ?? null : null,
    evidence: localPreviews.get(row.id) ?? paths.map(path => ({
      path, name: path.split('/').pop() ?? path, type: mimeOf(path), size: 0, dataUrl: signed.get(path) ?? '',
    })),
    reporterId: row.reporter_id ?? null,
    assignedTo: row.assigned_to ?? null,
    districtId: row.district_id ?? null,
  };
}

const table = new LiveTable<IncidentRow, StoredIncident>('road_incidents', toIncident);

async function signMissing() {
  const missing = table.allRows().flatMap(r => r.evidence_paths ?? []).filter(p => !signed.has(p) && !pending.has(p));
  if (!missing.length || !supabase) return;
  missing.forEach(p => pending.add(p));
  const { data } = await supabase.storage.from('incident-evidence').createSignedUrls(missing, 60 * 60);
  missing.forEach(p => pending.delete(p));
  for (const s of data ?? []) if (s.path && s.signedUrl) signed.set(s.path, s.signedUrl);
  if (data?.length) table.refresh();
}
table.subscribe(() => { void signMissing(); });

export function getIncidents(): StoredIncident[] {
  return table.items();
}

export function addIncident(input: {
  type: Incident['type'];
  location: string;
  route: string;
  severity: Severity;
  reportedBy: string;
  description: string;
  gpsCoords: string;
  evidence: IncidentEvidence[];
  landmark?: string;
  roadCondition?: RoadCondition | null;
  vehiclesAffected?: number | null;
  estimatedBlockage?: string;
}) {
  const id = crypto.randomUUID();
  const [lat, lng] = input.gpsCoords.split(',').map(v => parseFloat(v));
  const row: IncidentRow = {
    id,
    client_id: id,
    incident_type: TYPE_TO_DB[input.type] ?? 'other',
    severity: SEVERITY_TO_DB[input.severity],
    location_text: input.location.trim() || null,
    route_text: input.route.trim() || null,
    description: input.description.trim() || null,
    lat: Number.isFinite(lat) && Number.isFinite(lng) ? lat : null,
    lng: Number.isFinite(lat) && Number.isFinite(lng) ? lng : null,
    reporter_id: myUserId(),
    status: 'reported',
    verification: 'pending',
    evidence_paths: [],
    landmark: input.landmark?.trim() || null,
    road_condition: input.roadCondition ? ROAD_TO_DB[input.roadCondition] : null,
    vehicles_affected: input.vehiclesAffected ?? null,
    estimated_blockage: input.estimatedBlockage?.trim() || null,
    created_at: new Date().toISOString(),
  };
  localPreviews.set(id, input.evidence);
  const optimistic = toIncident(row);
  table.put(row);
  void (async () => {
    const uid = myUserId();
    if (!supabase || !uid) { table.remove(id); notify('Report was not saved: you are not signed in.', { tone: 'error' }); return; }
    try {
      // Files first, so the row never points at a missing object.
      row.evidence_paths = await Promise.all(input.evidence.map(async (file, i) => {
        const path = `${uid}/${id}/${i}-${file.name.replace(/[^\w.-]+/g, '_')}`;
        const blob = await (await fetch(file.dataUrl)).blob();
        const { error } = await supabase!.storage.from('incident-evidence').upload(path, blob, { contentType: file.type, upsert: true });
        if (error) throw error;
        return path;
      }));
    } catch (e) {
      localPreviews.delete(id);
      table.remove(id);
      notify(`Report was not saved: evidence upload failed (${errorText(e)}).`, { tone: 'error' });
      return;
    }
    const ok = await table.insert(row, 'Report');
    if (ok) { localPreviews.delete(id); table.refresh(); }
  })();
  return optimistic;
}

export function updateIncident(id: string, updates: Partial<Pick<Incident, 'verification' | 'assignedOfficer' | 'status'>>) {
  const patch: Partial<IncidentRow> = {};
  if (updates.verification) patch.verification = updates.verification.toLowerCase();
  if (updates.status) patch.status = STATUS_TO_DB[updates.status];
  if (updates.assignedOfficer !== undefined) {
    const officer = resolveOfficer(updates.assignedOfficer);
    if (officer === undefined) { notify(`Unknown officer "${updates.assignedOfficer}".`, { tone: 'error' }); return; }
    patch.assigned_to = officer;
  }
  void table.update(id, patch, 'Incident update');
}

export function subscribeToIncidents(listener: (incidents: StoredIncident[]) => void) {
  return table.subscribe(listener);
}
