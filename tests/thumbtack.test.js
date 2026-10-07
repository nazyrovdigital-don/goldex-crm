// Thumbtack integration — spec acceptance tests 1–7 plus security, run against
// real Postgres (PGlite) with a simulated Thumbtack API.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createDb, asUser, asService, one, all, val, OWNER } from './helpers.js';
import { normalizeLead, normalizeMessage, detectType, checkWebhookAuth, dispatchOutbox, makeThumbtackClient,
         makeTokenProvider } from '../supabase/functions/_shared/thumbtack.js';

let db;
const rpc = async (fn, args = {}) => {
  await asService(db);
  const k = Object.keys(args);
  const r = await db.query(`select public.${fn}(${k.map((x, i) => `${x} => $${i + 1}`).join(', ')}) as r`,
    k.map((x) => (args[x] !== null && typeof args[x] === 'object' ? JSON.stringify(args[x]) : args[x])));
  await asUser(db, OWNER);
  return r.rows[0].r;
};

// Simulated Thumbtack API.
let tt;
function fakeThumbtack() {
  const s = { sent: [], tokenCalls: 0, failNext: [], seq: 0 };
  s.fetch = async (url, init) => {
    if (url.includes('/oauth2/token')) {
      s.tokenCalls++;
      return new Response(JSON.stringify({ access_token: 'access-' + s.tokenCalls, refresh_token: 'refresh-' + s.tokenCalls, expires_in: 3600 }));
    }
    const status = s.failNext.shift();
    if (status) return new Response('{"error":"simulated"}', { status });
    s.sent.push({ url, auth: init.headers.Authorization, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ messageID: 'tt-msg-' + ++s.seq }));
  };
  return s;
}
const dispatch = () => {
  const getToken = makeTokenProvider({ rpc, tokenUrl: 'https://auth.test/oauth2/token', clientId: 'cid', clientSecret: 'secret', fetchFn: tt.fetch });
  return dispatchOutbox({ rpc, sendMessage: makeThumbtackClient({ apiBase: 'https://api.test', sendPath: '/api/v4/negotiations/{negotiationID}/messages', getToken, fetchFn: tt.fetch }) });
};
const due = async () => { await db.exec(`reset role`); await db.exec(`update thumbtack_outbox set next_attempt_at = now() where status = 'pending'`); await asUser(db, OWNER); };

// A v4-style "negotiation created" webhook.
const v4Lead = (id, secondsAgo = 37, extra = {}) => ({
  event: { eventID: 'evt-' + id, eventType: 'NegotiationCreatedV4' },
  data: {
    negotiationID: id, createTimestamp: Math.floor(Date.now() / 1000) - secondsAgo,
    customer: { customerID: 'cust-' + id, name: 'John Smith', phone: '(760) 555-01' + String(id).slice(-2).padStart(2, '0') },
    business: { businessID: 'biz-goldex' },
    request: { requestID: 'req-' + id, category: 'Cabinet Installation', title: 'Kitchen cabinets',
      description: 'Need 12 cabinets installed.', schedule: 'Within 2 weeks',
      details: [{ question: 'How many cabinets?', answer: '12' }, { question: 'Cabinets purchased?', answer: 'Yes' }],
      location: { city: 'Carlsbad', state: 'CA', zipCode: '92008' }, attachments: [{ url: 'x.jpg' }] },
    ...extra,
  },
});
const ingest = (payload) => rpc('tt_ingest_lead', { p: normalizeLead(payload) });

before(async () => {
  db = await createDb();
  tt = fakeThumbtack();
  await rpc('tt_store_tokens', { p_access: 'access-0', p_refresh: 'refresh-0', p_expires_in: 3600, p_account_id: 'biz-goldex', p_scopes: 'messages' });
});

