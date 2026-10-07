// Data layer. Pages talk only to this module, never to Supabase directly, so
// the same UI runs against Supabase (production) or PGlite (demo/testing).
//
//   db.list(table, { eq, neq, in, is, gte, lte, order, limit })
//   db.get(table, id) · db.insert(table, row) · db.update(table, id, patch)
//   db.remove(table, id) · db.rpc(fn, args)
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const DEMO = !SUPABASE_URL || !SUPABASE_ANON_KEY;
const IDENT = /^[a-z_][a-z0-9_]*$/;
const ident = (s) => { if (!IDENT.test(s)) throw new Error('Bad identifier: ' + s); return `"${s}"`; };

// ── SUPABASE ───────────────────────────────────────────────────────
async function supabaseAdapter() {
  const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const check = ({ data, error }) => { if (error) throw new Error(error.message); return data; };
  const apply = (q, o = {}) => {
    for (const [k, v] of Object.entries(o.eq || {})) q = q.eq(k, v);
    for (const [k, v] of Object.entries(o.neq || {})) q = q.neq(k, v);
    for (const [k, v] of Object.entries(o.in || {})) q = q.in(k, v);
    for (const [k, v] of Object.entries(o.gte || {})) q = q.gte(k, v);
    for (const [k, v] of Object.entries(o.lte || {})) q = q.lte(k, v);
    for (const k of o.is || []) q = q.is(k, null);
    for (const k of o.not || []) q = q.not(k, 'is', null);
    for (const ord of [].concat(o.order || [])) {
      const [col, dir] = ord.split(' ');
      q = q.order(col, { ascending: dir !== 'desc', nullsFirst: false });
    }
    if (o.limit) q = q.limit(o.limit);
    return q;
  };
  return {
    mode: 'supabase',
    list: async (t, o) => check(await apply(sb.from(t).select('*'), o)),
    get: async (t, id) => check(await sb.from(t).select('*').eq('id', id).maybeSingle()),
    insert: async (t, row) => check(await sb.from(t).insert(row).select().single()),
    insertMany: async (t, rows) => rows.length ? check(await sb.from(t).insert(rows).select()) : [],
    update: async (t, id, patch) => check(await sb.from(t).update(patch).eq('id', id).select().single()),
    updateWhere: async (t, o, patch) => check(await apply(sb.from(t).update(patch), o).select()),
    remove: async (t, id) => check(await sb.from(t).delete().eq('id', id)),
    removeWhere: async (t, o) => check(await apply(sb.from(t).delete(), o)),
    rpc: async (fn, args = {}) => check(await sb.rpc(fn, args)),
    auth: {
      session: async () => (await sb.auth.getSession()).data.session,
      signIn: async (email, password) => check(await sb.auth.signInWithPassword({ email, password })),
      resetPassword: async (email) => check(await sb.auth.resetPasswordForEmail(email, { redirectTo: location.href.split('#')[0] })),
      signOut: async () => { await sb.auth.signOut(); },
      onChange: (cb) => sb.auth.onAuthStateChange((_e, s) => cb(s)),
      userId: async () => (await sb.auth.getUser()).data.user?.id,
    },
  };
}

// ── PGLITE DEMO ────────────────────────────────────────────────────
const DEMO_OWNER = '00000000-0000-4000-8000-000000000001';

