// nirvana-board single-page app. Vanilla JS, no framework.

const ASCII =
`    _   _ _
    | \\ | (_)_ ____   ____ _ _ __   __ _
    |  \\| | | '__\\ \\ / / _\` | '_ \\ / _\` |
    | |\\  | | |   \\ V / (_| | | | | (_| |
    |_| \\_|_|_|    \\_/ \\__,_|_| |_|\\__,_|`;

const STATE = {
  board: null,
  tab: "my-day",                // "my-day" | "todos" | "agenda" | "one-on-ones" | ...
  partner: null,                // slug when tab == one-on-ones
  filter: "open",               // "open" | "all"
  loading: false,
  // Client-side draft caches for textareas with no server-side autosave.
  // Survive renders + tab switches. Cleared on successful Send/Save.
  summaryDrafts: {},            // slug -> in-flight "Send 1:1 summary" text
  notesDrafts: {},              // slug -> in-flight "Personal notes" text
  // Scheduled tasks are lazy-loaded (a ~2s PowerShell enumeration) separately
  // from /api/board so the main board stays snappy. null = not fetched yet.
  scheduledTasks: null,
  scheduledLoading: false,
  // My Day is the landing view. It carries today's meetings (a ~1-2s Outlook
  // read) plus server-computed needs-attention / focus lists, so like the
  // scheduled tasks it lives behind its own /api/my-day endpoint. null = not
  // fetched yet; we keep the last payload across refreshes so the tab never
  // flashes an empty skeleton once it has loaded.
  myDay: null,
  myDayLoading: false,
};

const $ = (id) => document.getElementById(id);
const escHtml = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Like escHtml, but renders soft line breaks: real newlines (the field values
// are stored on disk with real line breaks and the API returns them as "\n")
// become a single <br> in the output. A stray literal `<br>` token from any
// legacy value is also tolerated. The output is an HTML <br> element, never
// visible "<br>" text.
const escMultiline = (s) => escHtml(s)
  .replace(/&lt;br\s*\/?&gt;/gi, "<br>")
  .replace(/\r\n|\r|\n/g, "<br>");

function toast(msg, kind) {
  const el = $("toast");
  el.textContent = msg;
  el.classList.remove("hidden", "error", "success");
  if (kind === "error") el.classList.add("error");
  if (kind === "success") el.classList.add("success");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.add("hidden"), 3200);
}