test('Normalizer handles v4 and legacy v2 payloads', () => {
  const v4 = normalizeLead(v4Lead('n-1'));
  assert.equal(v4.thumbtack_lead_id, 'n-1');
  assert.deepEqual([v4.customer.first_name, v4.customer.last_name], ['John', 'Smith']);
  assert.equal(v4.location.zip, '92008');
  assert.equal(v4.attachments_count, 1);
  const v2 = normalizeLead({ leadID: '777', createTimestamp: '1700000000', customer: { customerID: 'c9', name: 'Ana', phone: '6195550100' },
    business: { businessID: 'b1' }, request: { category: 'Flooring', description: 'LVP 600 sqft', location: { address1: '1 Main St', city: 'Vista', state: 'CA', zipCode: '92081' } } });
  assert.equal(v2.thumbtack_lead_id, '777');
  assert.equal(v2.created_at, '2023-11-14T22:13:20.000Z');
  assert.equal(detectType({ leadID: '1', customerID: 'c', message: { messageID: 'm', text: 'hi' } }), 'message');
  assert.equal(detectType({ event: { eventType: 'MessageCreatedV4' }, data: {} }), 'message');
  const m = normalizeMessage({ event: { eventType: 'MessageCreatedV4' }, data: { messageID: 'm1', negotiationID: 'n-1', sentAt: '2026-10-06T10:00:00Z', from: 'Customer', text: 'Hi' } });
  assert.deepEqual([m.thumbtack_lead_id, m.from, m.text], ['n-1', 'CUSTOMER', 'Hi']);
});

test('Webhook authentication rejects anything but the right credentials', () => {
  const cfg = { user: 'thumbtack', pass: 's3cret-pass', secretToken: 'tok-123' };
  const basic = (u, p) => 'Basic ' + btoa(`${u}:${p}`);
  assert.equal(checkWebhookAuth({ authorization: basic('thumbtack', 's3cret-pass') }, cfg), true);
  assert.equal(checkWebhookAuth({ authorization: basic('thumbtack', 'wrong') }, cfg), false);
  assert.equal(checkWebhookAuth({ token: 'tok-123' }, cfg), true);
  assert.equal(checkWebhookAuth({ token: 'nope' }, cfg), false);
  assert.equal(checkWebhookAuth({}, cfg), false);
  assert.equal(checkWebhookAuth({ token: 'anything' }, {}), false, 'no credentials configured = reject everything');
});

let leadId;
test('Test 1 — new Thumbtack lead creates customer, property, lead with project details and Thumbtack IDs', async () => {
  const r = await ingest(v4Lead('n-1001'));
  assert.equal(r.created, true);
  leadId = r.lead_id;
  const l = await one(db, `select * from v_leads where id = $1`, [leadId]);
  assert.equal(l.source, 'Thumbtack');
  assert.equal(l.thumbtack_lead_id, 'n-1001');
  assert.equal(l.thumbtack_customer_id, 'cust-n-1001');
  assert.equal(l.service_type, 'Cabinet Installation');
  assert.equal(l.stage, 'NEW LEAD');
  assert.equal(l.customer_name, 'John Smith');
  assert.equal(l.property_address, 'Carlsbad, CA 92008');
  assert.match(l.description, /Need 12 cabinets installed/);
  assert.match(l.description, /How many cabinets\?: 12/);
  assert.equal(l.customer_availability, 'Within 2 weeks');
  assert.equal(l.photos_provided, true);
  assert.equal(l.response_status, 'RESPONSE_PENDING');
  assert.ok(await one(db, `select 1 from thumbtack_leads where thumbtack_lead_id = 'n-1001' and raw_payload is not null`));
  assert.ok(await one(db, `select 1 from tasks where lead_id = $1 and task_type = 'Contact Lead'`, [leadId]), 'normal new-lead task still created');
  assert.equal(await val(db, `select count(*)::int from notifications where entity_id = $1 and title like 'New lead:%'`, [leadId]), 0,
    'generic alert replaced by the Thumbtack alert');
  assert.equal(await val(db, `select count(*)::int from thumbtack_messages where lead_id = $1 and sender_type = 'CUSTOMER'`, [leadId]), 1,
    'original request is the first message');
});

