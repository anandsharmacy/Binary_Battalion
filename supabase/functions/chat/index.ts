/**
 * Read-only operations assistant. One endpoint for both the Flutter app and the
 * website.
 *
 * Security model: this function holds NO service-role key. It builds one
 * supabase-js client per request from the anon/publishable key plus the caller's
 * own JWT, so auth.uid() resolves and every RPC's internal role check applies to
 * every tool call. The LLM chooses which tool to call — it must never be able to
 * choose a privilege.
 *
 * Streams text/plain (not SSE) so the web and Flutter readers are identical.
 */

import { createClient } from 'npm:@supabase/supabase-js@2';
import { streamText, stepCountIs } from 'npm:ai@5';
import { createGroq } from 'npm:@ai-sdk/groq@2';
import { corsHeaders, corsPreflight } from '../_shared/cors.ts';
import { buildSystemPrompt, type DbRole } from './prompt.ts';
import { makeTools } from './tools.ts';

// Groq free-tier models with tool calling, tried in order per key. Each has its own 8K
// tokens-per-minute limit (~2 questions a minute), so falling back multiplies throughput.
// CHAT_MODELS="m1,m2" overrides the list.
const MODELS = [
  ...new Set(
    (Deno.env.get('CHAT_MODELS') ?? 'openai/gpt-oss-120b,qwen/qwen3.8-27b,openai/gpt-oss-20b')
      .split(',')
      .map((m) => m.trim())
      .filter(Boolean),
  ),
];
// Groq answers in seconds; a try that stalls past this is cut and the next model is tried.
const ATTEMPT_MS = 20_000;
const BUDGET_MS = 45_000; // all tries together, well under the Edge Function's 150 s wall-clock limit
const MAX_BODY_BYTES = 32_768;

// Keys tried in order: GROQ_API_KEYS="k1,k2" (falls back to GROQ_API_KEY). Groq limits are per
// organization, so extra keys only help if they come from separate Groq orgs.
const KEYS = (Deno.env.get('GROQ_API_KEYS') ?? Deno.env.get('GROQ_API_KEY') ?? '')
  .split(',')
  .map((k) => k.trim())
  .filter(Boolean);
// ponytail: per-isolate memory, so a fresh isolate re-probes a spent key once. Move to a table
// if the wasted first call ever shows up in latency.
const spentUntil = new Map<string, number>();
const SPENT_MS = 60_000;
const errText = (e: unknown) => String((e as Error)?.message ?? e);
const isQuota = (e: unknown) => /quota|rate.?limit|RESOURCE_EXHAUSTED|429|credits/i.test(errText(e));
const isBusy = (e: unknown) => /high demand|overloaded|capacity|UNAVAILABLE|503|timed out/i.test(errText(e));
const MAX_HISTORY = 12;