async function api(path, opts) {
  const res = await fetch(path, Object.assign({
    headers: { "Content-Type": "application/json" },
  }, opts || {}));
  let body = null;
  try { body = await res.json(); } catch { /* non-JSON */ }
  if (!res.ok) {
    const msg = (body && body.error) || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return body;
}

async function loadBoard() {
  STATE.loading = true;
  try {
    const b = await api("/api/board");
    STATE.board = b;
    if (!STATE.partner && b.one_on_ones.length) {
      // Pick partner with most open items.
      STATE.partner = b.one_on_ones
        .slice()
        .sort((a, c) => c.open_count - a.open_count)[0].slug;
    }
    render();
  } catch (e) {
    toast("Failed to load: " + e.message, "error");
  } finally {
    STATE.loading = false;
  }
}

function setTab(tab) {
  STATE.tab = tab;
  document.querySelectorAll(".nav-item[data-tab]").forEach((el) => {
    el.classList.toggle("active", el.dataset.tab === tab);
  });
  const partnerSec = $("partner-section");
  partnerSec.style.display = tab === "one-on-ones" ? "" : "none";
  // Hide + Add on read-only tabs (my-day / scope-board / sdk-rotation /
  // ado-tracker / scheduled-tasks have no add-row support).
  const addBtn = $("add-btn");
  if (addBtn) addBtn.style.display = (tab === "my-day" || tab === "scope-board" || tab === "sdk-rotation" || tab === "ado-tracker" || tab === "scheduled-tasks") ? "none" : "";
  // My Day + Scheduled tasks are lazy-loaded on first visit.
  if (tab === "my-day" && STATE.myDay === null && !STATE.myDayLoading) {
    loadMyDay(false);
  }
  if (tab === "scheduled-tasks" && STATE.scheduledTasks === null && !STATE.scheduledLoading) {
    loadScheduledTasks(false);
  }
  render();
}

function setPartner(slug) {
  STATE.partner = slug;
  document.querySelectorAll("#partner-list .nav-item").forEach((el) => {
    el.classList.toggle("active", el.dataset.slug === slug);
  });
  render();
}

function setFilter(f) {
  STATE.filter = f;
  document.querySelectorAll(".nav-item.filter").forEach((el) => {
    el.classList.toggle("active", el.dataset.filter === f);
  });
  render();
}

function renderCounts() {
  const b = STATE.board;
  const mdEl = $("count-my-day");
  if (mdEl) mdEl.textContent = (STATE.myDay && STATE.myDay.stats && STATE.myDay.stats.needs_attention != null) ? STATE.myDay.stats.needs_attention : "-";
  if (!b) return;
  $("count-todos").textContent = b.counts.todos_open;
  $("count-agenda").textContent = b.counts.agenda_open;
  const apEl = $("count-ai-plan");
  if (apEl) apEl.textContent = (b.counts && b.counts.ai_plan_open != null) ? b.counts.ai_plan_open : "-";
  $("count-1on1").textContent = b.counts.one_on_ones_open;
  const sbEl = $("count-scope-board");
  if (sbEl) sbEl.textContent = (b.counts && b.counts.scope_board_rows != null) ? b.counts.scope_board_rows : "-";
  const sdkEl = $("count-sdk-rotation");
  if (sdkEl) sdkEl.textContent = (b.counts && b.counts.sdk_rotation_rows != null) ? b.counts.sdk_rotation_rows : "-";
  const adoEl = $("count-ado-tracker");
  if (adoEl) adoEl.textContent = (b.counts && b.counts.ado_tracker != null) ? b.counts.ado_tracker : "-";
  const schedEl = $("count-scheduled-tasks");
  if (schedEl) schedEl.textContent = (STATE.scheduledTasks && STATE.scheduledTasks.count != null) ? STATE.scheduledTasks.count : "-";

  const partnerList = $("partner-list");
  partnerList.innerHTML = "";
  for (const p of b.one_on_ones) {
    const li = document.createElement("li");
    li.className = "nav-item" + (p.slug === STATE.partner ? " active" : "");
    li.dataset.slug = p.slug;
    const kindPill = p.is_direct
      ? `<span class="dot direct" title="Direct report"></span>`
      : `<span class="dot peer" title="Peer or manager"></span>`;
    li.innerHTML = `<span>${kindPill}${escHtml(p.label)}</span><span class="count">${p.open_count}</span>`;
    li.addEventListener("click", () => setPartner(p.slug));
    partnerList.appendChild(li);
  }

  const sbCount = (b.counts && b.counts.scope_board_rows != null) ? b.counts.scope_board_rows : 0;
  $("board-subtitle").textContent =
    `${b.counts.todos_open} open todos \u00b7 ${b.counts.agenda_open} agenda \u00b7 ${b.counts.one_on_ones_open} 1:1 items \u00b7 ${sbCount} scope rows \u00b7 ${b.today}`;
}

function filterItems(items, statusKey) {
  const closedSet = new Set(["done", "closed"]);
  if (STATE.filter === "open") return items.filter((i) => !closedSet.has(i[statusKey] || i.status));
  return items;
}

function cardTodo(item) {
  const isOverdue = item.is_overdue;
  let statusPill = "";
  if (item.status === "done") statusPill = `<span class="pill done">done</span>`;
  else if (item.status === "snoozed") statusPill = `<span class="pill snoozed">snoozed</span>`;
  else if (isOverdue) statusPill = `<span class="pill overdue">overdue</span>`;
  else statusPill = `<span class="pill open">open</span>`;

  const cat = item.category ? `<span class="pill cat">${escHtml(item.category)}</span>` : "";
  const pri = item.priority ? `<span class="pill pri">P:${escHtml(item.priority)}</span>` : "";
  const due = item.due && item.due !== "-" ? `<span><span class="label">Due</span> ${escHtml(item.due)}</span>` : "";
  const snoozed = item.snoozed_until && item.snoozed_until !== "-" ? `<span><span class="label">Snoozed until</span> ${escHtml(item.snoozed_until)}</span>` : "";
  const created = item.created ? `<span><span class="label">Created</span> ${escHtml(item.created)}</span>` : "";
  const recur = item.recur && item.recur !== "none" ? `<span><span class="label">Recur</span> ${escHtml(item.recur)}</span>` : "";
  const doneOn = item.done_on ? `<span><span class="label">Done</span> ${escHtml(item.done_on)}</span>` : "";

  const notes = item.notes && item.notes !== "-" ? `<div class="card-summary is-clipped" data-clip="1">${escMultiline(item.notes)}</div>` : "";

  const isDone = item.status === "done";
  const actions = isDone
    ? `<button data-act="reopen-todo" data-id="${escHtml(item.id)}">&#x21ba; Reopen</button>`
    : `
        <button data-act="close-todo" data-id="${escHtml(item.id)}">&#x2713; Close</button>
        <button data-act="snooze-todo" data-id="${escHtml(item.id)}">&#x23f0; Snooze</button>
      `;

  return `
    <article class="card${isDone ? " closed" : ""}" data-card-id="${escHtml(item.id)}">
      <div class="card-head">
        <span class="card-id">${escHtml(item.id)}</span>
        <span class="card-title">${escHtml(item.title)}</span>
        ${statusPill} ${cat} ${pri}
      </div>
      <div class="card-meta">${created} ${due} ${recur} ${snoozed} ${doneOn}</div>
      ${notes}
      <div class="card-actions">
        ${actions}
        ${notes ? `<button class="expand-btn" data-act="expand">expand</button>` : ""}
      </div>
    </article>
  `;
}

function cardClosedStyle(item, opts) {
  const ns = opts.namespace; // "agenda" | "ai-plan" | "one-on-one"
  const isOnOne = ns === "one-on-one";
  const slug = opts.slug || "";
  const isClosed = item.status === "closed";

  const statusPill = isClosed
    ? `<span class="pill closed">closed</span>`
    : `<span class="pill open">open</span>`;
  const kind = item.kind ? `<span class="pill kind">${escHtml(item.kind)}</span>` : "";

  const opened = item.opened_on ? `<span><span class="label">Opened</span> ${escHtml(item.opened_on)}</span>` : "";
  const by = item.opened_by ? `<span><span class="label">By</span> ${escHtml(item.opened_by)}</span>` : "";
  const owner = item.owner ? `<span><span class="label">Owner</span> ${escHtml(item.owner)}</span>` : "";
  const closedOn = item.closed_on ? `<span><span class="label">Closed</span> ${escHtml(item.closed_on)}</span>` : "";

  const summary = item.summary && item.summary !== "-" ? `<div class="card-summary is-clipped" data-clip="1">${escMultiline(item.summary)}</div>` : "";
  const why = item.why_matters && item.why_matters !== "-" ? `<div class="card-section hidden" data-section="why"><span class="label">Why it matters:</span> ${escMultiline(item.why_matters)}</div>` : "";
  const next = item.next_step && item.next_step !== "-" ? `<div class="card-section hidden" data-section="next"><span class="label">Next step:</span> ${escMultiline(item.next_step)}</div>` : "";
  const notes = item.notes && item.notes !== "-" ? `<div class="card-section hidden" data-section="notes"><span class="label">Notes:</span> ${escMultiline(item.notes)}</div>` : "";

  const hasMore = why || next || notes;

  // Emit literal action names per namespace (kept literal so static checks and
  // the action handler switch both match exactly).
  let actionId, editAct;
  if (isOnOne) {
    actionId = `data-act="${isClosed ? "reopen-on" : "close-on"}" data-id="${escHtml(item.id)}" data-slug="${escHtml(slug)}"`;
    editAct = `data-act="edit-on" data-id="${escHtml(item.id)}" data-slug="${escHtml(slug)}"`;
  } else if (ns === "ai-plan") {
    actionId = `data-act="${isClosed ? "reopen-ai-plan" : "close-ai-plan"}" data-id="${escHtml(item.id)}"`;
    editAct = `data-act="edit-ai-plan" data-id="${escHtml(item.id)}"`;
  } else {
    actionId = `data-act="${isClosed ? "reopen-agenda" : "close-agenda"}" data-id="${escHtml(item.id)}"`;
    editAct = `data-act="edit-agenda" data-id="${escHtml(item.id)}"`;
  }

  return `
    <article class="card${isClosed ? " closed" : ""}" data-card-id="${escHtml(item.id)}">
      <div class="card-head">
        <span class="card-id">${escHtml(item.id)}</span>
        <span class="card-title">${escHtml(item.title)}</span>
        ${statusPill} ${kind}
      </div>
      <div class="card-meta">${opened} ${by} ${owner} ${closedOn}</div>
      ${summary}
      ${why}
      ${next}
      ${notes}
      <div class="card-actions">
        <button ${actionId}>${isClosed ? "&#x21ba; Reopen" : "&#x2713; Close"}</button>
        <button ${editAct}>&#9998; Edit</button>
        ${hasMore ? `<button class="expand-btn" data-act="expand-all">expand</button>` : ""}
      </div>
    </article>
  `;
}

function renderCards() {
  const host = $("cards-host");
  const b = STATE.board;

  if (STATE.tab === "my-day") {
    const today = STATE.myDay && STATE.myDay.weekday ? `${STATE.myDay.weekday}, ${STATE.myDay.today}` : "today";
    $("view-title").textContent = "My Day";
    $("view-subtitle").innerHTML = `Meetings, what needs your attention, and what to focus on &mdash; ${escHtml(today)}.`;
    $("crumb-tab").textContent = "My Day";
    $("crumb-tail").textContent = "";
    host.innerHTML = renderMyDay(STATE.myDay);
    return;
  }

  if (!b) { host.innerHTML = ""; return; }
  let items = [];
  let html = "";

  if (STATE.tab === "todos") {
    $("view-title").textContent = "Todos";
    $("view-subtitle").innerHTML = `Source: <code>reports/personal-todos/todos.md</code>`;
    $("crumb-tab").textContent = "Todos";
    $("crumb-tail").textContent = "";
    items = filterItems(b.todos, "status");
    if (!items.length) {
      html = `<div class="empty">No items.</div>`;
    } else {
      html = items.map(cardTodo).join("");
    }
  } else if (STATE.tab === "agenda") {
    $("view-title").textContent = "Team open discussions";
    $("view-subtitle").innerHTML = `Source: <code>reports/team-agenda/open-discussions.md</code>`;
    $("crumb-tab").textContent = "Team agenda";
    $("crumb-tail").textContent = "";
    items = filterItems(b.agenda, "status");
    if (!items.length) {
      html = `<div class="empty">No items.</div>`;
    } else {
      html = items.map((it) => cardClosedStyle(it, { namespace: "agenda" })).join("");
    }
  } else if (STATE.tab === "ai-plan") {
    $("view-title").textContent = "AI Plan";
    $("view-subtitle").innerHTML = `Source: <code>reports/ai-plan/ai-plan.md</code>`;
    $("crumb-tab").textContent = "AI Plan";
    $("crumb-tail").textContent = "";
    items = filterItems(b.ai_plan || [], "status");
    if (!items.length) {
      html = `<div class="empty">No items.</div>`;
    } else {
      html = items.map((it) => cardClosedStyle(it, { namespace: "ai-plan" })).join("");
    }
  } else if (STATE.tab === "one-on-ones") {
    const partner = b.one_on_ones.find((p) => p.slug === STATE.partner);
    if (!partner) {
      $("view-title").textContent = "1:1s";
      $("view-subtitle").innerHTML = `No partner files at <code>reports/one-on-ones/</code>.`;
      host.innerHTML = `<div class="empty">Add a per-person markdown file at <code>reports/one-on-ones/&lt;slug&gt;.md</code> to start.</div>`;
      return;
    }
    $("view-title").textContent = `1:1 with ${partner.label}`;
    $("view-subtitle").innerHTML = `Source: <code>reports/one-on-ones/${escHtml(partner.slug)}.md</code>`;
    $("crumb-tab").textContent = "1:1s";
    $("crumb-tail").innerHTML = ` &raquo; <span class="chip">${escHtml(partner.label)}</span>`;
    const headerCard = renderDirectScopeHeader(partner);
    const contextCards = renderDirectContextCards(partner);
    items = filterItems(partner.items, "status");
    let cards = "";
    if (!items.length) {
      cards = `<div class="empty">No items for ${escHtml(partner.label)}.</div>`;
    } else {
      cards = items.map((it) => cardClosedStyle(it, { namespace: "one-on-one", slug: partner.slug })).join("");
    }
    html = headerCard + contextCards + cards;
  } else if (STATE.tab === "scope-board") {
    const sb = b.scope_board || { tables: [], path: "reports/directs-scope/scope-board.md", exists: false };
    $("view-title").textContent = "Directs scope board";
    $("view-subtitle").innerHTML = `Source: <code>${escHtml(sb.path || "reports/directs-scope/scope-board.md")}</code>`;
    $("crumb-tab").textContent = "Scope board";
    $("crumb-tail").textContent = "";
    host.innerHTML = renderScopeBoard(sb);
    wireScopeBoardEditors(host);
    return;
  } else if (STATE.tab === "sdk-rotation") {
    const rot = b.sdk_rotation || { tables: [], path: "config/sdk-rotation.md", exists: false, order_table_index: null };
    $("view-title").textContent = "SDK rotation";
    $("view-subtitle").innerHTML = `Source: <code>${escHtml(rot.path || "config/sdk-rotation.md")}</code>`;
    $("crumb-tab").textContent = "SDK rotation";
    $("crumb-tail").textContent = "";
    host.innerHTML = renderSdkRotation(rot);
    wireSdkRotationEditors(host);
    return;
  } else if (STATE.tab === "ado-tracker") {
    const t = b.ado_tracker || { items: [], path: "reports/ado-tracker/tracked.json", exists: false, count: 0 };
    $("view-title").textContent = "ADO Tracker";
    $("view-subtitle").innerHTML = `Source: <code>${escHtml(t.path || "reports/ado-tracker/tracked.json")}</code>`;
    $("crumb-tab").textContent = "ADO Tracker";
    $("crumb-tail").textContent = "";
    host.innerHTML = renderAdoTracker(t);
    return;
  } else if (STATE.tab === "scheduled-tasks") {
    $("view-title").textContent = "Scheduled tasks";
    $("view-subtitle").innerHTML = `Source: <code>Get-ScheduledTask -TaskName 'DM-*'</code> (Windows Task Scheduler)`;
    $("crumb-tab").textContent = "Scheduled tasks";
    $("crumb-tail").textContent = "";
    host.innerHTML = renderScheduledTasks(STATE.scheduledTasks);
    return;
  }
  host.innerHTML = html;
}

// ---- Per-direct 1:1 header (Now + Next scope from scope-board) ---------
// Renders a compact card on top of the 1:1 tab so Nir sees, at a glance,
// what this direct is working on and where they're heading next.

function renderDirectScopeHeader(partner) {
  if (!partner) return "";
  if (!partner.is_direct) {
    return ""; // peer / manager 1:1s (e.g., Your Manager.md) - no scope context.
  }
  const now = partner.scope_now_html || escHtml(partner.scope_now || "");
  const next = partner.scope_next_html || escHtml(partner.scope_next || "");
  const empty = `<span class="muted">_(none recorded)_</span>`;
  const smtp = partner.smtp ? `<a href="mailto:${escHtml(partner.smtp)}" class="mono">${escHtml(partner.smtp)}</a>` : "";
  return `
    <article class="card direct-scope-header">
      <div class="card-head">
        <span class="card-title">${escHtml(partner.label)} - Scope</span>
        ${smtp ? `<span class="pill smtp">${smtp}</span>` : ""}
        <a class="pill link" href="#scope-board" data-act="goto-scope-board" title="Open the Directs Scope Board">scope board &raquo;</a>
      </div>
      <div class="scope-grid">
        <div class="scope-cell">
          <div class="scope-label">Now</div>
          <div class="scope-value">${now || empty}</div>
        </div>
        <div class="scope-cell">
          <div class="scope-label">Next</div>
          <div class="scope-value">${next || empty}</div>
        </div>
      </div>
    </article>
  `;
}

// ---- Per-direct context cards (recent PRs, active ADO items, persona) -
// Populated by .copilot/skills/run-refresh-directs-context.ps1 which
// writes reports/directs-scope/directs-context.json. The Board reads
// that file at snapshot time, so this UI degrades gracefully if the
// refresher has never run (cards are skipped entirely).

function renderDirectContextCards(partner) {
  if (!partner || !partner.is_direct) return "";
  const prs = partner.recent_prs || [];
  const wis = partner.active_work_items || [];
  const highlights = partner.persona_highlights || [];
  const milestones = partner.upcoming_milestones || [];
  return [
    renderRecentPrsCard(partner, prs),
    renderActiveWorkItemsCard(partner, wis),
    renderHighlightsCard(partner, highlights),
    renderMilestonesCard(partner, milestones),
    renderPersonalNotesCard(partner),
    renderSummaryCard(partner)
  ].filter(Boolean).join("");
}

function prStatusTone(status) {
  const s = (status || "").toLowerCase();
  if (s === "active") return "neutral";
  if (s === "completed") return "good";
  if (s === "abandoned") return "muted";
  return "neutral";
}

function renderRecentPrsCard(partner, prs) {
  if (!prs || !prs.length) return "";
  const stale = partner.context_generated_at ? `<span class="pill muted" title="Generated at ${escHtml(partner.context_generated_at)}">refreshed ${escHtml(shortAgo(partner.context_generated_at))}</span>` : "";
  const rows = prs.slice(0, 10).map((p) => {
    const tone = prStatusTone(p.status);
    return `
      <li class="ctx-row">
        <a href="${escHtml(p.url || '#')}" target="_blank" rel="noopener" class="ctx-link">
          <span class="ctx-id mono">!${escHtml(String(p.id))}</span>
          <span class="ctx-title">${escHtml(p.title || '(untitled)')}</span>
        </a>
        <span class="pill ${tone}">${escHtml(p.status || '?')}</span>
        <span class="pill muted">${escHtml(p.role || '')}</span>
        ${p.repo ? `<span class="pill subtle mono">${escHtml(p.repo)}</span>` : ''}
      </li>`;
  }).join("");
  return `
    <article class="card ctx-card">
      <div class="card-head">
        <span class="card-title">Recent PRs</span>
        <span class="pill subtle">${prs.length}</span>
        ${stale}
      </div>
      <ul class="ctx-list">${rows}</ul>
    </article>`;
}

function wiStateTone(state) {
  const s = (state || "").toLowerCase();
  if (s === "active" || s === "committed") return "good";
  if (s === "new" || s === "approved") return "neutral";
  if (s === "blocked") return "bad";
  return "neutral";
}

function renderActiveWorkItemsCard(partner, wis) {
  if (!wis || !wis.length) return "";
  const rows = wis.slice(0, 20).map((w) => {
    const tone = wiStateTone(w.state);
    return `
      <li class="ctx-row">
        <a href="${escHtml(w.url || '#')}" target="_blank" rel="noopener" class="ctx-link">
          <span class="ctx-id mono">#${escHtml(String(w.id))}</span>
          <span class="ctx-title">${escHtml(w.title || '(untitled)')}</span>
        </a>
        <span class="pill ${tone}">${escHtml(w.state || '?')}</span>
        <span class="pill subtle">${escHtml(w.type || '')}</span>
      </li>`;
  }).join("");
  return `
    <article class="card ctx-card">
      <div class="card-head">
        <span class="card-title">Active ADO items</span>
        <span class="pill subtle">${wis.length}</span>
      </div>
      <ul class="ctx-list">${rows}</ul>
    </article>`;
}

function renderHighlightsCard(partner, highlights) {
  if (!highlights || !highlights.length) return "";
  const rows = highlights.slice(0, 6).map((h) => `<li class="ctx-bullet">${escHtml(h)}</li>`).join("");
  return `
    <article class="card ctx-card">
      <div class="card-head">
        <span class="card-title">Recent highlights</span>
        <span class="pill subtle">from persona</span>
      </div>
      <ul class="ctx-list highlights">${rows}</ul>
    </article>`;
}

function renderMilestonesCard(partner, milestones) {
  if (!milestones || !milestones.length) {
    return `
      <article class="card ctx-card milestones-card">
        <div class="card-head">
          <span class="card-title">Upcoming milestones</span>
          <span class="pill subtle">next 14d</span>
        </div>
        <div class="empty muted">No birthdays or work anniversaries in the next 2 weeks.</div>
      </article>`;
  }
  const rows = milestones.slice(0, 4).map((m) => {
    const emoji = m.type === "birthday" ? "&#127874;" : "&#127881;";
    const du = (typeof m.days_until === "number") ? m.days_until : "?";
    const suffix = (du === 1) ? "day" : "days";
    return `<li class="ctx-bullet">${emoji} ${escHtml(m.label || '')} <span class="ctx-muted">&middot; in ${du} ${suffix}</span></li>`;
  }).join("");
  return `
    <article class="card ctx-card milestones-card">
      <div class="card-head">
        <span class="card-title">Upcoming milestones</span>
        <span class="pill subtle">next 14d</span>
      </div>
      <ul class="ctx-list">${rows}</ul>
    </article>`;
}

function renderPersonalNotesCard(partner) {
  // Prefer any in-flight (unsaved) draft so a 30s auto-refresh doesn't
  // clobber what the user is typing. Cleared after a successful Save.
  const draft = STATE.notesDrafts[partner.slug];
  const notes = (draft != null) ? draft : (partner.personal_notes || "");
  const placeholder = "Personal notes (off-limits topics, asks, preferences). Free-form. Saved to reports/one-on-ones/" + escHtml(partner.slug) + ".md.";
  return `
    <article class="card ctx-card notes-card" data-pn-slug="${escHtml(partner.slug)}">
      <div class="card-head">
        <span class="card-title">Personal notes</span>
        <span class="pill subtle">editable, persisted</span>
      </div>
      <textarea class="pn-text" data-pn-input="1" rows="5" placeholder="${placeholder}">${escHtml(notes)}</textarea>
      <div class="pn-actions">
        <button type="button" class="btn primary" data-pn-save="1">Save notes</button>
        <span class="pn-status muted" data-pn-status="1"></span>
      </div>
    </article>`;
}

function renderSummaryCard(partner) {
  // Bake any in-flight (un-sent) draft back into the textarea so the
  // 30s auto-refresh doesn't wipe what the user is typing. Cleared
  // after a successful (non-dry-run) Send.
  const draft = STATE.summaryDrafts[partner.slug] || "";
  return `
    <article class="card ctx-card summary-card" data-sum-slug="${escHtml(partner.slug)}">
      <div class="card-head">
        <span class="card-title">Send 1:1 summary</span>
        <span class="pill accent">post-meeting</span>
      </div>
      <p class="muted">After the 1:1, drop a few free-form notes here and click Send.
      You'll get an email composed from the wins, decisions, open follow-ups,
      and these notes - delivered to ${escHtml(partner.label || partner.slug)} with you on CC.</p>
      <textarea class="sum-text" data-sum-input="1" rows="6" placeholder="What did we decide? Anything you want to highlight back?">${escHtml(draft)}</textarea>
      <div class="pn-actions">
        <button type="button" class="btn primary" data-sum-send="1">Send 1:1 summary</button>
        <button type="button" class="btn" data-sum-dry="1">Dry run (preview only)</button>
        <span class="sum-status muted" data-sum-status="1"></span>
      </div>
    </article>`;
}

function shortAgo(iso) {
  try {
    const t = new Date(iso).getTime();
    if (!t) return "";
    const diff = Math.max(0, Date.now() - t);
    const mins = Math.round(diff / 60000);
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    const days = Math.round(hrs / 24);
    return `${days}d ago`;
  } catch (e) { return ""; }
}

// ---- Scope board (editable tables) ------------------------------------
// Each cell in every GFM table is a click-to-edit surface. Save commits
// to reports/directs-scope/scope-board.md via PATCH /api/scope-board.
// We addresses cells by (table, row, col) - heading is informational.

function renderScopeBoard(sb) {
  const tables = (sb && sb.tables) || [];
  if (sb && sb.error) {
    return `<div class="empty">Failed to parse scope-board: ${escHtml(sb.error)}</div>`;
  }
  if (!tables.length) {
    return `<div class="empty">No tables found in <code>${escHtml(sb.path || "scope-board.md")}</code>.</div>`;
  }
  const banner = `<div class="sb-banner"><b>Tip:</b> hover a cell and click the pencil (or click the cell) to edit. <span class="mono">Ctrl+Enter</span> saves, <span class="mono">Esc</span> cancels. Saves write directly to <span class="mono">${escHtml(sb.path)}</span>.</div>`;
  const body = tables.map((s, ti) => {
    const heading = s.heading ? `<h2>${escHtml(s.heading)}</h2>` : "";
    const cols = (s.columns || []).map(c => `<th>${escHtml(c)}</th>`).join("");
    const rows = (s.rows || []).map((r, ri) => {
      const cells = (r.cells || []).map((cell, ci) => {
        return `<td class="sb-cell" data-t="${ti}" data-r="${ri}" data-c="${ci}" data-raw="${escHtml(cell.raw || "")}"><span class="sb-cell-html">${cell.html || ""}</span><button type="button" class="sb-edit-btn" title="Edit cell" aria-label="Edit">&#9998;</button></td>`;
      }).join("");
      return `<tr>${cells}</tr>`;
    }).join("");
    return `
      <section class="sb-section">
        ${heading}
        <table class="sb-table">
          <thead><tr>${cols}</tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `;
  }).join("");
  return banner + body;
}

function wireScopeBoardEditors(root) {
  if (!root) return;
  root.querySelectorAll("td.sb-cell").forEach((td) => {
    td.addEventListener("click", (e) => {
      if (td.classList.contains("editing")) return;
      // Don't hijack clicks on real links inside the cell.
      if (e.target.tagName === "A") return;
      e.preventDefault();
      openSbEditor(td);
    });
  });
}

function openSbEditor(td) {
  if (td.classList.contains("editing")) return;
  const t = td.dataset.t, r = td.dataset.r, c = td.dataset.c;
  const raw = td.dataset.raw || "";
  const originalHtml = td.innerHTML;
  td.classList.add("editing");
  td.innerHTML = `
    <div class="sb-editor">
      <textarea class="sb-textarea" rows="3" spellcheck="false"></textarea>
      <div class="sb-editor-row">
        <button type="button" class="sb-btn primary sb-save">Save</button>
        <button type="button" class="sb-btn sb-cancel">Cancel</button>
        <span class="sb-editor-hint">Ctrl+Enter saves &middot; Esc cancels</span>
        <span class="sb-status" data-role="status"></span>
      </div>
    </div>
  `;
  const ta = td.querySelector(".sb-textarea");
  ta.value = raw;
  ta.focus();
  ta.setSelectionRange(ta.value.length, ta.value.length);

  const status = td.querySelector('[data-role="status"]');
  const saveBtn = td.querySelector(".sb-save");
  const cancelBtn = td.querySelector(".sb-cancel");

  const cancel = () => {
    td.classList.remove("editing");
    td.innerHTML = originalHtml;
  };

  const save = async () => {
    const value = ta.value;
    saveBtn.disabled = true;
    cancelBtn.disabled = true;
    status.className = "sb-status";
    status.textContent = "Saving...";
    try {
      const resp = await fetch("/api/scope-board", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ table: Number(t), row: Number(r), col: Number(c), value }),
      });
      const j = await resp.json();
      if (!resp.ok) {
        throw new Error(j && j.error ? j.error : `HTTP ${resp.status}`);
      }
      // Update in-memory state so subsequent re-renders are consistent.
      try {
        const sect = STATE.board.scope_board.tables[Number(t)];
        if (sect && sect.rows && sect.rows[Number(r)] && sect.rows[Number(r)].cells) {
          sect.rows[Number(r)].cells[Number(c)] = { raw: j.raw, html: j.html };
        }
      } catch (_) { /* best effort */ }
      td.dataset.raw = j.raw || "";
      td.classList.remove("editing");
      td.innerHTML = `<span class="sb-cell-html">${j.html || ""}</span><button type="button" class="sb-edit-btn" title="Edit cell" aria-label="Edit">&#9998;</button>`;
      toast(`Cell saved`, "success");
    } catch (e) {
      status.className = "sb-status error";
      status.textContent = e.message || "Save failed";
      saveBtn.disabled = false;
      cancelBtn.disabled = false;
    }
  };

  saveBtn.addEventListener("click", save);
  cancelBtn.addEventListener("click", cancel);
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { e.preventDefault(); cancel(); return; }
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); save(); return; }
  });
}

