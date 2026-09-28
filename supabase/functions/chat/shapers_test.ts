// Runs under Node (node --test --experimental-strip-types) and Deno (deno test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clusterByAlong, shapeRouteRisk } from './shapers.ts';

const seg = (along_m: number, over: Record<string, unknown> = {}) => ({
  segment_id: `SEG${along_m}`,
  along_m,
  lat: 26.8,
  lon: 88.4,
  risk_percentile: 99.5,
  tier: 'alert' as const,
  steep: false,
  ...over,
});

test('clusterByAlong splits on gaps larger than the tolerance', () => {
  const runs = clusterByAlong([seg(0), seg(500), seg(1000), seg(9000), seg(9500)], 2000);
  assert.equal(runs.length, 2);
  assert.equal(runs[0].length, 3);
  assert.equal(runs[1].length, 2);
});

test('clusterByAlong sorts unordered input before grouping', () => {
  const runs = clusterByAlong([seg(9000), seg(0), seg(500)], 2000);
  assert.equal(runs.length, 2);
  assert.deepEqual(runs[0].map((s) => s.along_m), [0, 500]);
});

test('clusterByAlong drops segments with no along_m', () => {
  const runs = clusterByAlong([seg(0), { ...seg(1), along_m: undefined } as any], 2000);
  assert.equal(runs.flat().length, 1);
});

/** Stands in for the 640-segment route in SRS §8.3. */
function bigRoute() {
  const segments: any[] = [];
  for (let i = 0; i < 640; i++) {
    segments.push(
      seg(i * 800, {
        tier: i % 32 < 3 ? 'alert' : 'none', // 20 separated risky clusters
        risk_percentile: 90 + (i % 32) / 10,
        steep: i % 64 === 0,
      }),
    );
  }
  return {
    state: 'replay',
    score_date: '2025-08-05',
    model_version: 'final_v3',
    route_id: 'RT-NH10',
    route_length_m: 517_636,
    coverage_fraction: 0.5559,
    summary: {
      n_matched: 640,
      n_alert: 60,
      n_human_review: 131,
      max_percentile: 99.9961,
      band: 'high',
      worst: { ...seg(79_488), risk_percentile: 99.9961, tier: 'human_review', steep: true } as any,
    },
    segments,
  };
}

test('shapeRouteRisk caps stretches at 6 and stays small', () => {
  const out = shapeRouteRisk(bigRoute());
  assert.ok(out.risky_stretches.length <= 6, `got ${out.risky_stretches.length} stretches`);
  // ~4 chars/token, so 2400 chars ~= 600 tokens: bounded regardless of route length.
  const size = JSON.stringify(out).length;
  assert.ok(size < 2400, `shaped output is ${size} chars, too large for context`);
});

test('shapeRouteRisk never leaks raw_score or p_calibrated', () => {
  // The model calls these a probability the moment it sees them (prompt rule 2).
  const route = bigRoute();
  route.segments = route.segments.map((s) => ({ ...s, raw_score: 0.42, p_calibrated: 0.31 }));
  route.summary.worst.p_calibrated = 0.99;
  const serialised = JSON.stringify(shapeRouteRisk(route));
  assert.ok(!serialised.includes('p_calibrated'), 'p_calibrated leaked into model context');
  assert.ok(!serialised.includes('raw_score'), 'raw_score leaked into model context');
});

test('shapeRouteRisk keeps the route-level facts the officer needs', () => {
  const out = shapeRouteRisk(bigRoute());
  assert.equal(out.length_km, 518);
  assert.equal(out.coverage_pct, 56);
  assert.equal(out.band, 'high');
  assert.equal(out.worst.at_km, 79);
});

test('shapeRouteRisk omits risky_stretches when nothing is risky', () => {
  const out = shapeRouteRisk({
    state: 'replay',
    route_id: 'RT-SAFE',
    route_length_m: 40_000,
    coverage_fraction: 1,
    summary: { n_matched: 50, n_alert: 0, n_human_review: 0, max_percentile: 12, band: 'low', worst: null },
    segments: [seg(0, { tier: 'none' }), seg(800, { tier: 'none' })],
  });
  assert.equal(out.risky_stretches, undefined);
  assert.equal(out.band, 'low');
});

test('shapeRouteRisk handles a null result', () => {
  assert.ok('error' in shapeRouteRisk(null));
});
