// CEO dashboard: "Can the company operate and make money without me doing the work?"
import { db, page, register, refresh, state } from '../app.js';
import { html, money, pct, num, kpi, periodRange, marginTone, fmtDate, ago, badge, scoreBadge } from '../ui.js';
import { taskList } from './common.js';
import { thumbtackTiles } from './thumbtack.js';

let period = 'month';
const PERIODS = [['today', 'Today'], ['week', 'This week'], ['month', 'This month'], ['quarter', 'Quarter'], ['year', 'Year']];

register({ setPeriod: ({ p }) => { period = p; refresh(); } });

page('dashboard', {
  title: 'Today',
  async render() {
    const [from, to] = periodRange(period);
    const endOfToday = new Date(); endOfToday.setHours(23, 59, 59);
    const [s, tasks, leads, projects, invoices, events] = await Promise.all([
      db.rpc('dashboard_summary', { p_from: from, p_to: to }),
      db.list('tasks', { in: { status: ['Pending', 'In Progress'] }, is: ['archived_at'], lte: { due_at: endOfToday.toISOString() }, order: 'due_at', limit: 50 }),
      db.list('v_leads', { is: ['archived_at'], in: { stage: ['NEW LEAD', 'CONTACTED', 'QUALIFYING', 'SITE VISIT', 'ESTIMATE', 'PROPOSAL SENT', 'FOLLOW-UP'] }, order: 'created_at desc' }),
      db.list('v_project_outlook', { in: { status: ['Pending Deposit', 'Ready to Schedule', 'Scheduled', 'Pre-Construction', 'In Progress', 'On Hold', 'Punch List', 'QC', 'Completed'] } }),
      db.list('v_invoices', { in: { status: ['Sent', 'Partially Paid'] }, order: 'due_date' }),
      db.list('calendar_events', { eq: { event_date: to }, neq: { status: 'Cancelled' } }),
    ]);
    const ttTiles = await thumbtackTiles().catch(() => '');

    // ── TODAY'S PRIORITIES: one ranked list of what to do next ──
    const prio = [];
    for (const l of leads.filter((x) => x.stage === 'NEW LEAD'))
      prio.push({ rank: l.sla_breached ? 0 : 1, icon: l.thumbtack_lead_id ? '💬' : '📞',
        text: l.thumbtack_lead_id ? `Take over Thumbtack lead — ${l.service_type ?? ''}` : `Call new lead — ${money(l.estimated_value)} ${l.service_type ?? ''}`, sub: `${l.customer_name} · ${ago(l.created_at)}${l.sla_breached ? ' · SLA missed' : ''}`, act: 'openLead', id: l.id, hot: l.sla_breached });
    for (const i of invoices.filter((x) => x.is_overdue))
      prio.push({ rank: 2, icon: '💵', text: `Collect ${money(i.balance_due)} — ${i.invoice_number} ${i.days_overdue}d overdue`, sub: i.customer_name, act: 'go', to: 'invoices', hot: true });
    for (const l of leads.filter((x) => ['PROPOSAL SENT', 'FOLLOW-UP'].includes(x.stage) && x.next_task_due && new Date(x.next_task_due) <= endOfToday))
      prio.push({ rank: 3, icon: '↻', text: `Follow up proposal — ${money(l.estimated_value)} ${l.service_type ?? ''}`, sub: l.customer_name, act: 'openLead', id: l.id });
    for (const p of projects.filter((x) => x.next_action && !['In Progress'].includes(x.status)))
      prio.push({ rank: 4, icon: '▣', text: `${p.next_action} — ${p.project_name}`, sub: `${p.project_number} · ${p.status}`, act: 'go', to: 'project/' + p.project_id });
    prio.sort((a, b) => a.rank - b.rank);

    const own = s.owner_hours;
    const ownTotal = Number(own.total) || 0;
    const seg = (v, c) => ownTotal ? html`<span style="width:${(v / ownTotal) * 100}%;background:${c}"></span>` : '';
    const greet = new Date().getHours() < 12 ? 'Good morning' : new Date().getHours() < 18 ? 'Good afternoon' : 'Good evening';
    const atRisk = projects.filter((p) => Number(p.projected_profit) < 0 || (p.status === 'Pending Deposit') || (Number(p.budgeted_hours) > 0 && Number(p.actual_hours) > Number(p.budgeted_hours)));
    const dueSoon = invoices.reduce((a, i) => a + Number(i.balance_due), 0);

    const leadIdsInPrio = new Set(prio.filter((p) => p.act === 'openLead').map((p) => p.id));
    const myTasks = tasks.filter((t) => !t.lead_id || !leadIdsInPrio.has(t.lead_id));
    const periodLabel = PERIODS.find((p) => p[0] === period)[1];

    return html`
    <div class="hero">
      <div><h1>${greet}, ${state.me.first_name || 'boss'} 👋</h1><div class="muted">${new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}</div></div>
    </div>

    <div class="kpi-grid big-tiles">
      <div class="kpi click" data-act="go" data-to="pipeline"><div class="kpi-ico">🎯</div><div class="kpi-val ${s.new_leads ? 'gold' : ''}">${s.new_leads}</div><div class="kpi-label">New leads</div></div>
      <div class="kpi click" data-act="go" data-to="tasks"><div class="kpi-ico">✅</div><div class="kpi-val ${s.overdue_tasks ? 'red' : ''}">${s.tasks_today + s.overdue_tasks}</div><div class="kpi-label">Tasks today${s.overdue_tasks ? ` · ${s.overdue_tasks} late` : ''}</div></div>
      <div class="kpi click" data-act="go" data-to="projects"><div class="kpi-ico">🔨</div><div class="kpi-val green">${s.active_projects}</div><div class="kpi-label">Active jobs</div></div>
      <div class="kpi click" data-act="go" data-to="invoices"><div class="kpi-ico">💵</div><div class="kpi-val ${Number(s.overdue_ar) ? 'red' : ''}">${money(dueSoon)}</div><div class="kpi-label">Owed to you${Number(s.overdue_ar) ? ` · ${money(s.overdue_ar)} late` : ''}</div></div>
    </div>

    ${ttTiles}

    <div class="grid-2">
      <div class="card">
        <div class="card-title">👉 Do this next</div>
        ${prio.length ? prio.slice(0, 6).map((p) => html`
          <div class="list-item click" data-act="${p.act}" data-id="${p.id || ''}" data-to="${p.to || ''}">
            <span class="row-ico">${p.icon}</span>
            <div class="list-main" style="flex:1"><div class="list-name ${p.hot ? 'red' : ''}">${p.text}</div><div class="list-sub">${p.sub}</div></div><span class="muted">›</span>
          </div>`) : html`<div class="empty small">All clear. Nothing urgent right now. 🎉</div>`}
      </div>
      <div class="card">
        <div class="card-title">✅ Today's tasks <button class="btn btn-link" data-act="go" data-to="tasks">See all ›</button></div>
        ${taskList(myTasks.slice(0, 8))}
      </div>
    </div>

    <div class="section-h" style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
      <span>${periodLabel}</span>
      <div class="seg">${PERIODS.map(([k, l]) => html`<button class="${k === period ? 'on' : ''}" data-act="setPeriod" data-p="${k}">${l}</button>`)}</div>
    </div>
    <div class="kpi-grid">
      ${kpi('Money collected', money(s.revenue_collected), 'green')}
      ${kpi('Jobs won', money(s.contracted_revenue), '', `${s.won_count} job${s.won_count === 1 ? '' : 's'}`)}
      ${kpi('Profit on jobs', money(s.gross_profit), marginTone(s.gross_margin), s.gross_margin == null ? '' : `${pct(s.gross_margin)} margin`)}
      ${kpi('Open leads worth', money(s.pipeline), 'gold')}
    </div>

    <details class="more">
      <summary>More business numbers</summary>
      <div class="kpi-grid" style="margin-top:14px">
        ${kpi('Leads', s.leads)}${kpi('Good leads (A/B)', s.qualified_leads)}${kpi('Estimates', s.estimates)}
        ${kpi('Proposals', s.proposals)}${kpi('Close rate', s.close_rate == null ? '—' : s.close_rate + '%')}
        ${kpi('Average job', s.avg_project_value == null ? '—' : money(s.avg_project_value))}
      </div>
      <div class="grid-2">
        <div class="card">
          <div class="card-title">Your hours (goal: less field work)</div>
          <div style="display:flex;align-items:baseline;gap:10px"><span class="kpi-val gold" style="font-size:34px">${num(own.field)}</span><span class="muted">hours in the field</span></div>
          <div class="owner-bar">${seg(own.field, 'var(--gold)')}${seg(own.sales, 'var(--blue)')}${seg(own.management, 'var(--green)')}${seg(own.admin, 'var(--muted2)')}</div>
          <div class="legend"><span><i style="background:var(--gold)"></i>Field ${num(own.field)}h</span><span><i style="background:var(--blue)"></i>Sales ${num(own.sales)}h</span>
            <span><i style="background:var(--green)"></i>Managing ${num(own.management)}h</span><span><i style="background:var(--muted2)"></i>Admin ${num(own.admin)}h</span></div>
          <div class="profit-row" style="margin-top:10px"><span class="lbl">Money per field hour</span><span>${s.revenue_per_field_hour == null ? '—' : money(s.revenue_per_field_hour)}</span></div>
          <div class="profit-row"><span class="lbl">≈ Profit per field hour</span><span>${s.profit_per_field_hour == null ? '—' : money(s.profit_per_field_hour)}</span></div>
        </div>
        <div class="card">
          <div class="card-title">Watch list</div>
          <div class="profit-row"><span class="lbl">🔴 Jobs at risk</span><span class="${atRisk.length ? 'red' : ''}">${atRisk.length}</span></div>
          ${atRisk.slice(0, 4).map((p) => html`<div class="list-item click" data-act="go" data-to="project/${p.project_id}"><div class="list-main"><div class="list-name">${p.project_name}</div>
            <div class="list-sub">${p.status === 'Pending Deposit' ? 'Deposit unpaid' : Number(p.projected_profit) < 0 ? 'Projected loss ' + money(p.projected_profit) : 'Over budgeted hours'}</div></div>${badge(p.status)}</div>`)}
          <div class="profit-row"><span class="lbl">⚠ Late invoices</span><span class="${s.overdue_invoices ? 'red' : ''}">${s.overdue_invoices} · ${money(s.overdue_ar)}</span></div>
          <div class="card-title" style="margin-top:14px">How late is unpaid money</div>
          ${[['Not due yet', s.ar_aging.current], ['1–30 days late', s.ar_aging['1_30']], ['31–60 days', s.ar_aging['31_60']], ['61–90 days', s.ar_aging['61_90']], ['90+ days', s.ar_aging['90_plus']]]
            .map(([l, v], i) => html`<div class="profit-row"><span class="lbl">${l}</span><span class="${i && Number(v) ? 'red' : ''}">${money(v)}</span></div>`)}
        </div>
      </div>
    </details>`;
  },
});
