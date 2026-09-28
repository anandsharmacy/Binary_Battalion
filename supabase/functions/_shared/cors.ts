/**
 * CORS for browser callers (the Vite SPA). The Flutter app doesn't need this.
 *
 * `apikey` must be in Allow-Headers: supabase-js sends it on every request, and
 * omitting it is the classic "works in curl, fails in the browser" failure.
 *
 * CHAT_ALLOWED_ORIGINS is a comma-separated list; set it to the deployed web
 * origin. Unset, only localhost dev servers are allowed.
 */

const DEV_ORIGINS = ['http://localhost:5173', 'http://127.0.0.1:5173', 'http://localhost:8443'];

const allowed = new Set([
  ...DEV_ORIGINS,
  ...(Deno.env.get('CHAT_ALLOWED_ORIGINS') ?? '')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean),
]);

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') ?? '';
  return {
    'Access-Control-Allow-Origin': allowed.has(origin) ? origin : DEV_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}

export const corsPreflight = (req: Request) => new Response(null, { status: 204, headers: corsHeaders(req) });
