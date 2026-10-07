// Thumbtack → GOLDEX CRM webhook (leads + messages).
//
// Register this URL in Thumbtack (Pro account → webhooks, or via the partner
// API) for "lead / negotiation created" and "message created" events:
//   https://<ref>.supabase.co/functions/v1/thumbtack-webhook
// Authentication: HTTP Basic (TT_WEBHOOK_USER / TT_WEBHOOK_PASS), or
// ?token=<TT_WEBHOOK_TOKEN> if Thumbtack's form only takes a URL.
//
// Deploy with --no-verify-jwt (Thumbtack does not send a Supabase JWT).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { checkWebhookAuth, detectType, normalizeLead, normalizeMessage, dispatchOutbox, makeThumbtackClient,
         makeTokenProvider } from '../_shared/thumbtack.js';

const MAX_BODY = 512 * 1024;
const RATE = { windowMs: 60_000, max: 120 };       // per source IP, per function instance
const hits = new Map<string, number[]>();
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function rateLimited(ip: string) {
  const now = Date.now();
  const list = (hits.get(ip) ?? []).filter((t) => now - t < RATE.windowMs);
  list.push(now);
  hits.set(ip, list);
  return list.length > RATE.max;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0].trim() ?? 'unknown';
  if (rateLimited(ip)) return json({ error: 'rate limited' }, 429);

  const url = new URL(req.url);
  const authorized = checkWebhookAuth(
    { authorization: req.headers.get('authorization'), token: url.searchParams.get('token') },
    { user: Deno.env.get('TT_WEBHOOK_USER'), pass: Deno.env.get('TT_WEBHOOK_PASS'), secretToken: Deno.env.get('TT_WEBHOOK_TOKEN') },
  );
  if (!authorized) return json({ error: 'unauthorized' }, 401);

  const text = await req.text();
  if (text.length > MAX_BODY) return json({ error: 'payload too large' }, 413);
  let payload: Record<string, unknown>;
  try { payload = JSON.parse(text); } catch { return json({ error: 'invalid JSON' }, 400); }

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  };

  const receivedAt = new Date().toISOString();
  const type = detectType(payload);
  try {
    if (type === 'lead') {
      const lead = normalizeLead(payload, receivedAt);
      if (!lead.thumbtack_lead_id) return json({ error: 'lead id missing' }, 422);
      const r = await rpc('tt_ingest_lead', { p: lead });
      // Attempt 1 immediately, after acknowledging Thumbtack (retries via pg_cron).
      if (r?.outbox_id) EdgeRuntime.waitUntil(sendNow(rpc).catch((e) => console.error('immediate send failed', e)));
      return json({ ok: true, lead: r?.lead_number ?? null, created: r?.created ?? false });
    }
    if (type === 'message') {
      const msg = normalizeMessage(payload, receivedAt);
      if (!msg.thumbtack_lead_id) return json({ error: 'lead id missing' }, 422);
      await rpc('tt_ingest_message', { p: msg });
      return json({ ok: true });
    }
    // Reviews and unknown events are logged for later use, not processed.
    await sb.from('webhook_events').upsert({ provider: 'thumbtack', event_key: `${type}:${crypto.randomUUID()}`, event_type: type,
      status: 'ignored', raw_payload: payload }, { onConflict: 'provider,event_key' });
    return json({ ok: true, ignored: type });
  } catch (e) {
    console.error('thumbtack webhook failed', e);
    // 500 makes Thumbtack retry; ingestion is idempotent so retries are safe.
    return json({ error: 'processing failed' }, 500);
  }
});

function sendNow(rpc: (fn: string, args: Record<string, unknown>) => Promise<any>) {
  const cfg = { apiBase: Deno.env.get('TT_API_BASE') ?? 'https://pro-api.thumbtack.com',
                sendPath: Deno.env.get('TT_SEND_PATH') ?? '/api/v4/negotiations/{negotiationID}/messages' };
  const getToken = makeTokenProvider({ rpc, tokenUrl: Deno.env.get('TT_TOKEN_URL') ?? 'https://auth.thumbtack.com/oauth2/token',
    clientId: Deno.env.get('TT_CLIENT_ID') ?? '', clientSecret: Deno.env.get('TT_CLIENT_SECRET') ?? '' });
  return dispatchOutbox({ rpc, sendMessage: makeThumbtackClient({ ...cfg, getToken }) });
}