const json = (body: unknown, status: number, req: Request) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsPreflight(req);
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, req);

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized' }, 401, req);

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: 'payload_too_large' }, 413, req);

  let body: { messages?: { role: string; content: string }[]; language?: string };
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad_request' }, 400, req);
  }
  const messages = (body.messages ?? []).filter(
    (m) => (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string' && m.content.trim(),
  );
  if (!messages.length) return json({ error: 'bad_request' }, 400, req);

  // The publishable key. Never SUPABASE_SERVICE_ROLE_KEY: that sets
  // role = service_role and auth.uid() = NULL, which would defeat every role
  // check the RPCs rely on.
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SB_PUBLISHABLE_KEY');
  if (!anonKey) {
    console.error('no anon/publishable key in env');
    return json({ error: 'misconfigured' }, 500, req);
  }

  // Built inside the handler, with persistSession off: Deno isolates are reused
  // across requests, and a persisted session would leak one user's auth into the
  // next user's request.
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return json({ error: 'unauthorized' }, 401, req);

  // Needed for every answer, so they're prompt facts rather than tools — one
  // round trip instead of an extra model step. JWT claims won't do: my_role()
  // reads profiles, where role and is_active actually live.
  const [roleRes, districtRes, statusRes, quotaRes] = await Promise.all([
    supabase.rpc('my_role'),
    supabase.rpc('my_district_name'),
    supabase.rpc('ml_status'),
    supabase.rpc('chat_quota_ok'),
  ]);

  const role = roleRes.data as DbRole | null;
  if (!role) {
    return json(
      { error: 'no_role', message: 'Your account has no active operational role. Contact your district administrator.' },
      403,
      req,
    );
  }
  if (statusRes.error) console.error('ml_status failed:', statusRes.error.message);
  // Fails open on an RPC error: a broken counter shouldn't take the assistant down.
  if (quotaRes.error) console.error('chat_quota_ok failed:', quotaRes.error.message);
  else if (quotaRes.data === false) return json({ error: 'rate_limited' }, 429, req);

  if (!KEYS.length) {
    console.error('GROQ_API_KEYS / GROQ_API_KEY not set');
    return json({ error: 'misconfigured' }, 500, req);
  }

  try {
    const run = (apiKey: string, model: string, abortSignal: AbortSignal) => streamText({
      model: createGroq({ apiKey })(model),
      maxRetries: 0, // a failing key or model fails fast and the next one is tried instead
      abortSignal,
      system: buildSystemPrompt({
        role,
        district: (districtRes.data as string | null) ?? null,
        status: statusRes.data ?? null,
        language: body.language,
      }),
      messages: messages.slice(-MAX_HISTORY) as { role: 'user' | 'assistant'; content: string }[],
      tools: makeTools(supabase),
      stopWhen: stepCountIs(5), // cost fuse: a confused model can loop tools until timeout
      temperature: 0.2, // a numbers-quoting assistant, not a writing one
      // Reasoning tokens count against this cap; at 700 they once crowded out the answer.
      // Answer length is bounded by prompt rule 8, not by this.
      maxOutputTokens: 4096,
      // reasoningEffort only applies to the gpt-oss reasoning models.
      providerOptions: model.startsWith('openai/gpt-oss') ? { groq: { reasoningEffort: 'low' } } : undefined,
      onError: ({ error }) => console.error('stream error:', error),
      onFinish: async ({ text, totalUsage: usage, steps, finishReason }) => {
        const tools = steps.flatMap((s) => s.toolCalls?.map((c) => c.toolName) ?? []);
        console.log(
          JSON.stringify({
            user: user.id,
            role,
            model,
            tokens_in: usage?.inputTokens,
            tokens_out: usage?.outputTokens,
            reasoning_tokens: usage?.reasoningTokens,
            finish: finishReason,
            tools,
          }),
        );
        // Audit row + rate-limit counter. Logged, never thrown: the answer has already streamed.
        const { error } = await supabase.from('chat_logs').insert({
          role,
          prompt: messages.findLast((m) => m.role === 'user')?.content,
          response: text,
          tools,
          tokens_in: usage?.inputTokens,
          tokens_out: usage?.outputTokens,
        });
        if (error) console.error('chat_logs insert failed:', error.message);
      },
    });

    // toTextStreamResponse ends silently on a model error, and the 200 is already sent, so a
    // mid-stream failure (e.g. a rate limit) reached users as a blank answer. Say it in-band.
    const enc = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      async start(c) {
        let wrote = false;
        let failed: unknown = null;
        // Every key+model pair, each key's models in order. Pairs that failed in the last minute go
        // last rather than being dropped, in case their quota or load has recovered.
        const now = Date.now();
        const deadline = now + BUDGET_MS;
        const spent = (id: string) => (spentUntil.get(id) ?? 0) > now;
        const pairs = KEYS.flatMap((key, i) => MODELS.map((model) => ({ key, model, id: `${i}|${model}` })));
        const order = [...pairs.filter((p) => !spent(p.id)), ...pairs.filter((p) => spent(p.id))];
        for (const { key, model, id } of order) {
          const left = deadline - Date.now();
          if (left < 5_000) break;
          failed = null;
          for await (const part of run(key, model, AbortSignal.timeout(Math.min(ATTEMPT_MS, left))).fullStream) {
            if (part.type === 'text-delta' && part.text) {
              c.enqueue(enc.encode(part.text));
              wrote = true;
            } else if (part.type === 'error') failed = part.error;
            // A timeout ends the stream with 'abort', not 'error' — without this it read as success.
            else if (part.type === 'abort') failed = new Error('timed out waiting for the model');
          }
          // Any failure before text went out (quota, depleted credits, revoked key, busy model,
          // timeout) moves to the next pair; tools are read-only RPCs, so a rerun is safe.
          if (!failed || wrote) break;
          spentUntil.set(id, Date.now() + SPENT_MS);
          console.warn(`${model} (key ${id.split('|')[0]}) failed:`, errText(failed).slice(0, 160));
        }
        if (failed) {
          c.enqueue(
            enc.encode(
              (wrote ? '\n\n' : '') +
                (isQuota(failed)
                  ? 'The assistant is at its usage limit right now. Please try again in a minute.'
                  : isBusy(failed)
                    ? 'The AI model is busy right now. Please try again in a minute.'
                    : 'The assistant hit an error before finishing. Please try again.'),
            ),
          );
        }
        c.close();
      },
    });
    return new Response(stream, {
      headers: { ...corsHeaders(req), 'Content-Type': 'text/plain; charset=utf-8' },
    });
  } catch (e) {
    console.error('model call failed:', e);
    return json(
      { error: 'assistant_unavailable', message: 'The assistant is unavailable right now. Route risk and alerts still work.' },
      502,
      req,
    );
  }
});