// ---- SDK rotation (editable + drag-to-reorder) -------------------------
// Cells in every table are click-to-edit (saves to /api/sdk-rotation).
// Rows in the table tagged `order_table_index` are draggable via the
// left-side grip handle; on drop, /api/sdk-rotation/order rewrites the
// `## Current order` table and renumbers column 0. No anchor enforcement -
// any row can move anywhere (per Nir).

function renderSdkRotation(rot) {
  const tables = (rot && rot.tables) || [];
  if (rot && rot.error) {
    return `<div class="empty">Failed to parse sdk-rotation: ${escHtml(rot.error)}</div>`;
  }
  if (!tables.length) {
    return `<div class="empty">No tables found in <code>${escHtml(rot.path || "config/sdk-rotation.md")}</code>.</div>`;
  }
  const orderIdx = (typeof rot.order_table_index === "number") ? rot.order_table_index : -1;
  const banner = `<div class="sb-banner"><b>Tip:</b> click any cell to edit. On the <b>Current order</b> table, drag the <span class="mono">&#x22ee;&#x22ee;</span> handle to reorder rows - column <span class="mono">#</span> is renumbered automatically. Saves write directly to <span class="mono">${escHtml(rot.path)}</span>.</div>`;
  const body = tables.map((s, ti) => {
    const heading = s.heading ? `<h2>${escHtml(s.heading)}</h2>` : "";
    const isOrder = (ti === orderIdx);
    const cols = (s.columns || []).map(c => `<th>${escHtml(c)}</th>`).join("");
    const handleCol = isOrder ? `<th class="sdk-handle-col" aria-label="drag handle"></th>` : "";
    const rows = (s.rows || []).map((r, ri) => {
      const cells = (r.cells || []).map((cell, ci) => {
        return `<td class="sdk-cell" data-t="${ti}" data-r="${ri}" data-c="${ci}" data-raw="${escHtml(cell.raw || "")}"><span class="sb-cell-html">${cell.html || ""}</span><button type="button" class="sb-edit-btn" title="Edit cell" aria-label="Edit">&#9998;</button></td>`;
      }).join("");
      const handleCell = isOrder
        ? `<td class="sdk-handle-cell"><span class="sdk-drag-handle" draggable="true" title="Drag to reorder" aria-label="Drag to reorder">&#x22ee;&#x22ee;</span></td>`
        : "";
      const rowAttrs = isOrder ? ` class="sdk-row" data-orig="${ri}"` : "";
      return `<tr${rowAttrs}>${handleCell}${cells}</tr>`;
    }).join("");
    const tableCls = isOrder ? "sb-table sdk-table sdk-table-order" : "sb-table sdk-table";
    return `
      <section class="sb-section">
        ${heading}
        <table class="${tableCls}" data-table-index="${ti}">
          <thead><tr>${handleCol}${cols}</tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `;
  }).join("");
  return banner + body;
}

