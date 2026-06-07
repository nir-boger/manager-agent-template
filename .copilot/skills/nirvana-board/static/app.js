// nirvana-board single-page app. Vanilla JS, no framework.

const ASCII =
`    _   _ _
    | \\ | (_)_ ____   ____ _ _ __   __ _
    |  \\| | | '__\\ \\ / / _\` | '_ \\ / _\` |
    | |\\  | | |   \\ V / (_| | | | | (_| |
    |_| \\_|_|_|    \\_/ \\__,_|_| |_|\\__,_|`;

const STATE = {
  board: null,
  tab: "todos",                 // "todos" | "agenda" | "one-on-ones"
  partner: null,                // slug when tab == one-on-ones
  filter: "open",               // "open" | "all"
  loading: false,
  // Client-side draft caches for textareas with no server-side autosave.
  // Survive renders + tab switches. Cleared on successful Send/Save.
  summaryDrafts: {},            // slug -> in-flight "Send 1:1 summary" text
  notesDrafts: {},              // slug -> in-flight "Personal notes" text
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
  // Hide + Add on scope-board / sdk-rotation (no add-row support yet).
  const addBtn = $("add-btn");
  if (addBtn) addBtn.style.display = (tab === "scope-board" || tab === "sdk-rotation") ? "none" : "";
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
  $("refresh-btn").addEventListener("click", () => loadBoard());
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
  }, 30000);
}

window.addEventListener("DOMContentLoaded", () => {
  wire();
  loadBoard();
});

