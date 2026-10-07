// Thumbtack: lead panel (response performance + conversation), dashboard
// tiles and the Settings → Integrations tab.
import { db, register, refresh, setting, loadSettings, state } from '../app.js';
import { SUPABASE_URL } from '../config.js';
import { DEMO } from '../db.js';
import { html, raw, fmtDateTime, ago, badge, toast, closeModal, readForm, field, textarea, input, kpi, num, periodRange, confirmDialog } from '../ui.js';

const STATUS_TONE = { WAITING: 'orange', PROCESSING: 'blue', RESPONSE_PENDING: 'blue', RESPONSE_SENT: 'green',
  RESPONSE_FAILED: 'red', OWNER_TAKEOVER: 'gold' };
export const responseBadge = (s) => s ? badge(s.replace(/_/g, ' '), STATUS_TONE[s]) : '';
export const secs = (s) => s == null ? '—' : s < 60 ? `${Math.round(s)} sec` : s < 3600 ? `${Math.floor(s / 60)} min ${Math.round(s % 60)} sec` : `${(s / 3600).toFixed(1)} h`;
const time = (t) => t ? new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' }) + ' · ' + new Date(t).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : '—';

export async function thumbtackPanel(l) {
  if (!l.thumbtack_lead_id) return '';
  const [msgs, status] = await Promise.all([
    db.list('thumbtack_messages', { eq: { thumbtack_lead_id: l.thumbtack_lead_id }, order: ['sent_at', 'created_at'] }),
    db.rpc('tt_status'),
  ]);
  const connected = status?.status === 'connected';
  const who = { CUSTOMER: l.customer_name, AUTOMATION: '⚡ Auto-response', OWNER: 'GOLDEX (you)' };
  return html`
  <div class="fieldset" style="margin-top:4px"><div class="fieldset-title">Thumbtack</div>
    <div class="grid-2" style="margin-bottom:6px">
      <div>
        <div class="profit-row"><span class="lbl">Thumbtack lead ID</span><span class="small">${l.thumbtack_lead_id}</span></div>
        <div class="profit-row"><span class="lbl">Thumbtack customer ID</span><span class="small">${l.thumbtack_customer_id || '—'}</span></div>
        ${l.external_url ? html`<div class="profit-row"><span class="lbl">Open in Thumbtack</span><a href="${l.external_url}" target="_blank" rel="noopener">view ↗</a></div>` : ''}
        <div class="profit-row"><span class="lbl">Response status</span>${responseBadge(l.response_status)}</div>
      </div>
      <div>
        <div class="profit-row"><span class="lbl">Lead received</span><span class="small">${time(l.lead_received_at)}</span></div>
        <div class="profit-row"><span class="lbl">CRM received</span><span class="small">${time(l.crm_created_at)}</span></div>
        <div class="profit-row"><span class="lbl">First response</span><span class="small">${time(l.first_response_at)}${l.response_method ? ` (${l.response_method.replace('_', ' ')})` : ''}</span></div>
        <div class="profit-row total"><span>⚡ Response time</span><span class="${l.response_seconds == null ? 'orange' : l.response_seconds <= 300 ? 'green' : 'red'}">${secs(l.response_seconds)}</span></div>
      </div>
    </div>
    <div class="card-title">Conversation</div>
    <div style="max-height:280px;overflow-y:auto;margin-bottom:10px">
      ${msgs.map((m) => html`<div class="timeline-item"><div class="timeline-time">${fmtDateTime(m.sent_at)}</div>
        <div><b class="${m.sender_type === 'CUSTOMER' ? '' : m.sender_type === 'AUTOMATION' ? 'gold' : 'green'}">${who[m.sender_type] || m.sender_type}</b>
        <div style="white-space:pre-wrap">${m.message_text}</div></div></div>`)}
    </div>
    ${l.response_status !== 'OWNER_TAKEOVER' ? html`<button class="btn btn-gold btn-sm" data-act="ttTakeOver" data-id="${l.id}">Take over conversation</button>
      <span class="hint">Stops automatic messages for this lead.</span>` : ''}
    ${connected ? html`<div style="margin-top:10px" id="tt-reply">${textarea('text', '', 'placeholder="Reply to the customer in Thumbtack…" style="min-height:60px"')}
      <button class="btn btn-dark btn-sm" style="margin-top:6px" data-act="ttReply" data-id="${l.id}">Send via Thumbtack</button></div>`
      : html`<div class="hint" style="margin-top:8px">Thumbtack messaging isn't connected — reply in the Thumbtack app. Your replies there still sync here once the webhook is set up.</div>`}
  </div>`;
}

register({
  ttTakeOver: async ({ id }) => { await db.rpc('tt_take_over', { p_lead_id: id }); toast('You have the conversation — automation stopped for this lead'); closeModal(); refresh(); },
  ttReply: async ({ id }) => {
    const { text } = readForm(document.getElementById('tt-reply'));
    await db.rpc('tt_send_owner_message', { p_lead_id: id, p_text: text });
    toast('Queued — sending through Thumbtack'); closeModal(); refresh();
  },
});

// ── DASHBOARD TILES (spec §13) ─────────────────────────────────────
export async function thumbtackTiles() {
  const k = await db.rpc('tt_kpis', { p_from: periodRange('today')[0], p_to: periodRange('today')[1] });
  if (!k || (!k.leads && !k.connected)) return '';
  return html`<div class="section-h">Thumbtack — today ${k.connected ? '' : html`<span class="badge badge-orange">auto-reply not connected</span>`}</div>
  <div class="kpi-grid">
    ${kpi('Thumbtack leads today', k.leads, 'gold')}
    ${kpi('Auto responses', `${k.auto_responses}/${k.leads}`, k.auto_responses === k.leads ? 'green' : 'orange')}
    ${kpi('Avg response time', secs(k.avg_seconds))}
    ${kpi('Under 5 min', k.pct_under_5_min == null ? '—' : k.pct_under_5_min + '%', k.pct_under_5_min >= 95 ? 'green' : k.leads ? 'red' : '')}
    ${kpi('Failed responses', k.failed ?? 0, k.failed ? 'red' : 'green')}
  </div>`;
}

// ── SETTINGS → INTEGRATIONS ────────────────────────────────────────
export async function integrationsTab() {
  const [s, k] = await Promise.all([db.rpc('tt_status'), db.rpc('tt_kpis', { p_from: periodRange('month')[0], p_to: periodRange('month')[1] })]);
  const cfg = setting('thumbtack', {});
  const fn = (name) => SUPABASE_URL ? `${SUPABASE_URL}/functions/v1/${name}` : `https://<project>.supabase.co/functions/v1/${name}`;
  const connected = s?.status === 'connected';
  return html`<div class="grid-2">
    <div class="card"><div class="card-title">Thumbtack ${badge(s?.status?.replace('_', ' ') || 'unknown', connected ? 'green' : s?.status === 'error' ? 'red' : 'orange')}</div>
      <div class="profit-row"><span class="lbl">Receiving leads & messages</span><span class="small">Webhook → ${fn('thumbtack-webhook')}</span></div>
      <div class="profit-row"><span class="lbl">Sending messages</span><span>${connected ? 'Connected' : 'Needs Thumbtack partner access'}</span></div>
      ${s?.last_sync_at ? html`<div class="profit-row"><span class="lbl">Last lead synced</span><span>${ago(s.last_sync_at)}</span></div>` : ''}
      ${s?.last_error ? html`<div class="profit-row"><span class="lbl">Last error</span><span class="red small">${s.last_error}</span></div>` : ''}
      <div class="pill-row" style="margin-top:12px">
        ${connected ? html`<button class="btn btn-red btn-sm" data-act="ttDisconnect">Disconnect</button>`
          : html`<button class="btn btn-gold btn-sm" data-act="ttConnect" ${DEMO || !cfg.client_id ? raw('disabled') : ''}>Connect Thumbtack</button>`}
      </div>
      ${!connected ? html`<div class="hint" style="margin-top:8px">${DEMO ? 'Not available in demo mode. ' : ''}${!cfg.client_id ? 'Requires a Thumbtack partner Client ID (request access at developers.thumbtack.com), entered below.' : ''}</div>` : ''}
    </div>
    <div class="card" id="tt-form"><div class="card-title">Automatic response</div>
      <label class="check"><input type="checkbox" name="auto_response_enabled" ${cfg.auto_response_enabled !== false ? raw('checked') : ''}> Send automatically to every new Thumbtack lead</label>
      ${field('Message ({{first_name}} = customer first name)', textarea('template', cfg.template, 'style="min-height:110px"'))}
      <div class="hint" style="margin:-6px 0 10px">Fixed, approved text. It never quotes prices, promises dates or commits to scope.</div>
      <details><summary class="small muted" style="cursor:pointer;margin-bottom:8px">Partner API settings (from Thumbtack)</summary>
        ${field('Client ID (public)', input('client_id', cfg.client_id))}
        ${field('Authorize URL', input('auth_url', cfg.auth_url))}
        <div class="form-row">${field('Scopes', input('scopes', cfg.scopes))}${field('API base', input('api_base', cfg.api_base))}</div>
        <div class="hint">The client secret is never stored here — it lives only in the server (Supabase secret TT_CLIENT_SECRET).</div></details>
      <button class="btn btn-gold btn-sm" style="margin-top:10px" data-act="ttSaveSettings">Save</button>
    </div></div>
  <div class="section-h">Response performance — this month</div>
  <div class="kpi-grid">
    ${kpi('Leads', k?.leads ?? 0)}${kpi('Responded', k?.responded ?? 0)}${kpi('Average', secs(k?.avg_seconds))}${kpi('Median', secs(k?.median_seconds))}
    ${kpi('Fastest', secs(k?.fastest_seconds))}${kpi('Slowest', secs(k?.slowest_seconds))}
    ${kpi('< 1 min', (k?.pct_under_1_min ?? '—') + '%')}${kpi('< 5 min (target 95%)', (k?.pct_under_5_min ?? '—') + '%', k?.pct_under_5_min >= 95 ? 'green' : k?.leads ? 'red' : '')}
    ${kpi('> 5 min / none', (k?.pct_over_5_min ?? '—') + '%')}${kpi('Failed', k?.failed ?? 0, k?.failed ? 'red' : '')}
  </div>`;
}

register({
  ttSaveSettings: async () => {
    const f = readForm(document.getElementById('tt-form'));
    const value = { ...setting('thumbtack', {}), ...f };
    await db.updateWhere('settings', { eq: { key: 'thumbtack' } }, { value });
    await loadSettings(); toast('Thumbtack settings saved'); refresh();
  },
  ttConnect: async () => {
    const cfg = setting('thumbtack', {});
    const st = await db.rpc('tt_oauth_begin');
    const u = new URL(cfg.auth_url);
    u.search = new URLSearchParams({ client_id: cfg.client_id, redirect_uri: `${SUPABASE_URL}/functions/v1/thumbtack-oauth`,
      response_type: 'code', scope: cfg.scopes || 'messages', state: st }).toString();
    location.href = u.toString();
  },
  ttDisconnect: async () => {
    if (!(await confirmDialog('Disconnect Thumbtack?', 'Automatic responses stop. New leads still arrive through the webhook.', 'Disconnect', 'btn-red'))) return;
    await db.rpc('tt_disconnect'); toast('Thumbtack disconnected'); refresh();
  },
});