test('Test 2 + 3 — automatic response sent through Thumbtack, timestamps and response time recorded', async () => {
  const res = await dispatch();
  assert.equal(res.length, 1);
  assert.equal(res[0].status, 'sent');
  assert.equal(tt.sent.length, 1);
  assert.equal(tt.sent[0].url, 'https://api.test/api/v4/negotiations/n-1001/messages');
  assert.equal(tt.sent[0].auth, 'Bearer access-0');
  assert.match(tt.sent[0].body.text, /^Hi John! Thanks for reaching out to GOLDEX Construction/);

  const l = await one(db, `select * from v_leads where id = $1`, [leadId]);
  assert.equal(l.auto_response_sent, true);
  assert.equal(l.auto_response_message_id, 'tt-msg-1');
  assert.equal(l.response_status, 'RESPONSE_SENT');
  assert.equal(l.response_method, 'auto');
  assert.ok(Number(l.response_seconds) >= 36 && Number(l.response_seconds) <= 45, `response_seconds=${l.response_seconds}`);
  assert.ok(new Date(l.lead_received_at) < new Date(l.crm_created_at));
  const n = await one(db, `select * from notifications where entity_id = $1 and title like '🔔 NEW THUMBTACK LEAD%'`, [leadId]);
  assert.match(n.body, /Auto-response: Sent · Response time: \d+ sec/);
  assert.match(n.body, /Carlsbad, CA/);
  assert.equal(await val(db, `select sender_type from thumbtack_messages where thumbtack_message_id = 'tt-msg-1'`), 'AUTOMATION');

  assert.equal(l.last_contacted_at, null, 'an automatic reply is not the owner contacting the lead');
  assert.equal(l.stage, 'NEW LEAD');
  assert.equal(await val(db, `select count(*)::int from scheduled_actions where entity_id = $1 and status = 'pending'`, [leadId]), 3,
    'owner SLA reminders still run after the auto-reply');

  // Running the dispatcher again sends nothing.
  assert.equal((await dispatch()).length, 0);
  assert.equal(tt.sent.length, 1);
});

test('Test 5 — the same webhook twice (or a retry) creates one lead and one response', async () => {
  const again = await ingest(v4Lead('n-1001'));
  assert.equal(again.created, false);
  assert.equal(again.lead_id, leadId);
  assert.equal(await val(db, `select count(*)::int from leads where thumbtack_lead_id = 'n-1001'`), 1);
  assert.equal(await val(db, `select count(*)::int from customers where thumbtack_customer_id = 'cust-n-1001'`), 1);
  assert.equal(await val(db, `select count(*)::int from thumbtack_outbox where lead_id = $1`, [leadId]), 1);
  assert.equal((await dispatch()).length, 0);
  await db.exec(`reset role`);
  await assert.rejects(db.query(`insert into thumbtack_outbox (lead_id, thumbtack_lead_id, kind, message_text) values ($1, 'n-1001', 'auto_response', 'x')`, [leadId]),
    /thumbtack_outbox_one_auto/, 'database refuses a second automatic response');
  await asUser(db, OWNER);
});

