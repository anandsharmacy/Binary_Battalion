/**
 * Assistant tools. Each one is an existing SECURITY DEFINER RPC that the web and
 * Flutter clients already call — the database, not the prompt, decides what the
 * caller may see. Results are shaped (see shapers.ts) before reaching the model.
 *
 * On failure a tool returns { error } rather than throwing, so the model reports
 * the failure instead of the function 500ing mid-stream.
 */

import { tool } from 'npm:ai@5';
import { z } from 'npm:zod@3';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { shapeRouteRisk, shapeRoutesSummary, shapeTopAlerts } from './shapers.ts';

async function call(sb: SupabaseClient, fn: string, args?: Record<string, unknown>) {
  const { data, error } = await sb.rpc(fn, args ?? {});
  return error ? { error: error.message } : { data };
}

export function makeTools(sb: SupabaseClient) {
  return {
    routesRiskSummary: tool({
      description:
        'ML disruption-risk summary for every stored route. Use this first for "which routes are risky", "what is riskiest today", or to look up a route_id by its name or number.',
      inputSchema: z.object({}),
      execute: async () => {
        const r = await call(sb, 'get_routes_ml_summary');
        return 'error' in r ? r : shapeRoutesSummary(r.data);
      },
    }),

    routeRisk: tool({
      description:
        'Detailed ML risk for ONE route, including which stretches (in km along the route) carry the risk. Call routesRiskSummary first to get the route_id.',
      inputSchema: z.object({
        route_id: z.string().describe('route_id as returned by routesRiskSummary'),
      }),
      execute: async ({ route_id }) => {
        const r = await call(sb, 'get_route_ml_risk', { p_route_id: route_id });
        return 'error' in r ? r : shapeRouteRisk(r.data);
      },
    }),

    topRiskSegments: tool({
      description:
        "Today's highest-risk individual road segments in the officer's scope, with the nearest place name. Officers only; riders will get a permission error.",
      inputSchema: z.object({
        tier: z
          .enum(['alert', 'human_review'])
          .default('alert')
          .describe('"alert" for high disruption risk, "human_review" for segments needing review'),
      }),
      execute: async ({ tier }) => {
        const r = await call(sb, 'get_ml_top_alerts', { p_tier: tier });
        return 'error' in r ? r : shapeTopAlerts(r.data);
      },
    }),
  };
}