function wireSdkRotationEditors(root) {
  if (!root) return;
  // Cell-edit on every cell across every table.
  root.querySelectorAll("td.sdk-cell").forEach((td) => {
    td.addEventListener("click", (e) => {
      if (td.classList.contains("editing")) return;
      if (e.target.tagName === "A") return;
      // Don't open the editor when the click bubbles up from the drag handle.
      if (e.target.classList && e.target.classList.contains("sdk-drag-handle")) return;
      e.preventDefault();
      openSdkCellEditor(td);
    });
  });
  // Drag-to-reorder, scoped to the Current order table (the only one
  // that renders the `.sdk-table-order` class).
  const orderTable = root.querySelector("table.sdk-table-order");
  if (orderTable) wireSdkRowDnD(orderTable);
}

function openSdkCellEditor(td) {
  if (td.classList.contains("editing")) return;
  const t = td.dataset.t, r = td.dataset.r, c = td.dataset.c;
  const raw = td.dataset.raw || "";
  const originalHtml = td.innerHTML;
  td.classList.add("editing");
  td.innerHTML = `
    <div class="sb-editor">
      <textarea class="sb-textarea" rows="3" spellcheck="false"></textarea>
      <div class="sb-editor-row">
        <button type="button" class="sb-btn primary sb-save">Save</button>
        <button type="button" class="sb-btn sb-cancel">Cancel</button>
        <span class="sb-editor-hint">Ctrl+Enter saves &middot; Esc cancels</span>
        <span class="sb-status" data-role="status"></span>
      </div>
    </div>
  `;
  const ta = td.querySelector(".sb-textarea");
  ta.value = raw;
  ta.focus();
  ta.setSelectionRange(ta.value.length, ta.value.length);

  const status = td.querySelector('[data-role="status"]');
  const saveBtn = td.querySelector(".sb-save");
  const cancelBtn = td.querySelector(".sb-cancel");

  const cancel = () => {
    td.classList.remove("editing");
    td.innerHTML = originalHtml;
  };

  const save = async () => {
    const value = ta.value;
    saveBtn.disabled = true;
    cancelBtn.disabled = true;
    status.className = "sb-status";
    status.textContent = "Saving...";
    try {
      const resp = await fetch("/api/sdk-rotation", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ table: Number(t), row: Number(r), col: Number(c), value }),
      });
      const j = await resp.json();
      if (!resp.ok) {
        throw new Error(j && j.error ? j.error : `HTTP ${resp.status}`);
      }
      try {
        const sect = STATE.board.sdk_rotation.tables[Number(t)];
        if (sect && sect.rows && sect.rows[Number(r)] && sect.rows[Number(r)].cells) {
          sect.rows[Number(r)].cells[Number(c)] = { raw: j.raw, html: j.html };
        }
      } catch (_) { /* best effort */ }
      td.dataset.raw = j.raw || "";
      td.classList.remove("editing");
      td.innerHTML = `<span class="sb-cell-html">${j.html || ""}</span><button type="button" class="sb-edit-btn" title="Edit cell" aria-label="Edit">&#9998;</button>`;
      toast(`Cell saved`, "success");
    } catch (e) {
      status.className = "sb-status error";
      status.textContent = e.message || "Save failed";
      saveBtn.disabled = false;
      cancelBtn.disabled = false;
    }
  };

  saveBtn.addEventListener("click", save);
  cancelBtn.addEventListener("click", cancel);
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { e.preventDefault(); cancel(); return; }
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); save(); return; }
  });
}

function wireSdkRowDnD(table) {
  const tbody = table.querySelector("tbody");
  if (!tbody) return;
  let dragRow = null;     // <tr> being dragged
  let dropRow = null;     // <tr> currently under the cursor
  let dropBefore = true;  // insert before or after dropRow

  const clearMarkers = () => {
    tbody.querySelectorAll("tr.sdk-row").forEach((tr) => {
      tr.classList.remove("dragging", "drop-before", "drop-after");
    });
  };

  tbody.addEventListener("dragstart", (ev) => {
    const handle = ev.target.closest(".sdk-drag-handle");
    const row = ev.target.closest("tr.sdk-row");
    if (!handle || !row) { ev.preventDefault(); return; }
    dragRow = row;
    row.classList.add("dragging");
    try {
      ev.dataTransfer.effectAllowed = "move";
      ev.dataTransfer.setData("text/plain", row.dataset.orig || "");
    } catch (_) { /* some browsers throw on setData with type filter */ }
  });

  tbody.addEventListener("dragover", (ev) => {
    if (!dragRow) return;
    const row = ev.target.closest("tr.sdk-row");
    if (!row || row === dragRow) return;
    ev.preventDefault();
    try { ev.dataTransfer.dropEffect = "move"; } catch (_) {}
    const rect = row.getBoundingClientRect();
    const before = (ev.clientY - rect.top) < (rect.height / 2);
    if (dropRow && dropRow !== row) {
      dropRow.classList.remove("drop-before", "drop-after");
    }
    dropRow = row;
    dropBefore = before;
    row.classList.toggle("drop-before", before);
    row.classList.toggle("drop-after", !before);
  });

  tbody.addEventListener("dragleave", (ev) => {
    const row = ev.target.closest("tr.sdk-row");
    if (row) {
      row.classList.remove("drop-before", "drop-after");
    }
  });

  tbody.addEventListener("drop", async (ev) => {
    ev.preventDefault();
    if (!dragRow || !dropRow || dragRow === dropRow) {
      clearMarkers();
      dragRow = null; dropRow = null;
      return;
    }
    // Build the new permutation off the current DOM order, then move
    // the dragRow next to dropRow.
    const rows = Array.from(tbody.querySelectorAll("tr.sdk-row"));
    const order = rows.map((tr) => Number(tr.dataset.orig));
    const fromIdx = rows.indexOf(dragRow);
    let toIdx = rows.indexOf(dropRow);
    const [moved] = order.splice(fromIdx, 1);
    if (fromIdx < toIdx) toIdx -= 1;
    if (!dropBefore) toIdx += 1;
    order.splice(toIdx, 0, moved);
    clearMarkers();
    dragRow = null; dropRow = null;
    await commitSdkOrder(order);
  });

  tbody.addEventListener("dragend", () => {
    clearMarkers();
    dragRow = null; dropRow = null;
  });
}

