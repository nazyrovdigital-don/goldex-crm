// GOLDEX website → CRM lead intake (Supabase Edge Function, Deno).
//
// The website quote form POSTs here. This function validates the submission,
// drops obvious spam, and calls intake_website_lead() with the service-role
// key (which never leaves the server). That database function creates or
// matches the customer, the property and the lead; the lead.created
// automation then creates the urgent contact task, owner notification and
// 15 min / 30 min / 2 hr response reminders.
//
// Optional email (set RESEND_API_KEY + OWNER_EMAIL + FROM_EMAIL secrets):
// owner alert + customer confirmation. Without them, the in-CRM notification
// still fires.
import { createClient } from 'npm:@supabase/supabase-js@2';

const ALLOWED = (Deno.env.get('ALLOWED_ORIGINS') ?? 'https://goldexconst.com,https://www.goldexconst.com')
  .split(',').map((s) => s.trim());

const cors = (origin: string | null) => ({
  'Access-Control-Allow-Origin': origin && ALLOWED.includes(origin) ? origin : ALLOWED[0],
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type',
  Vary: 'Origin',
});

// Website dropdown labels → CRM service types (so lead scoring recognises core services).
const SERVICE_MAP: Record<string, string> = {
  'Drywall & Interior Finish': 'Drywall',
  'Doors & Interior Installation': 'Door Installation',
};

const clip = (v: unknown, n: number) => (typeof v === 'string' ? v.trim().slice(0, n) : '');
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

async function sendEmail(to: string, subject: string, html: string) {
  const key = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('FROM_EMAIL');
  if (!key || !from || !to) return;
  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to, subject, html }),
  }).catch((e) => console.error('email failed', e));
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  const headers = { ...cors(origin), 'Content-Type': 'application/json' };
  if (req.method === 'OPTIONS') return new Response(null, { headers });
  if (req.method !== 'POST') return new Response('{"error":"POST only"}', { status: 405, headers });
  if (origin && !ALLOWED.includes(origin)) return new Response('{"error":"origin not allowed"}', { status: 403, headers });

  let raw: Record<string, unknown>;
  try {
    const type = req.headers.get('content-type') ?? '';
    raw = type.includes('application/json') ? await req.json() : Object.fromEntries(await req.formData());
  } catch {
    return new Response('{"error":"bad request"}', { status: 400, headers });
  }

  // Honeypot: a hidden field real people never fill in. Pretend success to bots.
  if (clip(raw.company_website, 200)) return new Response('{"ok":true}', { headers });

  // goldexconst.com sends one "name" field and the service as "type";
  // first_name / last_name / service are also accepted.
  const full = clip(raw.name, 160);
  const [first, ...rest] = full.split(/\s+/);
  const service = clip(raw.service, 120) || clip(raw.type, 120);
  const lead = {
    first_name: clip(raw.first_name, 80) || first || '', last_name: clip(raw.last_name, 80) || rest.join(' '),
    phone: clip(raw.phone, 40), email: clip(raw.email, 200).toLowerCase(),
    address: clip(raw.address, 300), service: SERVICE_MAP[service] ?? service, details: clip(raw.details, 4000),
    source: 'Website', source_page: clip(raw.source_page, 300),
    utm_source: clip(raw.utm_source, 100), utm_medium: clip(raw.utm_medium, 100), utm_campaign: clip(raw.utm_campaign, 150),
  };
  if (!lead.first_name && !lead.last_name) return new Response('{"error":"Name is required"}', { status: 422, headers });
  if (lead.phone.replace(/\D/g, '').length < 10 && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(lead.email)) {
    return new Response('{"error":"A valid phone or email is required"}', { status: 422, headers });
  }

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc('intake_website_lead', { p: lead });
  if (error) {
    console.error('intake failed', error);
    return new Response('{"error":"Could not save your request. Please call (858) 428-0124."}', { status: 500, headers });
  }

  const name = esc(`${lead.first_name} ${lead.last_name}`.trim());
  await Promise.all([
    sendEmail(Deno.env.get('OWNER_EMAIL') ?? '', `New lead: ${name} — ${lead.service || 'quote request'}`,
      `<p><b>${name}</b> · ${esc(lead.phone)} · ${esc(lead.email)}</p><p>${esc(lead.address)}</p>
       <p><b>${esc(lead.service)}</b><br>${esc(lead.details).replace(/\n/g, '<br>')}</p><p>${data?.lead_number ?? ''} — call within 15 minutes.</p>`),
    lead.email && sendEmail(lead.email, 'We got your request — GOLDEX Construction',
      `<p>Hi ${esc(lead.first_name)},</p><p>Thanks for reaching out about ${esc(lead.service || 'your project')}.
       We'll call or text you within the hour during business hours.</p><p>— GOLDEX Construction · (858) 428-0124</p>`),
  ]);

  return new Response(JSON.stringify({ ok: true, lead: data?.lead_number }), { headers });
});