test('Test 4 — customer replies sync into the conversation; our own echo is not duplicated', async () => {
  const msg = (id, from, text) => normalizeMessage({ event: { eventID: 'e-' + id, eventType: 'MessageCreatedV4' },
    data: { messageID: id, negotiationID: 'n-1001', from, text, sentAt: new Date().toISOString() } });
  await rpc('tt_ingest_message', { p: msg('tt-msg-1', 'Business', tt.sent[0].body.text) });  // echo of the auto-response
  await rpc('tt_ingest_message', { p: msg('c-1', 'Customer', 'Thanks! When can you come out?') });
  await rpc('tt_ingest_message', { p: msg('c-1', 'Customer', 'Thanks! When can you come out?') });   // duplicate delivery
  const convo = await all(db, `select sender_type, message_text from thumbtack_messages where lead_id = $1 order by sent_at, created_at`, [leadId]);
  assert.deepEqual(convo.map((m) => m.sender_type), ['CUSTOMER', 'AUTOMATION', 'CUSTOMER']);
  assert.ok(await one(db, `select 1 from notifications where entity_id = $1 and title like '💬 Thumbtack message%'`, [leadId]));
  assert.ok(await one(db, `select 1 from communications where lead_id = $1 and type = 'Thumbtack' and message like 'Thanks! When%'`, [leadId]),
    'conversation mirrored into the customer timeline');
  assert.equal(await val(db, `select response_status from leads where id = $1`, [leadId]), 'RESPONSE_SENT');

  // Owner answers from the Thumbtack app → recorded as OWNER and the automation stands down.
  await rpc('tt_ingest_message', { p: msg('o-1', 'Business', 'Good morning John, I can come Thursday.') });
  assert.equal(await val(db, `select response_status from leads where id = $1`, [leadId]), 'OWNER_TAKEOVER');
  assert.equal(await val(db, `select sender_type from thumbtack_messages where thumbtack_message_id = 'o-1'`), 'OWNER');
});

test('Messages that arrive before their lead are attached when the lead arrives', async () => {
  const orphan = await rpc('tt_ingest_message', { p: normalizeMessage({ data: { messageID: 'early-1', negotiationID: 'n-2002', from: 'Customer', text: 'Also need crown molding' } }) });
  assert.equal(orphan.orphan, true);
  const r = await ingest(v4Lead('n-2002', 5));
  assert.equal(await val(db, `select lead_id from thumbtack_messages where thumbtack_message_id = 'early-1'`), r.lead_id);
});

test('Test 6 — Thumbtack API failure retries at +15 s, +60 s, +3 min, then alerts the owner', async () => {
  const r = await ingest(v4Lead('n-3003', 2));
  await db.exec(`reset role`); await db.exec(`update thumbtack_outbox set status = 'cancelled' where thumbtack_lead_id = 'n-2002'`); await asUser(db, OWNER);
  tt.failNext.push(503, 503, 503, 503);
  const delays = [];
  for (let i = 0; i < 3; i++) {
    const [res] = await dispatch();
    assert.equal(res.status, 'retry');
    delays.push(res.retry_in_seconds);
    assert.equal(await val(db, `select response_status from leads where id = $1`, [r.lead_id]), 'RESPONSE_FAILED');
    assert.equal((await dispatch()).length, 0, 'not retried before its time');
    await due();
  }
  assert.deepEqual(delays, [15, 60, 180]);
  const [last] = await dispatch();
  assert.equal(last.status, 'failed');
  assert.equal(await val(db, `select attempt_count from thumbtack_outbox where lead_id = $1`, [r.lead_id]), 4);
  assert.ok(await one(db, `select 1 from notifications where entity_id = $1 and title like '🚨 Thumbtack response failed%'`, [r.lead_id]));
  assert.ok(await one(db, `select 1 from tasks where lead_id = $1 and priority = 'Urgent' and title like 'Reply in Thumbtack NOW%'`, [r.lead_id]));
  assert.equal(await val(db, `select count(*)::int from automation_events where entity_id = $1 and status = 'retry_scheduled'`, [r.lead_id]), 3);
});

