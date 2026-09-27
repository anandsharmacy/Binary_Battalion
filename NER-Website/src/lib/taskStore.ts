import type { Severity, Task, TaskStatus } from '@/data/demo';
import { profileService } from '@/lib/profileService';
import { notify } from '@/lib/notify';
import { LiveTable, myUserId, officerLabel, resolveOfficer } from '@/lib/liveTable';
import { SEVERITY_FROM_DB, SEVERITY_TO_DB, formatTime, getIncidents } from '@/lib/incidentStore';

export type StoredTask = Task & { assignedTo: string | null; districtId: string | null };

// Post-completion states still count as completed work; a rejected verification does not.
export const COMPLETED_TASK_STATUSES: TaskStatus[] = ['Completed', 'Awaiting Verification', 'Verified'];

/** public.field_tasks (see supabase/migrations/20260927100060_field_reporting.sql). Timestamps are server-set. */
interface TaskRow {
  id: string;
  client_id?: string | null;
  incident_id?: string | null;
  title: string;
  description?: string | null;
  location_text?: string | null;
  priority: string;
  status: string;
  assigned_to?: string | null;
  district_id?: string | null;
  created_by?: string | null;
  deadline?: string | null;
  verification_note?: string | null;
  assigned_at?: string | null;
  started_at?: string | null;
  completed_at?: string | null;
  created_at?: string;
}

const STATUS_TO_DB: Record<TaskStatus, string> = {
  New: 'new', 'In Progress': 'in_progress', Completed: 'completed', Escalated: 'escalated',
  'Awaiting Verification': 'awaiting_verification', Verified: 'verified', Rejected: 'rejected',
};
const STATUS_FROM_DB = Object.fromEntries(Object.entries(STATUS_TO_DB).map(([k, v]) => [v, k])) as Record<string, TaskStatus>;

function toTask(row: TaskRow): StoredTask {
  return {
    id: row.id,
    title: row.title,
    location: row.location_text ?? '',
    priority: SEVERITY_FROM_DB[row.priority] ?? 'MODERATE',
    assignedOfficer: officerLabel(row.assigned_to),
    created: formatTime(row.created_at),
    deadline: row.deadline ? formatTime(row.deadline) : 'Pending review',
    status: STATUS_FROM_DB[row.status] ?? 'New',
    relatedIncident: row.incident_id ?? null,
    description: row.description ?? '',
    verificationNote: row.verification_note ?? undefined,
    assignedAt: row.assigned_at ?? undefined,
    startedAt: row.started_at ?? undefined,
    completedAt: row.completed_at ?? undefined,
    assignedTo: row.assigned_to ?? null,
    districtId: row.district_id ?? null,
  };
}

const table = new LiveTable<TaskRow, StoredTask>('field_tasks', toTask);

/** Mean minutes from start (else assignment) to completion over completed, officer-handled tasks; null when none are valid. */
export function averageResponseMinutes(tasks: StoredTask[]): number | null {
  const durations = tasks
    .filter(task => task.assignedOfficer && COMPLETED_TASK_STATUSES.includes(task.status))
    .map(task => Date.parse(task.completedAt ?? '') - Date.parse(task.startedAt ?? task.assignedAt ?? ''))
    .filter(ms => ms >= 0); // NaN (missing/invalid timestamp) fails this and is dropped
  return durations.length ? Math.round(durations.reduce((sum, ms) => sum + ms, 0) / durations.length / 60000) : null;
}

/** Average response time over the given tasks (all visible tasks by default); null when there is none yet. */
export function getAvgResponseMinutes(tasks: StoredTask[] = getTasks()): number | null {
  return averageResponseMinutes(tasks);
}

export function getTasks(): StoredTask[] {
  return table.items();
}

export function createTaskFromIncident(input: {
  incidentId: string;
  title: string;
  location: string;
  priority: Severity;
  description: string;
  assignedOfficer?: string;
}) {
  // Default assignee: whoever the incident is already assigned to.
  const assignee = input.assignedOfficer !== undefined
    ? resolveOfficer(input.assignedOfficer)
    : getIncidents().find(i => i.id === input.incidentId)?.assignedTo ?? null;
  if (assignee === undefined) notify(`Unknown officer "${input.assignedOfficer}"; task left unassigned.`, { tone: 'error' });
  const id = crypto.randomUUID();
  const row: TaskRow = {
    id,
    client_id: id,
    incident_id: input.incidentId,
    title: input.title,
    description: input.description,
    location_text: input.location,
    priority: SEVERITY_TO_DB[input.priority],
    status: 'new',
    assigned_to: assignee ?? null,
    created_by: myUserId(),
    created_at: new Date().toISOString(),
  };
  void table.insert(row, 'Task');
  return toTask(row);
}

export function updateTask(id: string, updates: Partial<Pick<Task, 'status' | 'assignedOfficer'>>) {
  const current = table.row(id);
  // Verification outcomes only come from reviewTask (District Officer). Undoing a review is allowed (DB checks the role).
  if (updates.status === 'Verified' || updates.status === 'Rejected') return;
  const patch: Partial<TaskRow> = {};
  if (updates.status) patch.status = STATUS_TO_DB[updates.status];
  if (updates.assignedOfficer !== undefined) {
    const officer = resolveOfficer(updates.assignedOfficer);
    if (officer === undefined) { notify(`Unknown officer "${updates.assignedOfficer}".`, { tone: 'error' }); return; }
    patch.assigned_to = officer;
  }
  if (current) void table.update(id, patch, 'Task update');
}

/** Field Officer: send a completed task to the District Officer for verification. */
export function requestTaskVerification(id: string) {
  if (table.row(id)?.status === 'completed') void table.update(id, { status: 'awaiting_verification' }, 'Verification request');
}

/** District Officer only: approve or reject a pending verification request. */
export function reviewTask(id: string, approve: boolean, reason = '') {
  if (profileService.getCurrentRole() !== 'district') return;
  if (table.row(id)?.status !== 'awaiting_verification') return;
  void table.update(id, {
    status: approve ? 'verified' : 'rejected',
    verification_note: approve ? null : reason.trim() || null,
  }, 'Review');
}

export function subscribeToTasks(listener: (tasks: StoredTask[]) => void) {
  return table.subscribe(listener);
}
