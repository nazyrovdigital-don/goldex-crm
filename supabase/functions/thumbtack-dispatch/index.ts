// Sends queued Thumbtack messages (automatic responses, retries, owner replies).
// Called every 15 seconds by pg_cron (see tt_setup_dispatch in 0009_thumbtack.sql)
// with the x-dispatch-secret header. Deploy with --no-verify-jwt.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatchOutbox, makeThumbtackClient, makeTokenProvider, safeEqual } from '../_shared/thumbtack.js';

Deno.serve(async (req) => {
  const secret = Deno.env.get('TT_DISPATCH_SECRET');
  if (!secret || !safeEqual(req.headers.get('x-dispatch-secret') ?? '', secret)) {
    return new Response('{"error":"unauthorized"}', { status: 401 });
  }
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  };
  const getToken = makeTokenProvider({ rpc, tokenUrl: Deno.env.get('TT_TOKEN_URL') ?? 'https://auth.thumbtack.com/oauth2/token',
    clientId: Deno.env.get('TT_CLIENT_ID') ?? '', clientSecret: Deno.env.get('TT_CLIENT_SECRET') ?? '' });
  const sendMessage = makeThumbtackClient({ apiBase: Deno.env.get('TT_API_BASE') ?? 'https://pro-api.thumbtack.com',
    sendPath: Deno.env.get('TT_SEND_PATH') ?? '/api/v4/negotiations/{negotiationID}/messages', getToken });
  try {
    const results = await dispatchOutbox({ rpc, sendMessage });
    return new Response(JSON.stringify({ ok: true, processed: results.length, results }), { headers: { 'Content-Type': 'application/json' } });
  } catch (e) {
    console.error('dispatch failed', e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