async function pgliteAdapter() {
  const { PGlite } = await import('https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.3.16/dist/index.js');
  const iso = (v) => new Date(v.replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00')).toISOString();
  const pg = new PGlite('idb://goldex-crm-demo', {
    parsers: { 1700: Number, 20: Number, 1082: (v) => v, 1083: (v) => v.slice(0, 5), 1184: iso, 1114: (v) => v },
  });
  await pg.exec(`create table if not exists _demo_migrations (name text primary key)`);
  const done = new Set((await pg.query(`select name from _demo_migrations`)).rows.map((r) => r.name));
  const base = new URL('../../supabase/', import.meta.url);
  const fetchText = async (p) => { const r = await fetch(new URL(p, base)); if (!r.ok) throw new Error(p + ' ' + r.status); return r.text(); };
  if (!done.has('auth_shim')) {
    await pg.exec(await fetchText('dev/auth_shim.sql'));
    await pg.query(`insert into _demo_migrations values ('auth_shim')`);
  }
  for (const f of JSON.parse(await fetchText('migrations/manifest.json'))) {
    if (done.has(f)) continue;
    await pg.exec(await fetchText('migrations/' + f));
    await pg.query(`insert into _demo_migrations values ($1)`, [f]);
  }
  await pg.exec(`set timezone to 'America/Los_Angeles'`);
  await pg.query(`select set_config('request.jwt.claim.sub', $1, false)`, [DEMO_OWNER]);
  if (!(await pg.query(`select 1 from auth.users where id = $1`, [DEMO_OWNER])).rows.length) {
    await pg.query(`insert into auth.users (id, email, raw_user_meta_data) values ($1, 'olim@goldexconst.com', '{"first_name":"Olimbek","last_name":"Nazyrov"}')`, [DEMO_OWNER]);
    const seed = await (await fetch(new URL('../demo/v1_seed.json', import.meta.url))).json();
    await pg.query(`select import_v1($1)`, [JSON.stringify(seed)]);
    await pg.query(`select set_config('request.jwt.claim.role', 'service_role', false)`);
    await pg.query(`select intake_website_lead($1)`, [JSON.stringify({
      first_name: 'Dana', last_name: 'Reyes', phone: '(619) 555-0142', email: 'dana@example.com',
      address: '742 Coast Blvd, La Jolla, CA 92037', service: 'Cabinet Installation',
      details: '18 kitchen cabinets plus island, photos attached. Want to start within a month.',
      utm_source: 'google', utm_medium: 'cpc', utm_campaign: 'cabinets-fall', photos_provided: true })]);
    await pg.query(`select set_config('request.jwt.claim.role', 'authenticated', false)`);
    // Sample Thumbtack lead, run through the real pipeline: lead → auto-response → customer reply.
    const tt = await import('../../supabase/functions/_shared/thumbtack.js');
    await pg.exec(`update integrations set status = 'connected' where provider = 'thumbtack'`);
    const lead = tt.normalizeLead({ event: { eventID: 'demo-evt-1', eventType: 'NegotiationCreatedV4' }, data: {
      negotiationID: 'demo-tt-1001', createTimestamp: Math.floor(Date.now() / 1000) - 38,
      customer: { customerID: 'demo-cust-1', name: 'John Smith', phone: '(760) 555-0188' }, business: { businessID: 'demo-biz' },
      request: { category: 'Cabinet Installation', title: 'Kitchen cabinet installation', description: 'Need 12 cabinets installed. Cabinets are already purchased.',
        schedule: 'Within 2 weeks', details: [{ question: 'How many cabinets?', answer: '12' }], location: { city: 'Carlsbad', state: 'CA', zipCode: '92008' } } } });
    await pg.query(`select tt_ingest_lead($1)`, [JSON.stringify(lead)]);
    const claimed = (await pg.query(`select tt_claim_outbox(5) as r`)).rows[0].r;
    for (const o of claimed) await pg.query(`select tt_complete_outbox($1, true, 'demo-msg-1')`, [o.id]);
    await pg.query(`select tt_ingest_message($1)`, [JSON.stringify(tt.normalizeMessage({ data: { messageID: 'demo-msg-2',
      negotiationID: 'demo-tt-1001', from: 'Customer', text: 'Thanks! Can you come take a look this week?', sentAt: new Date().toISOString() } }))]);
    await pg.exec(`update integrations set status = 'not_connected' where provider = 'thumbtack'`);
  }

  const where = (o = {}, params = []) => {
    const w = [];
    const add = (v) => { params.push(v); return '$' + params.length; };
    for (const [k, v] of Object.entries(o.eq || {})) w.push(`${ident(k)} = ${add(v)}`);
    for (const [k, v] of Object.entries(o.neq || {})) w.push(`${ident(k)} is distinct from ${add(v)}`);
    for (const [k, v] of Object.entries(o.in || {})) w.push(`${ident(k)}::text = any(${add(v.map(String))}::text[])`);
    for (const [k, v] of Object.entries(o.gte || {})) w.push(`${ident(k)} >= ${add(v)}`);
    for (const [k, v] of Object.entries(o.lte || {})) w.push(`${ident(k)} <= ${add(v)}`);
    for (const k of o.is || []) w.push(`${ident(k)} is null`);
    for (const k of o.not || []) w.push(`${ident(k)} is not null`);
    let sql = w.length ? ' where ' + w.join(' and ') : '';
    const ords = [].concat(o.order || []).map((x) => { const [c, d] = x.split(' '); return `${ident(c)} ${d === 'desc' ? 'desc' : 'asc'} nulls last`; });
    if (ords.length) sql += ' order by ' + ords.join(', ');
    if (o.limit) sql += ' limit ' + Number(o.limit);
    return sql;
  };
  const q = async (sql, params) => {
    try { return (await pg.query(sql, params)).rows; }
    catch (e) { throw new Error(e.message); }
  };
  const cols = (row) => Object.keys(row).map(ident);
  // jsonb columns: send objects/arrays as JSON text, as supabase-js does over HTTP.
  const v = (x) => (x !== null && typeof x === 'object' ? JSON.stringify(x) : x);
  return {
    mode: 'demo',
    pg,
    list: (t, o) => { const p = []; return q(`select * from public.${ident(t)}${where(o, p)}`, p); },
    get: async (t, id) => (await q(`select * from public.${ident(t)} where id = $1`, [id]))[0] ?? null,
    insert: async (t, row) => {
      const k = Object.keys(row);
      return (await q(`insert into public.${ident(t)} (${cols(row)}) values (${k.map((_, i) => '$' + (i + 1))}) returning *`,
        k.map((x) => v(row[x]))))[0];
    },
    insertMany: async function (t, rows) { const out = []; for (const r of rows) out.push(await this.insert(t, r)); return out; },
    update: async (t, id, patch) => {
      const k = Object.keys(patch);
      return (await q(`update public.${ident(t)} set ${k.map((x, i) => `${ident(x)} = $${i + 2}`)} where id = $1 returning *`,
        [id, ...k.map((x) => v(patch[x]))]))[0];
    },
    updateWhere: (t, o, patch) => {
      const k = Object.keys(patch); const p = k.map((x) => v(patch[x]));
      return q(`update public.${ident(t)} set ${k.map((x, i) => `${ident(x)} = $${i + 1}`)}${where(o, p)} returning *`, p);
    },
    remove: (t, id) => q(`delete from public.${ident(t)} where id = $1`, [id]),
    removeWhere: (t, o) => { const p = []; return q(`delete from public.${ident(t)}${where(o, p)}`, p); },
    rpc: async (fn, args = {}) => {
      const k = Object.keys(args);
      const vals = k.map((x) => (args[x] !== null && typeof args[x] === 'object' ? JSON.stringify(args[x]) : args[x]));
      return (await q(`select public.${ident(fn)}(${k.map((x, i) => `${ident(x)} => $${i + 1}`)}) as r`, vals))[0]?.r ?? null;
    },
    auth: {
      session: async () => ({ user: { id: DEMO_OWNER } }),
      signIn: async () => {}, resetPassword: async () => {}, signOut: async () => {},
      onChange: () => {}, userId: async () => DEMO_OWNER,
    },
    reset: async () => { await pg.close(); indexedDB.deleteDatabase('/pglite/goldex-crm-demo'); },
  };
}

export const db = DEMO ? await pgliteAdapter() : await supabaseAdapter();