async function commitSdkOrder(order) {
  try {
    const resp = await fetch("/api/sdk-rotation/order", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ order }),
    });
    const j = await resp.json();
    if (!resp.ok) {
      throw new Error(j && j.error ? j.error : `HTTP ${resp.status}`);
    }
    if (j.snapshot) {
      STATE.board.sdk_rotation = j.snapshot;
      const oi = j.snapshot.order_table_index;
      if (typeof oi === "number" && STATE.board.sdk_rotation.tables[oi]) {
        STATE.board.counts.sdk_rotation_rows = STATE.board.sdk_rotation.tables[oi].rows.length;
      }
    }
    render();
    toast(`Reordered ${order.length} row(s).`, "success");
  } catch (e) {
    toast(`Reorder failed: ${e.message}`, "error");
    // Reload from disk so the DOM doesn't drift from the file.
    loadBoard();
  }
}


// ---- ADO Tracker tab ---------------------------------------------------

function adoStateClass(state) {
  const s = String(state || "").trim().toLowerCase();
  if (/^(done|closed|resolved|completed)$/.test(s)) return "done";
  if (/^(removed|cut)$/.test(s)) return "removed";
  if (/^(to do|new|proposed|open|approved|backlog)$/.test(s)) return "notstarted";
  return "inprogress";
}

function adoStatusPill(state) {
  const palette = {
    done: ["#e6f4ea", "#137333"],
    inprogress: ["#e8f0fe", "#1967d2"],
    notstarted: ["#f1f3f4", "#5f6368"],
    removed: ["#fce8e6", "#c5221f"],
  };
  const [bg, fg] = palette[adoStateClass(state)];
  const label = escHtml(state) || "&mdash;";
  return `<span style="display:inline-block;padding:2px 9px;border-radius:11px;font-size:12px;font-weight:600;background:${bg};color:${fg}">${label}</span>`;
}

