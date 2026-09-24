import type { Role } from '@/roles';
import { profileService, type ProfileMeta } from '@/lib/profileService';
import { supabase } from '@/lib/supabase';

/**
 * Sign-in for the officer website.
 *
 * Supabase Auth checks the password and the database decides the role (SRS AUTH-001,
 * AUTH-003). There is no local or demo fallback: without a verified Supabase session
 * nobody reaches a dashboard.
 */
export type SessionSource = 'supabase' | 'demo-offline';

export type SignInResult =
  | { ok: true; role: Role; source: SessionSource }
  | { ok: false; message: string };

const SOURCE_KEY = 'ner-session-source';

export const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const DB_ROLES: Record<string, Role> = {
  field_officer: 'field',
  district_officer: 'district',
  control_room: 'control',
};

const ROLE_LABELS: Record<Role, string> = {
  control: 'Control Officer',
  district: 'District Officer',
  field: 'Field Officer',
};

function setSource(source: SessionSource | null) {
  try {
    if (source) window.localStorage.setItem(SOURCE_KEY, source);
    else window.localStorage.removeItem(SOURCE_KEY);
  } catch {
    /* storage unavailable: the session still works for this page load */
  }
}

export function getSessionSource(): SessionSource | null {
  try {
    const v = window.localStorage.getItem(SOURCE_KEY);
    return v === 'supabase' || v === 'demo-offline' ? v : null;
  } catch {
    return null;
  }
}

/** Network failure, timeout or server error — as opposed to rejected credentials. */
function isUnreachable(error: { name?: string; status?: number; message?: string }): boolean {
  if (error.name === 'AuthRetryableFetchError') return true;
  const status = error.status ?? 0;
  if (status === 0 || status >= 500) return true;
  return /failed to fetch|network|load failed|timeout/i.test(error.message ?? '');
}

function initials(name: string): string {
  return name.split(/\s+/).filter(Boolean).map((p) => p[0]).join('').slice(0, 2).toUpperCase() || 'NE';
}

/** Role and profile from the database for the signed-in user. */
async function loadAccount(): Promise<{ role: Role } | { error: string }> {
  if (!supabase) return { error: 'The sign-in service is not configured for this build.' };
  const { data: userData } = await supabase.auth.getUser();
  const user = userData.user;
  if (!user) return { error: 'Your session has expired. Please sign in again.' };

  const [{ data: dbRole }, { data: district }, { data: prof }, { data: ownRole }] = await Promise.all([
    supabase.rpc('my_role'),
    supabase.rpc('my_district_name'),
    supabase.from('profiles').select('full_name, officer_id, phone, organization, department, region, is_active')
      .eq('id', user.id).maybeSingle(),
    supabase.from('user_roles').select('role, is_active').eq('user_id', user.id).maybeSingle(),
  ]);

  if (dbRole === 'rider') {
    return { error: 'Rider accounts use the NER Logistics mobile app.' };
  }
  const role = typeof dbRole === 'string' ? DB_ROLES[dbRole] : undefined;
  if (prof?.is_active === false) {
    return { error: 'Your account request was not approved. Contact your district administrator.' };
  }
  if (!role && ownRole && !ownRole.is_active) {
    return {
      error: ownRole.role === 'field_officer'
        ? 'Your account is awaiting approval from your District Officer or the Control Room.'
        : 'Your account is awaiting approval from the Control Room.',
    };
  }
  if (!role) {
    return { error: 'Your account has no active operational role. Contact your district administrator.' };
  }

  const name = prof?.full_name || user.email || 'Officer';
  // The avatar isn't in the `profiles` table yet, so carry over whatever was
  // saved locally for this account (profileService persists it across logins).
  const savedAvatar = user.email ? profileService.findAccount(user.email)?.avatarUrl : undefined;
  const profile: ProfileMeta = {
    label: ROLE_LABELS[role],
    profileName: name,
    profileInitials: initials(name),
    officerId: prof?.officer_id ?? '',
    // Department is display-only, so the sign-up metadata is an acceptable fallback here.
    department: prof?.department ?? prof?.organization ?? (user.user_metadata?.department as string | undefined) ?? '',
    region: (district as string | null) ?? prof?.region ?? 'North Eastern Region',
    district: (district as string | null) ?? undefined,
    phone: prof?.phone ?? '',
    email: user.email ?? '',
    lastLogin: `Today, ${new Date().toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })} IST`,
    status: 'Active',
    avatarUrl: savedAvatar,
  };
  profileService.adoptProfile(profile, role);
  return { role };
}

