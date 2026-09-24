import type { Severity, Task, TaskStatus } from '@/data/demo';
import { profileService } from '@/lib/profileService';

export type StoredTask = Task;

const STORAGE_KEY = 'ner-tasks';
const AVG_RESPONSE_KEY = 'ner-avg-response-minutes';
// Post-completion states still count as completed work; a rejected verification does not.
const COMPLETED: TaskStatus[] = ['Completed', 'Awaiting Verification', 'Verified'];
const TASKS_CHANGED = 'ner-tasks-changed';

function readTasks(): StoredTask[] {
  if (typeof window === 'undefined') return [];
  try {
    const value = window.localStorage.getItem(STORAGE_KEY);
    if (!value) return [];
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function publish(tasks: StoredTask[]) {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(tasks));
  getAvgResponseMinutes(tasks); // side effect: saves the average when valid, so it outlives later task changes
  window.dispatchEvent(new CustomEvent(TASKS_CHANGED, { detail: tasks }));
}

/** Mean minutes from start (else assignment) to completion over completed, officer-handled tasks; null when none are valid. */
function averageResponseMinutes(tasks: StoredTask[]): number | null {
  const durations = tasks
    .filter(task => task.assignedOfficer && COMPLETED.includes(task.status))
    .map(task => Date.parse(task.completedAt ?? '') - Date.parse(task.startedAt ?? task.assignedAt ?? ''))
    .filter(ms => ms >= 0); // NaN (missing/invalid timestamp) fails this and is dropped
  return durations.length ? Math.round(durations.reduce((sum, ms) => sum + ms, 0) / durations.length / 60000) : null;
}

/** Fresh average from the given tasks (and remembered), else the last valid one saved; null only if there has never been one. */
export function getAvgResponseMinutes(tasks: StoredTask[] = readTasks()): number | null {
  const fresh = averageResponseMinutes(tasks);
  try {
    if (fresh !== null) {
      window.localStorage.setItem(AVG_RESPONSE_KEY, String(fresh));
      return fresh;
    }
    const saved = parseFloat(window.localStorage.getItem(AVG_RESPONSE_KEY) ?? '');
    return Number.isFinite(saved) ? saved : null;
  } catch {
    return fresh;
  }
}

function createTaskId() {
  return `TSK-${Date.now().toString().slice(-6)}`;
}

export function getTasks() {
  return readTasks();
}

export function createTaskFromIncident(input: {
  incidentId: string;
  title: string;
  location: string;
  priority: Severity;
  description: string;
  assignedOfficer?: string;
}) {
  const task: StoredTask = {
    id: createTaskId(),
    title: input.title,
    location: input.location,
    priority: input.priority,
    assignedOfficer: input.assignedOfficer ?? 'FO-1024',
    assignedAt: new Date().toISOString(),
    created: new Date().toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' }),
    deadline: 'Pending review',
    status: 'New',
    relatedIncident: input.incidentId,
    description: input.description,
  };
  publish([...readTasks(), task]);
  return task;
}

export function updateTask(id: string, updates: Partial<Pick<Task, 'status' | 'assignedOfficer'>>) {
  // Verification outcomes only come from reviewTask (District Officer).
  if (updates.status === 'Verified' || updates.status === 'Rejected') return;
  const now = new Date().toISOString();
  publish(readTasks().map(task => {
    if (task.id !== id) return task;
    const next = { ...task, ...updates };
    if (updates.assignedOfficer && updates.assignedOfficer !== task.assignedOfficer) next.assignedAt = now;
    if (updates.status === 'In Progress' && !task.startedAt) next.startedAt = now;
    if (updates.status === 'Completed' && !task.completedAt) next.completedAt = now;
    return next;
  }));
}

/** Field Officer: send a completed task to the District Officer for verification. */
export function requestTaskVerification(id: string) {
  publish(readTasks().map(task => task.id === id && task.status === 'Completed'
    ? { ...task, status: 'Awaiting Verification' }
    : task));
}

/** District Officer only: approve or reject a pending verification request. */
export function reviewTask(id: string, approve: boolean, reason = '') {
  if (profileService.getCurrentRole() !== 'district') return;
  publish(readTasks().map(task => task.id === id && task.status === 'Awaiting Verification'
    ? { ...task, status: approve ? 'Verified' : 'Rejected', verificationNote: approve ? undefined : reason.trim() || undefined }
    : task));
}

export function subscribeToTasks(listener: (tasks: StoredTask[]) => void) {
  if (typeof window === 'undefined') return () => {};
  const notify = () => listener(readTasks());
  window.addEventListener(TASKS_CHANGED, notify);
  window.addEventListener('storage', notify);
  return () => {
    window.removeEventListener(TASKS_CHANGED, notify);
    window.removeEventListener('storage', notify);
  };
}
