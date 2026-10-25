// Sends a CRM notification as a push to the user's enabled devices.
// Called by the notifications trigger (pg_net) with the x-push-secret header.
// Secrets: PUSH_SECRET, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:…)
// Deploy: supabase functions deploy push-send --no-verify-jwt
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from './webpush.js';

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

function linkFor(n: { entity_type: string | null; entity_id: string | null }) {
  if (n.entity_type === 'lead' && n.entity_id) return `./#/lead/${n.entity_id}`;
  if (n.entity_type === 'project' && n.entity_id) return `./#/project/${n.entity_id}`;
  if (n.entity_type === 'invoice' || n.entity_type === 'payment') return './#/invoices';
  return './#/dashboard';
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('PUSH_SECRET');
  const given = req.headers.get('x-push-secret') ?? '';
  if (!secret || given.length !== secret.length || !crypto.subtle) return json({ error: 'unauthorized' }, 401);
  let diff = 0; for (let i = 0; i < secret.length; i++) diff |= secret.charCodeAt(i) ^ given.charCodeAt(i);
  if (diff) return json({ error: 'unauthorized' }, 401);

  const { notification_id } = await req.json().catch(() => ({}));
  if (!notification_id) return json({ error: 'notification_id required' }, 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: n } = await sb.from('notifications').select('*').eq('id', notification_id).maybeSingle();
  if (!n) return json({ error: 'not found' }, 404);

  // Addressed to one user, or (user_id null) to every active owner/admin.
  let userIds: string[] = n.user_id ? [n.user_id] : [];
  if (!n.user_id) {
    const { data: users } = await sb.from('users').select('id').eq('status', 'active').in('role', ['owner', 'admin']);
    userIds = (users ?? []).map((u: { id: string }) => u.id);
  }
  const { data: subs } = await sb.from('push_subscriptions').select('*').in('user_id', userIds);
  const vapid = { publicKey: Deno.env.get('VAPID_PUBLIC_KEY')!, privateKey: Deno.env.get('VAPID_PRIVATE_KEY')!,
                  subject: Deno.env.get('VAPID_SUBJECT') ?? 'mailto:olim@goldexconst.com' };
  const message = { title: n.title, body: n.body ?? '', url: linkFor(n), tag: n.entity_id ?? n.id };

  const results = await Promise.all((subs ?? []).map(async (s: any) => {
    try {
      const r = await sendPush({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, message, vapid);
      if (r.gone || (!r.ok && s.failed_count >= 4)) await sb.from('push_subscriptions').delete().eq('id', s.id);
      else await sb.from('push_subscriptions').update(r.ok ? { last_used_at: new Date().toISOString(), failed_count: 0 }
                                                          : { failed_count: s.failed_count + 1 }).eq('id', s.id);
      return r.status;
    } catch (e) {
      console.error('push failed', e);
      return 0;
    }
  }));
  return json({ ok: true, sent: results.filter((s) => s >= 200 && s < 300).length, devices: results.length });
});