function adoRelative(iso) {
  if (!iso) return "&mdash;";
  const dt = new Date(iso);
  if (isNaN(dt.getTime())) return "&mdash;";
  const mins = (Date.now() - dt.getTime()) / 60000;
  if (mins < 0) return dt.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  if (mins < 60) return `${Math.max(1, Math.round(mins))}m ago`;
  if (mins < 1440) return `${Math.round(mins / 60)}h ago`;
  if (mins < 10080) return `${Math.round(mins / 1440)}d ago`;
  return dt.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function renderAdoTracker(t) {
  if (t && t.error) {
    return `<div class="empty">Failed to read tracker: ${escHtml(t.error)}</div>`;
  }
  const items = (t && t.items) || [];
  if (!items.length) {
    return `<div class="empty">Not tracking any ADO items yet. In chat, say <code>track ADO &lt;id&gt;</code>.</div>`;
  }
  const gen = t.generated_at
    ? `Live fields synced ${adoRelative(t.generated_at)}.`
    : "Live fields not synced yet \u2014 they refresh on the hourly watch / daily digest.";
  const banner = `<div class="sb-banner"><b>Watchlist.</b> Add or remove by chat (<span class="mono">track ADO &lt;id&gt;</span> / <span class="mono">untrack ADO &lt;id&gt;</span>). ${gen}</div>`;
  const rows = items.map((it) => {
    const url = escHtml(it.url);
    const idChip = `<a href="${url}" target="_blank" rel="noopener" class="mono" style="color:#1967d2;text-decoration:none;white-space:nowrap">#${escHtml(it.id)}</a>`;
    let title = `<a href="${url}" target="_blank" rel="noopener" style="font-weight:600;text-decoration:none">${escHtml(it.title) || "(unsynced \u2014 title pending)"}</a>`;
    if (it.note) title += `<div style="color:#5f6368;font-size:12px;margin-top:2px">${escHtml(it.note)}</div>`;
    const owner = it.owner ? escHtml(it.owner) : `<span style="color:#c5221f">Unassigned</span>`;
    const ping = it.can_ping
      ? `<button type="button" class="ghost" data-act="ping-owner" data-id="${escHtml(it.id)}" title="Email ${escHtml(it.owner)} for a status update">Ping owner</button>`
      : `<button type="button" class="ghost" disabled title="No @microsoft.com owner to ping">Ping owner</button>`;
    return `<tr>
      <td>${idChip}</td>
      <td>${title}</td>
      <td>${escHtml(it.type)}</td>
      <td>${owner}</td>
      <td>${adoStatusPill(it.state)}</td>
      <td style="color:#5f6368;white-space:nowrap">${adoRelative(it.changed_date)}</td>
      <td style="text-align:right">${ping}</td>
    </tr>`;
  }).join("");
  return banner + `
    <section class="sb-section">
      <table class="sb-table">
        <thead><tr><th>Item</th><th>Title</th><th>Type</th><th>Owner</th><th>Status</th><th>Updated</th><th></th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </section>`;
}

async function pingAdoOwner(id, btn) {
  if (!id) return;
  const prev = btn.textContent;
  btn.disabled = true;
  btn.textContent = "Pinging\u2026";
  try {
    await api("/api/ado-tracker/ping", { method: "POST", body: JSON.stringify({ id: Number(id) }) });
    toast(`Status-check sent to the owner of #${id}`, "success");
    btn.textContent = "Pinged \u2713";
    setTimeout(() => { btn.disabled = false; btn.textContent = prev; }, 4000);
  } catch (e) {
    toast("Ping failed: " + e.message, "error");
    btn.disabled = false;
    btn.textContent = prev;
  }
}

// ---- My Day tab -------------------------------------------------------
// The landing view. Today's Outlook meetings + two server-computed lists:
// "needs attention" (overdue/due-today todos, snoozed-past items, 1:1 prep,
// recently-changed tracked ADO items, reminders firing today) and "focus
// today" (a short ranked shortlist). Lazy-loaded from /api/my-day (a ~1-2s
// Outlook read, cached server-side) so the board stays fast; the last payload
// is kept across refreshes so the tab never flashes empty once loaded.

async function loadMyDay(force) {
  if (STATE.myDayLoading) return;
  STATE.myDayLoading = true;
  try {
    STATE.myDay = await api("/api/my-day" + (force ? "?refresh=1" : ""));
  } catch (e) {
    // Keep any previous payload; only synthesize an error shell on first load.
    if (STATE.myDay === null) {
      STATE.myDay = { meetings: [], needs_attention: [], focus: [], stats: {}, calendar_available: false, error: e.message };
    }
  } finally {
    STATE.myDayLoading = false;
    renderCounts();
    if (STATE.tab === "my-day") renderCards();
  }
}

const MYDAY_TONE_CLASS = {
  danger: "bad", warning: "snoozed", accent: "kind", neutral: "neutral", good: "good",
};

function mydayToneClass(tone) {
  return MYDAY_TONE_CLASS[tone] || "subtle";
}

// A meeting is "now" if the local clock sits inside [start, end).
function meetingIsNow(m) {
  try {
    const now = Date.now();
    return new Date(m.start).getTime() <= now && now < new Date(m.end).getTime();
  } catch { return false; }
}

function renderMeetingRow(m) {
  const now = meetingIsNow(m);
  const tags = [];
  if (m.is_one_on_one) tags.push(`<span class="pill kind">1:1</span>`);
  if (m.online) tags.push(`<span class="pill subtle">online</span>`);
  if (m.busy_label === "Out of office") tags.push(`<span class="pill subtle">OOF</span>`);
  if (m.response_label === "Tentative" || m.response_label === "Not responded") {
    tags.push(`<span class="pill subtle" title="Your response: ${escHtml(m.response_label)}">${escHtml(m.response_label.toLowerCase())}</span>`);
  }
  const loc = m.location ? `<span class="myday-mtg-loc">${escHtml(m.location)}</span>` : "";
  const prep = (m.is_one_on_one && m.partner_open)
    ? `<button type="button" class="linklike" data-act="goto" data-tab="one-on-ones" data-ref="${escHtml(m.partner_slug)}">${m.partner_open} to raise &rarr;</button>`
    : "";
  return `<div class="myday-mtg${now ? " is-now" : ""}">
    <div class="myday-mtg-time">${escHtml(m.time_label || "")}${now ? `<span class="myday-now">now</span>` : ""}</div>
    <div class="myday-mtg-body">
      <div class="myday-mtg-subj">${escHtml(m.subject || "(no subject)")} ${tags.join(" ")}</div>
      <div class="myday-mtg-meta">${loc}${prep}</div>
    </div>
  </div>`;
}

function renderSuggestionRow(s) {
  const cls = mydayToneClass(s.tone);
  const clickable = s.tab ? ` data-act="goto" data-tab="${escHtml(s.tab)}"${s.ref ? ` data-ref="${escHtml(s.ref)}"` : ""}` : "";
  const cursor = s.tab ? " is-clickable" : "";
  return `<div class="myday-item${cursor}"${clickable}>
    <span class="pill ${cls}">${escHtml(s.tag || "")}</span>
    <span class="myday-item-text">${escHtml(s.text || "")}</span>
  </div>`;
}

function renderMyDay(data) {
  if (data === null) {
    return `<div class="empty">Loading your day&hellip; <span class="mono">(reading today's calendar)</span></div>`;
  }
  const stats = data.stats || {};
  const meetings = data.meetings || [];
  const needs = data.needs_attention || [];
  const focus = data.focus || [];

  // Hero strip: a one-line headline + a small stat grid.
  const bits = [];
  bits.push(`${stats.meetings || 0} meeting${(stats.meetings === 1) ? "" : "s"}`);
  if (stats.first_meeting) bits.push(`first at ${escHtml(stats.first_meeting.split("\u2013")[0])}`);
  if (stats.needs_attention) bits.push(`${stats.needs_attention} need${stats.needs_attention === 1 ? "s" : ""} attention`);
  const gen = data.generated_at ? `Updated ${adoRelative(data.generated_at)}.` : "";
  const hero = `<div class="myday-hero">
    <div class="myday-headline">${escHtml(bits.join(" \u00b7 "))}</div>
    <div class="myday-stats">
      <span class="myday-stat"><b>${stats.meetings || 0}</b> meetings</span>
      <span class="myday-stat"><b>${stats.overdue || 0}</b> overdue</span>
      <span class="myday-stat"><b>${stats.due_today || 0}</b> due today</span>
      <span class="myday-stat"><b>${focus.length}</b> to focus</span>
      <span class="myday-gen">${gen} <button type="button" class="ghost" data-act="reload-myday">Refresh</button></span>
    </div>
  </div>`;

  // Meetings column.
  let mtgHtml;
  if (data.calendar_available === false) {
    mtgHtml = `<div class="myday-note">${escHtml(data.calendar_error || data.error || "Calendar unavailable (Outlook not reachable).")}</div>`;
  } else if (!meetings.length) {
    mtgHtml = `<div class="myday-note">No meetings on the calendar today. Enjoy the focus time.</div>`;
  } else {
    mtgHtml = meetings.map(renderMeetingRow).join("");
  }

  const needsHtml = needs.length
    ? needs.map(renderSuggestionRow).join("")
    : `<div class="myday-note">Nothing flagged &mdash; no overdue items, no prep due. Nice.</div>`;

  const focusHtml = focus.length
    ? focus.map((f, i) => {
        const cls = mydayToneClass(f.tone);
        const clickable = f.tab ? ` data-act="goto" data-tab="${escHtml(f.tab)}"${f.ref ? ` data-ref="${escHtml(f.ref)}"` : ""}` : "";
        const cursor = f.tab ? " is-clickable" : "";
        return `<div class="myday-focus${cursor}"${clickable}>
          <span class="myday-focus-rank">${i + 1}</span>
          <span class="myday-focus-text">${escHtml(f.text || "")}</span>
          <span class="pill ${cls}">${escHtml(f.tag || "")}</span>
        </div>`;
      }).join("")
    : `<div class="myday-note">No must-dos surfaced. Pick a high-priority todo or prep an upcoming 1:1.</div>`;

  return hero + `
    <div class="myday-grid">
      <section class="myday-col myday-col-wide">
        <h3 class="myday-h">Today's meetings <span class="myday-count">${meetings.length}</span></h3>
        <div class="myday-meetings">${mtgHtml}</div>
      </section>
      <section class="myday-col">
        <h3 class="myday-h">Needs your attention <span class="myday-count">${needs.length}</span></h3>
        <div class="myday-list">${needsHtml}</div>
        <h3 class="myday-h" style="margin-top:1.1rem">Focus today <span class="myday-count">${focus.length}</span></h3>
        <div class="myday-list">${focusHtml}</div>
      </section>
    </div>`;
}

// ---- Scheduled tasks tab ----------------------------------------------
// Read-only view of the DM-* Windows Scheduled Tasks that fire Nirvana's
// skills unattended. Lazy-loaded from /api/scheduled-tasks (a ~2s PowerShell
// enumeration) so the main board stays fast.

async function loadScheduledTasks(force) {
  if (STATE.scheduledLoading) return;
  STATE.scheduledLoading = true;
  try {
    STATE.scheduledTasks = await api("/api/scheduled-tasks" + (force ? "?refresh=1" : ""));
  } catch (e) {
    STATE.scheduledTasks = { tasks: [], count: 0, available: true, error: e.message };
  } finally {
    STATE.scheduledLoading = false;
    renderCounts();
    if (STATE.tab === "scheduled-tasks") renderCards();
  }
}

function schedFmtDateTime(iso) {
  if (!iso) return `<span style="color:var(--cp-text-muted)">&mdash;</span>`;
  const dt = new Date(iso);
  if (isNaN(dt.getTime())) return `<span style="color:var(--cp-text-muted)">&mdash;</span>`;
  return escHtml(dt.toLocaleString(undefined, {
    month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
  }));
}

function schedStatePill(state) {
  const s = String(state || "").trim().toLowerCase();
  if (s === "ready")    return `<span class="pill good">Ready</span>`;
  if (s === "running")  return `<span class="pill neutral">Running</span>`;
  if (s === "disabled") return `<span class="pill muted">Disabled</span>`;
  return `<span class="pill subtle">${escHtml(state) || "&mdash;"}</span>`;
}

function schedResultPill(code, lastRun) {
  if (!lastRun) return `<span class="pill muted">never run</span>`;
  const n = Number(code);
  if (n === 0)      return `<span class="pill good">OK</span>`;
  if (n === 267009) return `<span class="pill neutral">running</span>`;    // 0x41301
  if (n === 267011) return `<span class="pill muted">not yet run</span>`;  // 0x41303
  const hex = (n >>> 0).toString(16).toUpperCase();
  return `<span class="pill bad" title="Last task result 0x${hex}">err 0x${hex}</span>`;
}

function renderScheduledTasks(data) {
  if (data === null) {
    return `<div class="empty">Loading scheduled tasks&hellip; <span class="mono">(Get-ScheduledTask DM-*)</span></div>`;
  }
  if (data.error) {
    return `<div class="empty">Couldn't enumerate scheduled tasks: ${escHtml(data.error)}</div>`;
  }
  if (data.available === false) {
    return `<div class="empty">${escHtml(data.note || "Scheduled-task enumeration is only available on Windows.")}</div>`;
  }
  const tasks = data.tasks || [];
  const gen = data.generated_at ? `Enumerated ${adoRelative(data.generated_at)}.` : "";
  const banner = `<div class="sb-banner"><b>Windows Task Scheduler.</b> Every task matching <span class="mono">DM-*</span> &mdash; the schedules that run Nirvana's skills unattended. Read-only. ${gen} <button type="button" class="ghost" data-act="reload-scheduled" style="margin-left:.4rem">Refresh</button></div>`;
  if (!tasks.length) {
    return banner + `<div class="empty">No <span class="mono">DM-*</span> scheduled tasks registered.</div>`;
  }
  const rows = tasks.map((t) => {
    const name = `<span class="mono" style="font-weight:600">${escHtml(t.name)}</span>`;
    const expl = t.explanation
      ? `<div title="${escHtml(t.explanation)}" style="max-width:66ch;line-height:1.4;max-height:2.8em;overflow:hidden;color:var(--cp-text-muted);font-size:.85rem">${escHtml(t.explanation)}</div>`
      : `<span style="color:var(--cp-text-muted)">&mdash;</span>`;
    const schedule = t.schedule
      ? `<span class="mono" style="font-size:.82rem">${escHtml(t.schedule)}</span>`
      : `<span style="color:var(--cp-text-muted)">&mdash;</span>`;
    return `<tr>
      <td>${name}</td>
      <td>${expl}</td>
      <td>${schedule}</td>
      <td style="white-space:nowrap">${schedFmtDateTime(t.next_run)}</td>
      <td style="white-space:nowrap">${schedFmtDateTime(t.last_run)} ${schedResultPill(t.last_result, t.last_run)}</td>
      <td>${schedStatePill(t.state)}</td>
    </tr>`;
  }).join("");
  return banner + `
    <section class="sb-section">
      <table class="sb-table">
        <thead><tr><th>Task</th><th>What it does</th><th>Schedule</th><th>Next run</th><th>Last run</th><th>State</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </section>`;
}

function render() {
  renderCounts();
  renderCards();
}

// ---- Add modal ---------------------------------------------------------

const ADD_FIELDS = {
  todos: [
    { name: "title",    label: "Title",          type: "text",     required: true },
    { name: "category", label: "Category",       type: "select",   options: ["work", "personal"], default: "work" },
    { name: "priority", label: "Priority",       type: "select",   options: ["H", "M", "L"],       default: "M" },
    { name: "due",      label: "Due (YYYY-MM-DD or 'tomorrow' / '-' / etc.)", type: "text", default: "-" },
    { name: "recur",    label: "Recur",          type: "select",   options: ["none", "weekly", "monthly"], default: "none" },
    { name: "notes",    label: "Notes",          type: "textarea" },
  ],
  agenda: [
    { name: "title",       label: "Title",          type: "text",     required: true },
    { name: "kind",        label: "Kind",           type: "select",   options: ["discussion", "follow-up"], default: "discussion" },
    { name: "opened_by",   label: "Opened by",      type: "text",     default: "Nir" },
    { name: "owner",       label: "Owner",          type: "text",     default: "TBD" },
    { name: "summary",     label: "Summary",        type: "textarea" },
    { name: "why_matters", label: "Why it matters", type: "textarea" },
    { name: "next_step",   label: "Next step",      type: "textarea" },
    { name: "notes",       label: "Notes",          type: "textarea" },
  ],
  "ai-plan": [
    { name: "title",       label: "Title",          type: "text",     required: true },
    { name: "kind",        label: "Kind",           type: "select",   options: ["discussion", "follow-up"], default: "discussion" },
    { name: "opened_by",   label: "Opened by",      type: "text",     default: "Nir" },
    { name: "owner",       label: "Owner",          type: "text",     default: "TBD" },
    { name: "summary",     label: "Summary",        type: "textarea" },
    { name: "why_matters", label: "Why it matters", type: "textarea" },
    { name: "next_step",   label: "Next step",      type: "textarea" },
    { name: "notes",       label: "Notes",          type: "textarea" },
  ],
  "one-on-ones": [
    { name: "title",       label: "Title",          type: "text",     required: true },
    { name: "kind",        label: "Kind",           type: "select",   options: ["discussion", "follow-up"], default: "discussion" },
    { name: "opened_by",   label: "Opened by",      type: "text",     default: "Nir" },
    { name: "owner",       label: "Owner",          type: "text",     default: "TBD" },
    { name: "summary",     label: "Summary",        type: "textarea" },
    { name: "why_matters", label: "Why it matters", type: "textarea" },
    { name: "next_step",   label: "Next step",      type: "textarea" },
    { name: "notes",       label: "Notes",          type: "textarea" },
  ],
};

// Modal state - which mode it's in and (if edit) which item it points at.
// mode = "add" | "edit". When "edit", patchTarget carries { path, label, id }.
let MODAL_MODE = "add";
let MODAL_PATCH_TARGET = null;

function openAddModal() {
  const tab = STATE.tab;
  if (tab === "one-on-ones" && !STATE.partner) {
    toast("Pick a 1:1 partner first.", "error");
    return;
  }
  MODAL_MODE = "add";
  MODAL_PATCH_TARGET = null;
  const fields = ADD_FIELDS[tab];
  const titleSuffix = tab === "one-on-ones"
    ? ` (for ${(STATE.board.one_on_ones.find(p => p.slug === STATE.partner) || {}).label})`
    : "";
  $("modal-title").textContent = `Add ${tab === "todos" ? "Todo" : tab === "agenda" ? "Agenda item" : tab === "ai-plan" ? "AI Plan item" : "1:1 talking point"}${titleSuffix}`;
  $("modal-submit").textContent = "Add";
  renderFormFields(fields, {});
  $("form-error").classList.add("hidden");
  $("modal-backdrop").classList.remove("hidden");
  setTimeout(() => $("form-fields").querySelector("input,textarea,select")?.focus(), 30);
}

function openEditModal(ns, id, slug) {
  // ns = "agenda" | "ai-plan" | "one-on-one"
  const b = STATE.board;
  if (!b) return;
  let item = null;
  let label = "";
  let path = "";
  if (ns === "agenda") {
    item = (b.agenda || []).find((x) => x.id === id);
    label = "Agenda item";
    path = `/api/agenda/${id}`;
  } else if (ns === "ai-plan") {
    item = (b.ai_plan || []).find((x) => x.id === id);
    label = "AI Plan item";
    path = `/api/ai-plan/${id}`;
  } else {
    const partner = (b.one_on_ones || []).find((p) => p.slug === slug);
    if (partner) {
      item = (partner.items || []).find((x) => x.id === id);
      label = `1:1 (${partner.label})`;
    }
    path = `/api/one-on-ones/${encodeURIComponent(slug)}/${id}`;
  }
  if (!item) { toast(`${id} not found in current snapshot.`, "error"); return; }
  MODAL_MODE = "edit";
  MODAL_PATCH_TARGET = { path, id, label, ns, slug };
  // Reuse the same field schema as ADD - it's a superset; "title" is
  // required, the rest are optional / clearable.
  const fields = ADD_FIELDS[ns === "agenda" ? "agenda" : ns === "ai-plan" ? "ai-plan" : "one-on-ones"];
  const values = {
    title:       item.title       || "",
    kind:        item.kind        || "discussion",
    opened_by:   item.opened_by   || "",
    owner:       item.owner       || "",
    summary:     item.summary     || "",
    why_matters: item.why_matters || "",
    next_step:   item.next_step   || "",
    notes:       item.notes       || "",
  };
  $("modal-title").textContent = `Edit ${id} - ${label}`;
  $("modal-submit").textContent = "Save";
  renderFormFields(fields, values);
  $("form-error").classList.add("hidden");
  $("modal-backdrop").classList.remove("hidden");
  setTimeout(() => $("form-fields").querySelector("input,textarea,select")?.focus(), 30);
}

function renderFormFields(fields, values) {
  const host = $("form-fields");
  host.innerHTML = fields.map((f) => {
    const has = Object.prototype.hasOwnProperty.call(values, f.name);
    const val = has ? values[f.name] : (f.default == null ? "" : f.default);
    if (f.type === "textarea") {
      return `<label>${escHtml(f.label)}<textarea name="${f.name}" rows="3">${escHtml(val)}</textarea></label>`;
    }
    if (f.type === "select") {
      const opts = f.options.map((o) => `<option value="${escHtml(o)}"${o === val ? " selected" : ""}>${escHtml(o)}</option>`).join("");
      return `<label>${escHtml(f.label)}<select name="${f.name}">${opts}</select></label>`;
    }
    return `<label>${escHtml(f.label)}<input type="text" name="${f.name}" value="${escHtml(val)}"${f.required ? " required" : ""} /></label>`;
  }).join("");
}

function closeAddModal() { $("modal-backdrop").classList.add("hidden"); MODAL_MODE = "add"; MODAL_PATCH_TARGET = null; }

async function submitAdd(ev) {
  ev.preventDefault();
  if (MODAL_MODE === "edit" && MODAL_PATCH_TARGET) {
    return submitEdit(ev);
  }
  const tab = STATE.tab;
  const fields = ADD_FIELDS[tab];
  const data = {};
  for (const f of fields) {
    const el = ev.target.elements[f.name];
    if (el) data[f.name] = el.value;
  }
  const submit = $("modal-submit");
  submit.disabled = true;
  try {
    let path = "";
    if (tab === "todos") path = "/api/todos";
    else if (tab === "agenda") path = "/api/agenda";
    else if (tab === "ai-plan") path = "/api/ai-plan";
    else if (tab === "one-on-ones") path = `/api/one-on-ones/${encodeURIComponent(STATE.partner)}`;
    const out = await api(path, { method: "POST", body: JSON.stringify(data) });
    closeAddModal();
    toast(`Added ${out.id}`, "success");
    await loadBoard();
  } catch (e) {
    const errEl = $("form-error");
    errEl.textContent = e.message;
    errEl.classList.remove("hidden");
  } finally {
    submit.disabled = false;
  }
}

async function submitEdit(ev) {
  const target = MODAL_PATCH_TARGET;
  if (!target) return;
  const tab = target.ns === "one-on-one" ? "one-on-ones" : target.ns;
  const fields = ADD_FIELDS[tab];
  const data = {};
  for (const f of fields) {
    const el = ev.target.elements[f.name];
    if (el) data[f.name] = el.value;
  }
  if (!data.title || !data.title.trim()) {
    const errEl = $("form-error");
    errEl.textContent = "Title cannot be empty.";
    errEl.classList.remove("hidden");
    return;
  }
  const submit = $("modal-submit");
  submit.disabled = true;
  try {
    await api(target.path, {
      method: "PATCH",
      body: JSON.stringify({ action: "edit", fields: data }),
    });
    closeAddModal();
    toast(`${target.id} updated`, "success");
    await loadBoard();
  } catch (e) {
    const errEl = $("form-error");
    errEl.textContent = e.message;
    errEl.classList.remove("hidden");
  } finally {
    submit.disabled = false;
  }
}

// ---- Snooze modal ------------------------------------------------------

let snoozeTargetId = null;

function openSnooze(ptId) {
  snoozeTargetId = ptId;
  const today = new Date();
  today.setDate(today.getDate() + 7);
  $("snooze-date").value = today.toISOString().slice(0, 10);
  $("snooze-backdrop").classList.remove("hidden");
  setTimeout(() => $("snooze-date").focus(), 30);
}

function closeSnooze() { $("snooze-backdrop").classList.add("hidden"); }

async function submitSnooze(ev) {
  ev.preventDefault();
  const d = $("snooze-date").value;
  if (!d || !snoozeTargetId) return;
  try {
    await api(`/api/todos/${snoozeTargetId}`, {
      method: "PATCH",
      body: JSON.stringify({ action: "snooze", snoozed_until: d }),
    });
    closeSnooze();
    toast(`${snoozeTargetId} snoozed to ${d}`, "success");
    await loadBoard();
  } catch (e) {
    toast(e.message, "error");
  }
}

// ---- Card actions ------------------------------------------------------

async function patchItem(path, payload, label) {
  try {
    await api(path, { method: "PATCH", body: JSON.stringify(payload) });
    toast(label, "success");
    await loadBoard();
    // My Day derives from the same stores; keep it in sync after a close/reopen.
    loadMyDay(false);
  } catch (e) {
    toast(e.message, "error");
  }
}

// Delegated input handler: every keystroke in a client-side-only textarea
// is mirrored into STATE.*Drafts so it survives the 30s auto-refresh
// re-render (and tab/partner switches). Cleared by the matching Send/Save.
function onCardsInput(ev) {
  const t = ev.target;
  if (!t || typeof t.matches !== "function") return;
  if (t.matches(".sum-text[data-sum-input]")) {
    const root = t.closest("[data-sum-slug]");
    if (root && root.dataset.sumSlug) {
      STATE.summaryDrafts[root.dataset.sumSlug] = t.value;
    }
    return;
  }
  if (t.matches(".pn-text[data-pn-input]")) {
    const root = t.closest("[data-pn-slug]");
    if (root && root.dataset.pnSlug) {
      STATE.notesDrafts[root.dataset.pnSlug] = t.value;
    }
    return;
  }
}

function onCardsClick(ev) {
  // Handle the "scope board >>" link in the per-direct header card.
  const a = ev.target.closest('a[data-act="goto-scope-board"]');
  if (a) {
    ev.preventDefault();
    setTab("scope-board");
    return;
  }
  // My Day: a meeting/suggestion/focus row (or its prep button) can deep-link
  // into another tab. These targets are divs or buttons, so handle them before
  // the button-only guard below.
  const goto = ev.target.closest('[data-act="goto"]');
  if (goto) {
    ev.preventDefault();
    const gtab = goto.dataset.tab;
    const gref = goto.dataset.ref;
    if (gtab === "one-on-ones" && gref) {
      setTab("one-on-ones");
      setPartner(gref);
    } else if (gtab) {
      setTab(gtab);
    }
    return;
  }
  const reload = ev.target.closest('[data-act="reload-myday"]');
  if (reload) {
    reload.disabled = true;
    reload.textContent = "Refreshing\u2026";
    loadMyDay(true).then(() => toast("My Day refreshed.", "success"));
    return;
  }
  const btn = ev.target.closest("button");
  if (!btn) return;
  const card = btn.closest(".card");
  const act = btn.dataset.act;
  const id = btn.dataset.id;
  const slug = btn.dataset.slug;
  if (act === "expand") {
    const s = card.querySelector(".card-summary");
    if (s) s.classList.toggle("is-clipped");
    btn.textContent = s && s.classList.contains("is-clipped") ? "expand" : "collapse";
    return;
  }
  if (act === "expand-all") {
    const s = card.querySelector(".card-summary");
    if (s) s.classList.toggle("is-clipped");
    card.querySelectorAll('[data-section]').forEach((el) => el.classList.toggle("hidden"));
    const collapsed = s ? s.classList.contains("is-clipped") : true;
    btn.textContent = collapsed ? "expand" : "collapse";
    return;
  }
  if (act === "close-todo")    return patchItem(`/api/todos/${id}`, { action: "close"  }, `${id} closed`);
  if (act === "reopen-todo")   return patchItem(`/api/todos/${id}`, { action: "reopen" }, `${id} reopened`);
  if (act === "snooze-todo")   return openSnooze(id);
  if (act === "close-agenda")  return patchItem(`/api/agenda/${id}`, { action: "close"  }, `${id} closed`);
  if (act === "reopen-agenda") return patchItem(`/api/agenda/${id}`, { action: "reopen" }, `${id} reopened`);
  if (act === "edit-agenda")   return openEditModal("agenda", id);
  if (act === "close-ai-plan")  return patchItem(`/api/ai-plan/${id}`, { action: "close"  }, `${id} closed`);
  if (act === "reopen-ai-plan") return patchItem(`/api/ai-plan/${id}`, { action: "reopen" }, `${id} reopened`);
  if (act === "edit-ai-plan")   return openEditModal("ai-plan", id);
  if (act === "close-on")      return patchItem(`/api/one-on-ones/${encodeURIComponent(slug)}/${id}`, { action: "close"  }, `${id} closed`);
  if (act === "reopen-on")     return patchItem(`/api/one-on-ones/${encodeURIComponent(slug)}/${id}`, { action: "reopen" }, `${id} reopened`);
  if (act === "edit-on")       return openEditModal("one-on-one", id, slug);
  if (act === "ping-owner")    return pingAdoOwner(id, btn);
  if (act === "reload-scheduled") {
    btn.disabled = true;
    btn.textContent = "Refreshing\u2026";
    loadScheduledTasks(true).then(() => toast("Scheduled tasks refreshed.", "success"));
    return;
  }

  if (btn.hasAttribute("data-pn-save")) {
    const root = btn.closest("[data-pn-slug]");
    if (!root) return;
    const pnSlug = root.dataset.pnSlug;
    const ta = root.querySelector("[data-pn-input]");
    const status = root.querySelector("[data-pn-status]");
    if (!ta) return;
    return savePersonalNotes(pnSlug, ta.value, status, btn);
  }
  if (btn.hasAttribute("data-sum-send") || btn.hasAttribute("data-sum-dry")) {
    const root = btn.closest("[data-sum-slug]");
    if (!root) return;
    const sumSlug = root.dataset.sumSlug;
    const ta = root.querySelector("[data-sum-input]");
    const status = root.querySelector("[data-sum-status]");
    const dryRun = btn.hasAttribute("data-sum-dry");
    if (!ta) return;
    return sendOneOnOneSummary(sumSlug, ta.value, dryRun, status, btn);
  }
}

async function savePersonalNotes(slug, text, statusEl, btn) {
  if (btn) btn.disabled = true;
  if (statusEl) { statusEl.textContent = "Saving..."; statusEl.classList.remove("error","good"); }
  try {
    await api(`/api/one-on-ones/${encodeURIComponent(slug)}/personal-notes`, {
      method: "PATCH",
      body: JSON.stringify({ text: text })
    });
    // Notes are now persisted server-side; drop the in-flight draft so
    // the next render falls back to STATE.board.personal_notes.
    delete STATE.notesDrafts[slug];
    if (statusEl) { statusEl.textContent = "Saved."; statusEl.classList.add("good"); }
    toast("Personal notes saved.", "success");
  } catch (e) {
    if (statusEl) { statusEl.textContent = "Failed: " + e.message; statusEl.classList.add("error"); }
    toast(e.message, "error");
  } finally {
    if (btn) btn.disabled = false;
  }
}

async function sendOneOnOneSummary(slug, notes, dryRun, statusEl, btn) {
  if (!dryRun) {
    if (!confirm(`Send the 1:1 summary email for ${slug}? (You'll be on CC.)`)) return;
  }
  if (btn) btn.disabled = true;
  let tick = null;
  if (statusEl) {
    statusEl.classList.remove("error","good");
    if (dryRun) {
      const t0 = Date.now();
      const paint = () => { statusEl.textContent = `Rendering preview... ${Math.round((Date.now()-t0)/1000)}s (rewriting your notes)`; };
      paint();
      tick = setInterval(paint, 1000);
    } else {
      statusEl.textContent = "Spawning runner...";
    }
  }
  try {
    const res = await api(`/api/one-on-ones/${encodeURIComponent(slug)}/summary`, {
      method: "POST",
      body: JSON.stringify({ notes: notes, dry_run: dryRun })
    });
    if (tick) { clearInterval(tick); tick = null; }
    if (dryRun) {
      // Synchronous path: the backend returns the rendered email HTML.
      if (res && res.preview_html) {
        showSummaryPreview(slug, res.preview_html);
        if (statusEl) { statusEl.textContent = "Preview ready."; statusEl.classList.add("good"); }
        toast(`Preview ready for ${slug}.`, "success");
      } else {
        const why = (res && res.warning) ? res.warning : "No preview was produced.";
        if (statusEl) { statusEl.textContent = why; statusEl.classList.add("error"); }
        toast(why, "error");
        if (res && res.detail) console.warn("[summary preview]", res.detail);
      }
      return;
    }
    // Real send: the draft has done its job, drop it so the textarea
    // resets next render.
    delete STATE.summaryDrafts[slug];
    const ta = document.querySelector(`[data-sum-slug="${slug}"] [data-sum-input]`);
    if (ta) ta.value = "";
    if (statusEl) {
      statusEl.textContent = `Queued (send). Check reports/logs/one-on-one-prep-*.log.`;
      statusEl.classList.add("good");
    }
    toast(`1:1 summary send queued for ${slug}.`, "success");
  } catch (e) {
    if (tick) { clearInterval(tick); tick = null; }
    if (statusEl) { statusEl.textContent = "Failed: " + e.message; statusEl.classList.add("error"); }
    toast(e.message, "error");
  } finally {
    if (tick) { clearInterval(tick); tick = null; }
    if (btn) btn.disabled = false;
  }
}

// Render the dry-run email HTML in a full-screen overlay with a sandboxed
// iframe (the email carries its own styles, so it must be isolated from the
// board's CSS). Built lazily and reused across previews.
function showSummaryPreview(slug, html) {
  let ov = document.getElementById("summary-preview-overlay");
  if (!ov) {
    ov = document.createElement("div");
    ov.id = "summary-preview-overlay";
    ov.style.cssText = "position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.55);" +
      "display:flex;align-items:center;justify-content:center;padding:24px;";
    ov.innerHTML =
      '<div style="background:#fff;width:min(820px,96vw);height:min(86vh,900px);' +
      'border-radius:10px;overflow:hidden;display:flex;flex-direction:column;' +
      'box-shadow:0 18px 60px rgba(0,0,0,.4);">' +
        '<div style="display:flex;align-items:center;justify-content:space-between;' +
        'padding:10px 14px;background:#1f2430;color:#fff;font:600 13px system-ui;">' +
          '<span id="summary-preview-title">1:1 summary preview</span>' +
          '<button type="button" id="summary-preview-close" ' +
          'style="background:#3a4150;color:#fff;border:0;border-radius:6px;' +
          'padding:5px 12px;cursor:pointer;font:600 13px system-ui;">Close</button>' +
        '</div>' +
        '<iframe id="summary-preview-frame" title="preview" ' +
        'style="border:0;width:100%;height:100%;background:#fff;"></iframe>' +
      '</div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.addEventListener("click", (e) => { if (e.target === ov) close(); });
    ov.querySelector("#summary-preview-close").addEventListener("click", close);
    document.addEventListener("keydown", function onEsc(e) {
      if (e.key === "Escape" && document.getElementById("summary-preview-overlay")) {
        ov.remove(); document.removeEventListener("keydown", onEsc);
      }
    });
  }
  const titleEl = ov.querySelector("#summary-preview-title");
  if (titleEl) titleEl.textContent = `1:1 summary preview - ${slug}`;
  const frame = ov.querySelector("#summary-preview-frame");
  if (frame) frame.srcdoc = html;
}

// ---- Wire everything ---------------------------------------------------

function wire() {
  $("brand-ascii").textContent = ASCII;
  document.querySelectorAll(".nav-item[data-tab]").forEach((el) => {
    el.addEventListener("click", () => setTab(el.dataset.tab));
  });
  document.querySelectorAll(".nav-item.filter").forEach((el) => {
    el.addEventListener("click", () => setFilter(el.dataset.filter));
  });
  $("refresh-btn").addEventListener("click", () => { loadBoard(); loadMyDay(true); loadScheduledTasks(true); });
  $("theme-btn").addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme");
    const next = cur === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("nirvana-theme", next);
  });
  $("add-btn").addEventListener("click", openAddModal);
  $("modal-close").addEventListener("click", closeAddModal);
  $("modal-cancel").addEventListener("click", closeAddModal);
  $("modal-backdrop").addEventListener("click", (e) => { if (e.target.id === "modal-backdrop") closeAddModal(); });
  $("add-form").addEventListener("submit", submitAdd);
  $("snooze-close").addEventListener("click", closeSnooze);
  $("snooze-cancel").addEventListener("click", closeSnooze);
  $("snooze-backdrop").addEventListener("click", (e) => { if (e.target.id === "snooze-backdrop") closeSnooze(); });
  $("snooze-form").addEventListener("submit", submitSnooze);
  $("cards-host").addEventListener("click", onCardsClick);
  $("cards-host").addEventListener("input", onCardsInput);

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeAddModal(); closeSnooze(); }
  });

  // Auto-refresh every 30s. Skip the tick if the user is actively typing
  // in one of the client-side-only textareas - otherwise the re-render
  // wipes their in-flight input mid-keystroke and resets the caret.
  setInterval(() => {
    if (STATE.loading) return;
    const ae = document.activeElement;
    if (ae && typeof ae.matches === "function" &&
        (ae.matches(".sum-text") || ae.matches(".pn-text"))) {
      return;
    }
    loadBoard();
    // Keep My Day current too (meetings are cached server-side, so this is a
    // cheap recompute of the needs-attention / focus lists).
    loadMyDay(false);
  }, 30000);
}

window.addEventListener("DOMContentLoaded", () => {
  wire();
  loadBoard();
  // Warm My Day (the landing tab) so today's meetings + attention list are
  // ready on first paint. Non-blocking.
  loadMyDay(false);
  // Warm the Scheduled tasks tab in the background so its sidebar count shows
  // up and the tab opens instantly. Non-blocking; the main board never waits.
  loadScheduledTasks(false);
});

