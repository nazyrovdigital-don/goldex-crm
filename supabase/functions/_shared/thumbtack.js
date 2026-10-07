// Thumbtack integration core — plain JavaScript so the same code runs in the
// Supabase Edge Functions (Deno) and in the Node test suite.
//
// Thumbtack has two webhook formats in the wild:
//   v2 (legacy):  { leadID, createTimestamp, request:{…}, customer:{…}, business:{…} }
//                 { leadID, customerID, businessID, message:{ messageID, createTimestamp, text } }
//   v4 (current): { event:{ eventType:'NegotiationCreatedV4' | 'MessageCreatedV4', … }, data:{ negotiationID, … } }
// The normalizer accepts both (and common casing variants) and always keeps
// the raw payload, so nothing is lost if Thumbtack adds or renames fields.

const get = (obj, path) => path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
const pick = (obj, ...paths) => {
  for (const p of paths) {
    const v = get(obj, p);
    if (v !== undefined && v !== null && v !== '') return v;
  }
  return undefined;
};

export function toISO(ts) {
  if (ts === undefined || ts === null || ts === '') return null;
  if (typeof ts === 'number' || /^\d+$/.test(String(ts))) {
    const n = Number(ts);
    return new Date(n < 1e12 ? n * 1000 : n).toISOString();   // unix seconds or ms
  }
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export function detectType(payload) {
  const t = String(pick(payload, 'event.eventType', 'eventType', 'type') || '').toLowerCase();
  if (t.includes('message')) return 'message';
  if (t.includes('negotiation') || t.includes('lead')) return 'lead';
  if (t.includes('review')) return 'review';
  if (pick(payload, 'review', 'data.review')) return 'review';
  if (pick(payload, 'message.messageID', 'data.messageID', 'messageID')) return 'message';
  if (pick(payload, 'request', 'data.request', 'leadID', 'data.negotiationID', 'negotiationID')) return 'lead';
  return 'unknown';
}

function splitName(full) {
  const parts = String(full || '').trim().split(/\s+/).filter(Boolean);
  return { first_name: parts[0] || '', last_name: parts.slice(1).join(' ') };
}

export function normalizeLead(payload, receivedAt = new Date().toISOString()) {
  const d = payload.data && typeof payload.data === 'object' ? payload.data : payload;
  const leadId = pick(d, 'negotiationID', 'negotiationId', 'leadID', 'leadId', 'id');
  const cust = pick(d, 'customer') || {};
  const req = pick(d, 'request') || {};
  const loc = pick(req, 'location') || pick(d, 'location') || {};
  const name = pick(cust, 'name', 'displayName', 'fullName');
  const first = pick(cust, 'firstName', 'first_name');
  const last = pick(cust, 'lastName', 'last_name');
  const split = first ? { first_name: first, last_name: last || '' } : splitName(name);
  const category = pick(req, 'category.name', 'categoryName', 'category', 'serviceCategory') ?? pick(d, 'category.name', 'category');
  const details = (pick(req, 'details', 'questionsAndAnswers', 'answers') || [])
    .map((x) => ({ question: pick(x, 'question', 'label', 'title') || '', answer: Array.isArray(x.answer) ? x.answer.join(', ') : pick(x, 'answer', 'value', 'response') || '' }))
    .filter((x) => x.question || x.answer);
  const createdAt = toISO(pick(d, 'createTimestamp', 'createdAt', 'createTime', 'created_at') ?? pick(payload, 'event.createdAt', 'event.createTimestamp'));
  return {
    event_key: String(pick(payload, 'event.eventID', 'event.eventId', 'eventID') || `lead:${leadId}`),
    thumbtack_lead_id: leadId == null ? null : String(leadId),
    thumbtack_customer_id: (v => (v == null ? null : String(v)))(pick(cust, 'customerID', 'customerId', 'id') ?? pick(d, 'customerID')),
    business_id: (v => (v == null ? null : String(v)))(pick(d, 'business.businessID', 'business.businessId', 'businessID', 'businessId')),
    request_id: (v => (v == null ? null : String(v)))(pick(req, 'requestID', 'requestId', 'id')),
    created_at: createdAt,
    received_at: receivedAt,
    customer: { ...split, phone: pick(cust, 'phone', 'phoneNumber') || null, email: pick(cust, 'email') || null },
    category: category == null ? null : String(category),
    title: pick(req, 'title') || null,
    description: pick(req, 'description') || null,
    schedule: (v => (v && typeof v === 'object' ? JSON.stringify(v) : v))(pick(req, 'schedule', 'scheduleText', 'timing')) || null,
    details,
    attachments_count: (pick(req, 'attachments') || []).length,
    location: {
      address1: pick(loc, 'address1', 'street', 'addressLine1') || null, address2: pick(loc, 'address2', 'addressLine2') || null,
      city: pick(loc, 'city') || null, state: pick(loc, 'state') || null, zip: pick(loc, 'zipCode', 'zip', 'postalCode') || null,
    },
    status: pick(d, 'status', 'leadType', 'chargeState') || null,
    url: pick(d, 'url', 'negotiationURL', 'leadURL') || null,
    raw: payload,
  };
}

export function normalizeMessage(payload, receivedAt = new Date().toISOString()) {
  const d = payload.data && typeof payload.data === 'object' ? payload.data : payload;
  const msg = pick(d, 'message') && typeof d.message === 'object' ? d.message : d;
  const from = String(pick(msg, 'from', 'senderType', 'sender.type') ?? pick(d, 'from', 'senderType') ?? 'Customer');
  const messageId = pick(msg, 'messageID', 'messageId', 'id') ?? pick(d, 'messageID');
  return {
    event_key: String(pick(payload, 'event.eventID', 'event.eventId', 'eventID') || `message:${messageId}`),
    thumbtack_message_id: messageId == null ? null : String(messageId),
    thumbtack_lead_id: (v => (v == null ? null : String(v)))(pick(d, 'negotiationID', 'negotiationId', 'leadID', 'leadId')),
    from: /customer|consumer|requester/i.test(from) ? 'CUSTOMER' : 'BUSINESS',
    sender_name: pick(msg, 'senderName', 'sender.name') || null,
    text: pick(msg, 'text', 'body', 'content') || '',
    sent_at: toISO(pick(msg, 'sentAt', 'createTimestamp', 'createdAt') ?? pick(d, 'sentAt')) || receivedAt,
    raw: payload,
  };
}

// Constant-time comparison so the webhook password can't be guessed by timing.
export function safeEqual(a, b) {
  const x = String(a ?? ''); const y = String(b ?? '');
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x.charCodeAt(i) || 0) ^ (y.charCodeAt(i) || 0);
  return diff === 0;
}