test('Permanent errors fail immediately; expired tokens are refreshed and stored in Vault', async () => {
  const r = await ingest(v4Lead('n-4004', 1));
  tt.failNext.push(400);
  const [res] = await dispatch();
  assert.equal(res.status, 'failed', '400 Bad Request is not retried');

  const r2 = await ingest(v4Lead('n-4005', 1));
  await db.exec(`reset role`); await db.exec(`update integrations set token_expires_at = now() - interval '1 minute'`); await asUser(db, OWNER);
  const before = tt.tokenCalls;
  const [ok] = await dispatch();
  assert.equal(ok.status, 'sent');
  assert.equal(tt.tokenCalls, before + 1);
  assert.equal(tt.sent.at(-1).auth, `Bearer access-${tt.tokenCalls}`);
  await db.exec(`reset role`);
  assert.equal(await val(db, `select count(*)::int from vault.secrets where secret like 'access-%'`), 1, 'one access token secret, updated in place');
  await asUser(db, OWNER);
  assert.ok(r.lead_id && r2.lead_id);
});

test('Test 7 — owner takeover stops the automatic response; owner can reply from the CRM', async () => {
  const r = await ingest(v4Lead('n-5005', 3));
  await db.query(`select tt_take_over($1)`, [r.lead_id]);
  const sentBefore = tt.sent.length;
  assert.equal((await dispatch()).length, 0);
  assert.equal(tt.sent.length, sentBefore, 'no automatic message after takeover');
  assert.equal(await val(db, `select status from thumbtack_outbox where lead_id = $1 and kind = 'auto_response'`, [r.lead_id]), 'cancelled');
  assert.equal(await val(db, `select response_status from leads where id = $1`, [r.lead_id]), 'OWNER_TAKEOVER');

  await db.query(`select tt_send_owner_message($1, 'Hi John, Olim here — can I call you at 5?')`, [r.lead_id]);
  const [res] = await dispatch();
  assert.equal(res.status, 'sent');
  assert.equal(tt.sent.at(-1).body.text, 'Hi John, Olim here — can I call you at 5?');
  assert.equal(await val(db, `select response_method from lead_response_metrics where lead_id = $1`, [r.lead_id]), 'owner_crm');
});

test('Not connected yet: lead still lands, no message is attempted, owner is told to reply in the app', async () => {
  await db.exec(`reset role`); await db.exec(`update integrations set status = 'not_connected'`); await asUser(db, OWNER);
  const r = await ingest(v4Lead('n-6006', 1));
  assert.equal(r.response_status, 'WAITING');
  assert.equal(await val(db, `select count(*)::int from thumbtack_outbox where lead_id = $1`, [r.lead_id]), 0);
  assert.ok(await one(db, `select 1 from notifications where entity_id = $1 and body like '%reply in the Thumbtack app now%'`, [r.lead_id]));
  assert.equal(await val(db, `select next_action from v_leads where id = $1`, [r.lead_id]), 'Take over the Thumbtack conversation');
  await db.exec(`reset role`); await db.exec(`update integrations set status = 'connected'`); await asUser(db, OWNER);
});

test('Response-time KPIs for the dashboard', async () => {
  const k = await val(db, `select tt_kpis(current_date, current_date)`);
  assert.ok(k.leads >= 7);
  assert.ok(k.auto_responses >= 2);
  assert.ok(k.failed >= 2);
  assert.ok(k.pct_under_5_min > 0 && k.pct_under_5_min <= 100);
  assert.ok(k.avg_seconds >= 0);
  assert.equal(k.connected, true);
});

test('Security — the CRM user cannot call ingestion, read tokens or touch the integration table', async () => {
  await assert.rejects(db.query(`select tt_ingest_lead('{}')`), /permission denied/);
  await assert.rejects(db.query(`select tt_get_tokens()`), /permission denied/);
  await assert.rejects(db.query(`select * from integrations`), /permission denied/);
  await assert.rejects(db.query(`update thumbtack_outbox set status = 'pending'`), /permission denied/);
  const s = await val(db, `select tt_status()`);
  assert.equal(s.status, 'connected');
  assert.ok(!('access_token' in s));
  await asUser(db, null);
  await assert.rejects(db.query(`select tt_kpis()`), /permission denied/);
  await asUser(db, OWNER);
});
