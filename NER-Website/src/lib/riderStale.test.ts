// Run: node --test src/lib/riderStale.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isStale, STALE_MINUTES } from './riderStale.ts';

test('stale-rider window', () => {
  const now = Date.parse('2026-09-27T10:00:00Z');
  assert.equal(isStale('2026-09-27T09:59:00Z', now), false);
  assert.equal(isStale(new Date(now - STALE_MINUTES * 60_000).toISOString(), now), false); // exactly at the edge
  assert.equal(isStale(new Date(now - STALE_MINUTES * 60_000 - 1000).toISOString(), now), true);
  assert.equal(isStale('2026-09-27T09:55:00Z', now, 2), true);
  assert.equal(isStale('garbage', now), true);
});
