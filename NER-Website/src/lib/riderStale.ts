/** A rider whose last GPS fix is older than this is shown greyed as stale. Matches get_active_riders' default. */
export const STALE_MINUTES = 30;

/** True when the fix at `recordedAt` (ISO string) is older than `minutes` at `now` (ms). Unparseable = stale. */
export function isStale(recordedAt: string, now: number, minutes = STALE_MINUTES): boolean {
  const t = Date.parse(recordedAt);
  return Number.isNaN(t) || now - t > minutes * 60_000;
}
