// CEO dashboard: "Can the company operate and make money without me doing the work?"
import { db, page, register, refresh, state } from '../app.js';
import { html, money, pct, num, kpi, periodRange, marginTone, fmtDate, ago, badge, scoreBadge } from '../ui.js';
import { taskList } from './common.js';
import { thumbtackTiles } from './thumbtack.js';

let period = 'month';
const PERIODS = [['today', 'Today'], ['week', 'This week'], ['month', 'This month'], ['quarter', 'Quarter'], ['year', 'Year']];

register({ setPeriod: ({ p }) => { period = p; refresh(); } });

page('dashboard', {
  title: 'Dashboard',
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

    return html`
    <div class="hero">
      <div><h1>${greet}, ${state.me.first_name || 'boss'}</h1><div class="muted small">${new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}</div></div>
      <div class="seg">${PERIODS.map(([k, l]) => html`<button class="${k === period ? 'on' : ''}" data-act="setPeriod" data-p="${k}">${l}</button>`)}</div>
    </div>

    <div class="kpi-grid">
      ${kpi('New leads', s.new_leads, s.new_leads ? 'gold' : '')}
      ${kpi('Tasks due today / overdue', `${s.tasks_today} / ${s.overdue_tasks}`, s.overdue_tasks ? 'red' : '')}
      ${kpi('Site visits today', events.filter((e) => e.type === 'Site Visit').length)}
      ${kpi('Active projects', s.active_projects, 'green')}
      ${kpi('Payments due', money(dueSoon), 'gold')}
      ${kpi('Overdue', money(s.overdue_ar), Number(s.overdue_ar) ? 'red' : '')}
    </div>

    ${ttTiles}

    <div class="grid-2">
      <div class="card">
        <div class="card-title">⚡ Today's priorities <span class="muted">${prio.length}</span></div>
        ${prio.length ? prio.slice(0, 10).map((p, i) => html`
          <div class="list-item click" data-act="${p.act}" data-id="${p.id || ''}" data-to="${p.to || ''}">
            <div class="list-main"><div class="list-name ${p.hot ? 'red' : ''}">${i + 1}. ${p.text}</div><div class="list-sub">${p.sub}</div></div><span>${p.icon}</span>
          </div>`) : html`<div class="empty small">Nothing urgent. Go win some work.</div>`}
      </div>
      <div class="card">
        <div class="card-title">Tasks due today & overdue <button class="btn btn-link" data-act="go" data-to="tasks">All tasks →</button></div>
        ${taskList(tasks.slice(0, 12))}
      </div>
    </div>

    <div class="section-h">Company — ${PERIODS.find((p) => p[0] === period)[1].toLowerCase()}</div>
    <div class="kpi-grid">
      ${kpi('Revenue collected', money(s.revenue_collected), 'green')}
      ${kpi('Contracted revenue', money(s.contracted_revenue), '', `${s.won_count} jobs won`)}
      ${kpi('Pipeline', money(s.pipeline), 'gold', `weighted ${money(s.weighted_pipeline)}`)}
      ${kpi('Job gross profit', money(s.gross_profit), '', 'projected open + actual completed')}
      ${kpi('Gross margin', pct(s.gross_margin), marginTone(s.gross_margin))}
      ${kpi('Accounts receivable', money(s.accounts_receivable))}
    </div>
    <div class="kpi-grid">
      ${kpi('Leads', s.leads)}${kpi('Qualified (A/B)', s.qualified_leads)}${kpi('Estimates', s.estimates)}
      ${kpi('Proposals', s.proposals)}${kpi('Won', s.won_count, 'green')}${kpi('Close rate', s.close_rate == null ? '—' : s.close_rate + '%')}
      ${kpi('Avg project', s.avg_project_value == null ? '—' : money(s.avg_project_value))}
    </div>

    <div class="grid-2">
      <div class="card">
        <div class="card-title">Owner independence</div>
        <div style="display:flex;align-items:baseline;gap:10px"><span class="kpi-val gold" style="font-size:36px">${num(own.field)}</span><span class="muted">owner field hours</span></div>
        <div class="owner-bar">${seg(own.field, 'var(--gold)')}${seg(own.sales, 'var(--blue)')}${seg(own.management, 'var(--green)')}${seg(own.admin, 'var(--muted)')}</div>
        <div class="legend"><span><i style="background:var(--gold)"></i>Field ${num(own.field)}h</span><span><i style="background:var(--blue)"></i>Sales ${num(own.sales)}h</span>
          <span><i style="background:var(--green)"></i>Management ${num(own.management)}h</span><span><i style="background:var(--muted)"></i>Admin ${num(own.admin)}h</span></div>
        <div class="grid-3" style="margin:14px 0 0">
          ${kpi('Revenue / field hr', s.revenue_per_field_hour == null ? '—' : money(s.revenue_per_field_hour))}
          ${kpi('≈ Profit / field hr', s.profit_per_field_hour == null ? '—' : money(s.profit_per_field_hour))}
          ${kpi('Revenue / owner hr', s.revenue_per_owner_hour == null ? '—' : money(s.revenue_per_owner_hour))}
        </div>
        <div class="hint">Goal: field hours trend down while revenue per owner hour trends up.</div>
      </div>
      <div class="card">
        <div class="card-title">Watch list</div>
        <div class="profit-row"><span class="lbl">🔴 Projects at risk</span><span class="${atRisk.length ? 'red' : ''}">${atRisk.length}</span></div>
        ${atRisk.slice(0, 4).map((p) => html`<div class="list-item click" data-act="go" data-to="project/${p.project_id}"><div class="list-main"><div class="list-name">${p.project_name}</div>
          <div class="list-sub">${p.status === 'Pending Deposit' ? 'Deposit unpaid' : Number(p.projected_profit) < 0 ? 'Projected loss ' + money(p.projected_profit) : 'Over budgeted hours'}</div></div>${badge(p.status)}</div>`)}
        <div class="profit-row"><span class="lbl">⚠ Overdue invoices</span><span class="${s.overdue_invoices ? 'red' : ''}">${s.overdue_invoices} · ${money(s.overdue_ar)}</span></div>
        <div class="profit-row"><span class="lbl">⚡ Leads needing action</span><span class="${s.leads_needing_action ? 'orange' : ''}">${s.leads_needing_action}</span></div>
        <div class="card-title" style="margin-top:14px">AR aging</div>
        ${[['Current', s.ar_aging.current], ['1–30 days', s.ar_aging['1_30']], ['31–60', s.ar_aging['31_60']], ['61–90', s.ar_aging['61_90']], ['90+', s.ar_aging['90_plus']]]
          .map(([l, v], i) => html`<div class="profit-row"><span class="lbl">${l}</span><span class="${i && Number(v) ? 'red' : ''}">${money(v)}</span></div>`)}
      </div>
    </div>

    <div class="card">
      <div class="card-title">Open pipeline <button class="btn btn-link" data-act="go" data-to="pipeline">Pipeline →</button></div>
      ${leads.slice(0, 8).map((l) => html`<div class="list-item click" data-act="openLead" data-id="${l.id}">
        <div class="list-main"><div class="list-name">${scoreBadge(l.qualification_score)} ${l.customer_name} — ${l.service_type ?? ''}</div>
        <div class="list-sub">${l.stage} · ${l.next_action ?? ''} · ${l.source ?? ''}</div></div><div class="list-val">${money(l.estimated_value)}</div></div>`)}
    </div>`;
  },
});
