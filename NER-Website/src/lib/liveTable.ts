import type { RealtimeChannel } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { notify } from '@/lib/notify';

/**
 * In-memory mirror of one Supabase table for the signed-in user: loaded on sign-in, kept fresh
 * by Realtime (postgres_changes, filtered by RLS), cleared on sign-out. Reads are synchronous so
 * pages can keep `useState(() => getX())`; writes are optimistic and roll back with a toast.
 */
type Row = { id: string; created_at?: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const tables: LiveTable<Row, unknown>[] = [];
const names = new Map<string, string>();
let me: string | null = null;
let started = false;

/** The signed-in user's id, or null before the session has loaded. */
export const myUserId = () => me;

/** Display label for a user id: officer ID, else full name, else a short id. */
export function officerLabel(id: string | null | undefined): string | null {
  return id ? names.get(id) ?? `User ${id.slice(0, 8)}` : null;
}

/** A user id from a uuid, officer ID or name; undefined when nobody matches. */
export function resolveOfficer(value: string | null): string | null | undefined {
  if (value === null || UUID.test(value)) return value;
  const key = value.trim().toLowerCase();
  for (const [id, label] of names) if (label.toLowerCase() === key) return id;
  return undefined;
}

/** Field officers the signed-in user can see (their district, or all for the control room). */
export async function listFieldOfficers(): Promise<{ id: string; label: string }[]> {
  if (!supabase) return [];
  const { data, error } = await supabase.from('user_roles').select('user_id').eq('role', 'field_officer').eq('is_active', true);
  if (error) { notify(`Could not load officers: ${error.message}`, { tone: 'error' }); return []; }
  return (data ?? []).map(r => ({ id: r.user_id as string, label: officerLabel(r.user_id)! }));
}

async function loadNames() {
  const { data } = await supabase!.from('profiles').select('id, full_name, officer_id');
  for (const p of data ?? []) names.set(p.id, p.officer_id || p.full_name || `User ${String(p.id).slice(0, 8)}`);
}

function start() {
  if (started || !supabase) return;
  started = true;
  supabase.auth.onAuthStateChange((_event, session) => {
    const uid = session?.user.id ?? null;
    if (uid === me) return;
    me = uid;
    names.clear();
    tables.forEach(t => t.reset());
    // Supabase calls inside this callback can deadlock the auth lock, so defer them.
    if (uid) setTimeout(() => { loadNames().finally(() => tables.forEach(t => t.load())); }, 0);
  });
}

export const errorText = (e: unknown) => (e && typeof e === 'object' && 'message' in e ? String((e as { message: unknown }).message) : String(e));

export class LiveTable<R extends Row, T> {
  private rows: R[] = [];
  private view: T[] = [];
  private listeners = new Set<(items: T[]) => void>();
  private channel: RealtimeChannel | null = null;

  constructor(private table: string, private toView: (row: R) => T) {
    tables.push(this as unknown as LiveTable<Row, unknown>);
  }

  items(): T[] { start(); return this.view; }
  row(id: string): R | undefined { return this.rows.find(r => r.id === id); }
  allRows(): R[] { return this.rows; }

  subscribe(listener: (items: T[]) => void): () => void {
    start();
    this.listeners.add(listener);
    listener(this.view); // catch up on anything loaded between the first render and this subscription
    return () => { this.listeners.delete(listener); };
  }

  /** Recompute the view (e.g. after names or signed URLs arrive) and notify listeners. */
  refresh() {
    this.view = this.rows.map(this.toView);
    this.listeners.forEach(l => l(this.view));
  }

  put(row: R) {
    const i = this.rows.findIndex(r => r.id === row.id);
    if (i >= 0) this.rows[i] = { ...this.rows[i], ...row };
    else this.rows.push(row);
    this.rows.sort((a, b) => (a.created_at ?? '').localeCompare(b.created_at ?? ''));
    this.refresh();
  }

  remove(id: string) {
    this.rows = this.rows.filter(r => r.id !== id);
    this.refresh();
  }

  reset() {
    if (this.channel) void supabase?.removeChannel(this.channel);
    this.channel = null;
    this.rows = [];
    this.refresh();
  }

  async load() {
    if (!supabase) return;
    this.channel = supabase.channel(`live-${this.table}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: this.table }, payload => {
        if (payload.eventType === 'DELETE') this.remove((payload.old as R).id);
        else this.put(payload.new as R);
      })
      .subscribe();
    const { data, error } = await supabase.from(this.table).select('*').order('created_at');
    if (error) { notify(`Could not load ${this.table.replace('_', ' ')}: ${error.message}`, { tone: 'error' }); return; }
    this.rows = (data ?? []) as R[];
    this.refresh();
  }

  /** Optimistic insert: shows the row now, replaces it with the server row, removes it on failure. */
  async insert(row: R, what: string): Promise<boolean> {
    this.put(row);
    const { created_at: _clientTime, ...body } = row; // the server stamps created_at
    const { data, error } = await supabase!.from(this.table).insert(body as never).select().single();
    if (error) { this.remove(row.id); notify(`${what} was not saved: ${error.message}`, { tone: 'error' }); return false; }
    this.put(data as R);
    return true;
  }

  /** Optimistic update: applies the patch now, takes the server row (trigger-set fields), rolls back on failure. */
  async update(id: string, patch: Partial<R>, what: string): Promise<boolean> {
    const before = this.row(id);
    if (!before || !supabase) return false;
    this.put({ ...before, ...patch });
    const { data, error } = await supabase.from(this.table).update(patch as never).eq('id', id).select().single();
    if (error) { this.put(before); notify(`${what} failed: ${error.message}`, { tone: 'error' }); return false; }
    this.put(data as R);
    return true;
  }
}