export async function signIn(identity: string, password: string): Promise<SignInResult> {
  const email = identity.trim();
  if (!email || !password) return { ok: false, message: 'Enter your email and password to continue.' };
  if (!EMAIL_PATTERN.test(email)) return { ok: false, message: 'Enter a valid email address.' };
  if (!supabase) return { ok: false, message: 'The sign-in service is not configured for this build.' };

  let error: { name?: string; status?: number; message?: string; code?: string } | null = null;
  try {
    ({ error } = await supabase.auth.signInWithPassword({ email, password }));
  } catch (e) {
    error = { name: 'AuthRetryableFetchError', message: String(e) };
  }
  if (error) {
    if (isUnreachable(error)) return { ok: false, message: 'Unable to reach the sign-in service. Check your connection and try again.' };
    if (error.code === 'email_not_confirmed') return { ok: false, message: 'Confirm your email address using the link we sent you, then log in.' };
    return { ok: false, message: 'Invalid email or password.' };
  }

  const account = await loadAccount();
  if ('error' in account) {
    await supabase.auth.signOut().catch(() => undefined);
    return { ok: false, message: account.error };
  }
  setSource('supabase');
  return { ok: true, role: account.role, source: 'supabase' };
}

const REQUESTED_ROLES: Record<Role, string> = {
  field: 'field_officer',
  district: 'district_officer',
  control: 'control_room',
};

export type SignUpResult = { ok: true; needsConfirmation: boolean } | { ok: false; message: string };

/**
 * Creates the account in Supabase Auth. The `on_auth_user_created` trigger turns the metadata into the
 * profile and role rows; district and control-room roles start inactive until an administrator approves them.
 */
export async function signUp(input: {
  email: string; password: string; fullName: string; role: Role; state?: string; district?: string; department?: string;
}): Promise<SignUpResult> {
  if (!supabase) return { ok: false, message: 'The sign-in service is not configured for this build.' };

  let result: Awaited<ReturnType<typeof supabase.auth.signUp>>;
  try {
    result = await supabase.auth.signUp({
      email: input.email.trim(),
      password: input.password,
      options: {
        data: {
          full_name: input.fullName.trim(),
          requested_role: REQUESTED_ROLES[input.role],
          state: input.state ?? '',
          district: input.district ?? '',
          department: input.department?.trim() ?? '',
        },
      },
    });
  } catch {
    return { ok: false, message: 'Unable to reach the sign-in service. Check your connection and try again.' };
  }

  const { data, error } = result;
  if (error) {
    if (isUnreachable(error)) return { ok: false, message: 'Unable to reach the sign-in service. Check your connection and try again.' };
    if (error.code === 'user_already_exists' || error.code === 'email_exists') return { ok: false, message: 'An account with this email already exists. Log in instead.' };
    if (error.code === 'weak_password') return { ok: false, message: error.message || 'Choose a stronger password.' };
    if (error.code === 'email_address_invalid') return { ok: false, message: 'Enter a valid email address.' };
    if (error.code === 'over_email_send_rate_limit' || error.code === 'over_request_rate_limit') return { ok: false, message: 'Too many sign-up attempts. Please try again later.' };
    return { ok: false, message: 'Could not create the account. Please try again.' };
  }
  // The form tells people to log in next, so don't leave a session the app isn't tracking.
  if (data.session) await supabase.auth.signOut().catch(() => undefined);
  return { ok: true, needsConfirmation: !data.session };
}

/** Restores the session on page load; null means "show the login screen". */
export async function restoreSession(): Promise<{ role: Role; source: SessionSource } | null> {
  const source = getSessionSource();
  if (source !== 'supabase' || !supabase) {
    profileService.clearSession();
    setSource(null);
    return null;
  }
  const { data } = await supabase.auth.getSession();
  if (!data.session) {
    profileService.clearSession();
    setSource(null);
    return null;
  }
  try {
    const account = await loadAccount();
    if ('error' in account) {
      await signOut();
      return null;
    }
    return { role: account.role, source };
  } catch {
    // Can't verify the session with Supabase, so don't trust anything stored locally.
    return null;
  }
}

export async function signOut(): Promise<void> {
  if (supabase) await supabase.auth.signOut().catch(() => undefined);
  profileService.clearSession();
  setSource(null);
}

/** Calls `onEnd` when the Supabase session ends (logout in another tab, revoked or expired refresh token). */
export function watchSessionEnd(onEnd: () => void): () => void {
  if (!supabase) return () => {};
  const { data } = supabase.auth.onAuthStateChange((event) => {
    if (event === 'SIGNED_OUT') onEnd();
  });
  return () => data.subscription.unsubscribe();
}