export function checkWebhookAuth({ authorization, token }, { user, pass, secretToken }) {
  if (!user && !secretToken) return false;                     // never accept unauthenticated webhooks
  if (secretToken && token && safeEqual(token, secretToken)) return true;
  if (user && authorization?.startsWith('Basic ')) {
    let decoded = '';
    try { decoded = atob(authorization.slice(6)); } catch { return false; }
    const i = decoded.indexOf(':');
    const userOk = safeEqual(decoded.slice(0, i), user);      // evaluate both: no short-circuit timing leak
    const passOk = safeEqual(decoded.slice(i + 1), pass);
    return i > 0 && userOk && passOk;
  }
  return false;
}

export class SendError extends Error {
  constructor(message, retryable) { super(message); this.retryable = retryable; }
}

// Access tokens live ~1 hour; refresh tokens rotate. Both are kept in Supabase Vault.
export function makeTokenProvider({ rpc, tokenUrl, clientId, clientSecret, fetchFn = fetch }) {
  return async function getToken(force = false) {
    const t = await rpc('tt_get_tokens', {});
    if (!t || t.status !== 'connected' || !t.access_token) throw new SendError('Thumbtack is not connected', false);
    const fresh = t.expires_at && new Date(t.expires_at).getTime() - Date.now() > 120_000;
    if (fresh && !force) return t.access_token;
    if (!t.refresh_token) throw new SendError('Thumbtack access expired — reconnect Thumbtack in Settings', false);
    const res = await fetchFn(tokenUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Authorization: 'Basic ' + btoa(`${clientId}:${clientSecret}`) },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: t.refresh_token }).toString(),
    });
    if (!res.ok) {
      const msg = `Token refresh failed (${res.status})`;
      if (res.status === 400 || res.status === 401) {
        await rpc('tt_set_integration_error', { p_error: msg + ' — reconnect Thumbtack', p_status: 'error' });
        throw new SendError(msg, false);
      }
      throw new SendError(msg, true);
    }
    const j = await res.json();
    await rpc('tt_store_tokens', { p_access: j.access_token, p_refresh: j.refresh_token ?? null, p_expires_in: j.expires_in ?? 3600,
      p_account_id: null, p_scopes: j.scope ?? null });
    return j.access_token;
  };
}

export function makeThumbtackClient({ apiBase, sendPath, getToken, fetchFn = fetch, timeoutMs = 10_000 }) {
  return async function sendMessage(row) {
    const path = sendPath.replace('{negotiationID}', encodeURIComponent(row.thumbtack_lead_id))
      .replace('{leadID}', encodeURIComponent(row.thumbtack_lead_id)).replace('{businessID}', encodeURIComponent(row.business_id ?? ''));
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await getToken(attempt > 0);
      let res;
      try {
        res = await fetchFn(apiBase + path, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
          body: JSON.stringify({ text: row.text }),
          signal: AbortSignal.timeout(timeoutMs),
        });
      } catch (e) { throw new SendError(`Network error: ${e.message}`, true); }
      if (res.status === 401 && attempt === 0) continue;      // token rejected → refresh once
      const body = await res.text();
      if (res.ok) {
        let j = {}; try { j = JSON.parse(body); } catch { /* empty body */ }
        const id = pick(j, 'messageID', 'messageId', 'data.messageID', 'id', 'data.id');
        return { messageId: id == null ? null : String(id) };
      }
      const retryable = res.status >= 500 || res.status === 408 || res.status === 429;
      throw new SendError(`Thumbtack ${res.status}: ${body.slice(0, 300)}`, retryable);
    }
    throw new SendError('Thumbtack rejected the access token twice', false);
  };
}

// Claim due outbox rows, send each, record the result. Safe to run
// concurrently: rows are claimed with SKIP LOCKED.
export async function dispatchOutbox({ rpc, sendMessage, limit = 10 }) {
  const rows = (await rpc('tt_claim_outbox', { p_limit: limit })) || [];
  const results = [];
  for (const row of rows) {
    try {
      const r = await sendMessage(row);
      results.push({ id: row.id, ...(await rpc('tt_complete_outbox', { p_id: row.id, p_ok: true, p_message_id: r.messageId, p_error: null, p_retryable: true })) });
    } catch (e) {
      results.push({ id: row.id, ...(await rpc('tt_complete_outbox', { p_id: row.id, p_ok: false, p_message_id: null,
        p_error: String(e.message).slice(0, 500), p_retryable: e.retryable !== false })) });
    }
  }
  return results;
}
