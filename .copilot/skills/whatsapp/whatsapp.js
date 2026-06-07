#!/usr/bin/env node
/**
 * Nirvana WhatsApp skill — Playwright-driven WhatsApp Web automation.
 *
 * Subcommands:
 *   login                  Open visible browser for one-time QR scan
 *   list-allowed           Print allowlist
 *   read --chat "X" [--limit N] [--since 2h]
 *   send --chat "X" --message "..." [--confirm SEND]
 *
 * Safety: strict allowlist (`allowlist.txt`); send is preview-only unless
 * `--confirm SEND` is passed (literal string `SEND`, case-sensitive).
 *
 * Signature mandatory on every send (saved Nir preference 2026-05-06): the
 * caller composes the body with the `WhatsAppGroupHe` signature already
 * appended. Joke is off by default; the `Your Team Group`
 * group also gets a Hebrew one-liner. No auto-poll. See SKILL.md for the
 * full contract.
 */

const path = require('path');
const fs = require('fs');
const os = require('os');

const SKILL_DIR = __dirname;
const REPO_ROOT = path.resolve(SKILL_DIR, '..', '..', '..');
const PROFILE_DIR = path.join(REPO_ROOT, '.playwright-profiles', 'whatsapp');
const ALLOWLIST_PATH = path.join(SKILL_DIR, 'allowlist.txt');
const LOG_DIR = path.join(REPO_ROOT, 'reports', 'whatsapp');
const WHATSAPP_URL = 'https://web.whatsapp.com';

const DEFAULT_READ_LIMIT = 30;
const MAX_READ_LIMIT = 200;
const LOG_BODY_TRUNCATE = 200;

// ---------- arg parsing ----------
function parseArgs(argv) {
    const [, , cmd, ...rest] = argv;
    const args = { _cmd: cmd };
    for (let i = 0; i < rest.length; i++) {
        const a = rest[i];
        if (a.startsWith('--')) {
            const key = a.slice(2);
            const next = rest[i + 1];
            if (next === undefined || next.startsWith('--')) {
                args[key] = true;
            } else {
                args[key] = next;
                i++;
            }
        }
    }
    return args;
}

// ---------- name normalization ----------
// Strip bidi/format marks (RTL hellos, ZWNBSP, etc.), NFKC-normalize, collapse
// whitespace, lowercase. Critical for Hebrew names and copy-pasted entries.
function normalizeName(s) {
    if (!s) return '';
    return String(s)
        .replace(/[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '')
        .normalize('NFKC')
        .replace(/\s+/g, ' ')
        .trim()
        .toLowerCase();
}

// ---------- allowlist ----------
function loadAllowlist() {
    if (!fs.existsSync(ALLOWLIST_PATH)) return [];
    let raw = fs.readFileSync(ALLOWLIST_PATH, 'utf8');
    if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1); // strip UTF-8 BOM
    const lines = raw.split(/\r?\n/);
    return lines
        .map(l => l.trim())
        .filter(l => l.length > 0 && !l.startsWith('#'))
        .map(raw => {
            const isGroup = /^\[group\]\s*/i.test(raw);
            const name = raw.replace(/^\[group\]\s*/i, '').trim();
            return { raw, name, normalized: normalizeName(name), isGroup };
        });
}

function findAllowlistEntry(allowlist, requested) {
    const needle = normalizeName(requested);
    return allowlist.find(e => e.normalized === needle) || null;
}

function refuseNotAllowed(name) {
    const msg = `'${name}' is not on the WhatsApp allowlist. Add it to .copilot/skills/whatsapp/allowlist.txt (prefix [group] if it's a group) and retry.`;
    process.stderr.write(msg + '\n');
    process.exit(2);
}

// ---------- since parsing ----------
function parseSince(s) {
    if (!s) return null;
    const m = String(s).match(/^(\d+)\s*([hdm])$/i);
    if (!m) return null;
    const n = parseInt(m[1], 10);
    const unit = m[2].toLowerCase();
    const ms = unit === 'h' ? n * 3600 * 1000 : unit === 'd' ? n * 86400 * 1000 : n * 60 * 1000;
    return new Date(Date.now() - ms);
}

// data-pre-plain-text is "[HH:MM, DD/MM/YYYY] Sender Name: "
function parsePrePlainText(s) {
    if (!s) return { ts: null, sender: null };
    const m = s.match(/^\[(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*(AM|PM))?,\s*(\d{1,2})\/(\d{1,2})\/(\d{2,4})\]\s*([^:]*):\s*$/i);
    if (!m) return { ts: null, sender: s.replace(/[\[\]:]/g, '').trim() || null };
    let [, hh, mm, ss, ampm, d, mo, y, sender] = m;
    let H = parseInt(hh, 10);
    if (ampm) {
        if (/PM/i.test(ampm) && H < 12) H += 12;
        if (/AM/i.test(ampm) && H === 12) H = 0;
    }
    const year = y.length === 2 ? 2000 + parseInt(y, 10) : parseInt(y, 10);
    const ts = new Date(year, parseInt(mo, 10) - 1, parseInt(d, 10), H, parseInt(mm, 10), ss ? parseInt(ss, 10) : 0);
    return { ts: isNaN(ts.getTime()) ? null : ts, sender: sender.trim() };
}

// ---------- logging ----------
function logAction(line) {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    const today = new Date().toISOString().slice(0, 10);
    const file = path.join(LOG_DIR, `${today}.md`);
    const stamp = new Date().toISOString();
    fs.appendFileSync(file, `- ${stamp} ${line}\n`, 'utf8');
}

function truncate(s, n) {
    if (!s) return '';
    s = String(s).replace(/\s+/g, ' ');
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

// ---------- browser plumbing ----------
async function launchContext({ headless }) {
    let chromium;
    try {
        ({ chromium } = require('playwright'));
    } catch (e) {
        process.stderr.write('Playwright not installed. Run: npm install (in this folder) and retry.\n');
        process.exit(3);
    }
    fs.mkdirSync(PROFILE_DIR, { recursive: true });
    // WhatsApp Web fingerprints true headless and refuses to finish loading.
    // For non-login flows we want a browser the user doesn't have to interact with —
    // launch headful but minimized via a real user agent + window-position trick.
    // Caller passes headless: false for `login` (visible QR) and `'auto'` otherwise.
    const realHeadless = headless === false ? false : false; // always headful — see comment above
    const launchOpts = {
        headless: realHeadless,
        viewport: { width: 1280, height: 900 },
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        args: [
            '--disable-blink-features=AutomationControlled',
            // Keep the long-lived WhatsApp Web WebSocket healthy even when the
            // window is moved offscreen / minimized. Chrome aggressively
            // throttles background/occluded windows; that can quietly drop the
            // relay socket and leave a "sent" bubble stuck on the pending
            // clock forever — the root cause of the 2026-05-02 missed send to
            // Partner (bubble rendered optimistically, never relayed).
            '--disable-backgrounding-occluded-windows',
            '--disable-renderer-backgrounding',
            '--disable-background-timer-throttling',
        ],
    };
    if (headless === 'auto') {
        // Move the window off-screen and minimize so it doesn't steal focus / clutter.
        launchOpts.args.push('--window-position=-2400,-2400');
        launchOpts.args.push('--window-size=1280,900');
    }
    const ctx = await chromium.launchPersistentContext(PROFILE_DIR, launchOpts);
    const page = ctx.pages()[0] || (await ctx.newPage());
    return { ctx, page };
}

async function gotoWhatsApp(page) {
    await page.goto(WHATSAPP_URL, { waitUntil: 'domcontentloaded' });
}

async function getLoginState(page) {
    const loggedIn = await page.locator('#pane-side, #side').first().isVisible().catch(() => false);
    if (loggedIn) return 'logged-in';
    const qrVisible = await page.locator('canvas[aria-label*="QR" i], canvas[aria-label*="קוד" i], canvas').first().isVisible().catch(() => false);
    if (qrVisible) return 'qr';
    return 'loading';
}

// Wait until the user is fully logged in (side pane visible). Used by `login`,
// which polls patiently through the QR-scan phase. Returns true on success,
// false on timeout.
async function waitForLoggedIn(page, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const state = await getLoginState(page);
        if (state === 'logged-in') return true;
        await page.waitForTimeout(500);
    }
    return false;
}

// Fast precondition for read/send: fail immediately if QR is showing instead of
// hanging on a session that needs human action.
async function ensureLoggedIn(page) {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
        const state = await getLoginState(page);
        if (state === 'logged-in') return;
        if (state === 'qr') {
            throw new Error('Not logged in to WhatsApp Web. Run `whatsapp.ps1 login` to scan the QR code (one-time).');
        }
        await page.waitForTimeout(500);
    }
    throw new Error('Timed out waiting for WhatsApp Web to load.');
}

async function findSearchBox(page) {
    // WhatsApp Web changed: the search field is now a real <input> (not contenteditable).
    const byTab = page.locator('input[data-tab="3"][role="textbox"]').first();
    if (await byTab.isVisible().catch(() => false)) return byTab;
    const sideScoped = page.locator('#side input[role="textbox"]').first();
    if (await sideScoped.isVisible().catch(() => false)) return sideScoped;
    // Last-resort fallback: contenteditable in #side (older builds)
    const legacy = page.locator('#side div[contenteditable="true"][role="textbox"]').first();
    if (await legacy.isVisible().catch(() => false)) return legacy;
    throw new Error('Search box not found. WhatsApp Web UI may have changed.');
}

async function clearSearch(page) {
    // Press Escape twice to close any open chat / clear search state.
    await page.keyboard.press('Escape').catch(() => {});
    await page.waitForTimeout(120);
    await page.keyboard.press('Escape').catch(() => {});
    await page.waitForTimeout(120);
}

// Best-effort group classification of a chat row or header element.
// Returns true if positive group signal, false if positive 1:1 signal,
// null if inconclusive (custom avatar, ambiguous DOM).
async function classifyGroupKind(scope) {
    const groupHits = await scope.locator('[data-icon*="group" i], [aria-label*="group" i], [aria-label*="קבוצ" i]').count().catch(() => 0);
    if (groupHits > 0) return true;
    const userHits = await scope.locator('[data-icon="default-user"], [data-icon*="user" i]').count().catch(() => 0);
    if (userHits > 0) return false;
    return null;
}

async function detectOfflineBanner(page) {
    // WhatsApp Web shows a "Computer not connected" / "Phone not connected" banner.
    // Locale-tolerant: match common substrings.
    const txt = await page.locator('body').innerText().catch(() => '');
    const m = txt.match(/(phone not connected|computer not connected|trouble connecting|reconnecting|טלפון לא מחובר|מתחבר מחדש)/i);
    return m ? m[0] : null;
}

async function openChat(page, entry) {
    await clearSearch(page);

    const offline = await detectOfflineBanner(page);
    if (offline) throw new Error(`WhatsApp Web appears offline ("${offline}"). Reconnect on your phone and retry.`);

    const search = await findSearchBox(page);
    await search.click();
    // <input> path uses fill(); contenteditable path uses keyboard.type after focusing.
    const tag = await search.evaluate(el => el.tagName).catch(() => '');
    if (tag === 'INPUT' || tag === 'TEXTAREA') {
        await search.fill('');
        await search.fill(entry.name.slice(0, 80));
    } else {
        await search.fill('');
        await page.keyboard.type(entry.name.slice(0, 80), { delay: 25 });
    }
    await page.waitForTimeout(900);

    // Scope strictly to the sidebar (#pane-side) — avoid clicking composer/etc.
    await page.waitForSelector('#pane-side', { timeout: 10_000 });
    // Match either the new structure (div[role="row"]) or the old (div[role="listitem"]).
    const rows = page.locator('#pane-side div[role="row"], #pane-side div[role="listitem"]');
    const count = await rows.count();
    if (count === 0) throw new Error(`Search returned no rows for "${entry.name}".`);

    const matches = [];
    for (let i = 0; i < Math.min(count, 30); i++) {
        const row = rows.nth(i);
        // Each row has multiple span[title]; the chat name is the FIRST one (avatar/last-msg titles come later).
        const titles = await row.locator('span[title]').evaluateAll(els => els.map(e => e.getAttribute('title') || '')).catch(() => []);
        const nameTitle = titles[0] || '';
        if (normalizeName(nameTitle) === entry.normalized) {
            const kind = await classifyGroupKind(row);
            matches.push({ row, title: nameTitle, kind });
        }
    }
    if (matches.length === 0) {
        throw new Error(`No exact match for "${entry.name}" in the sidebar. (Search returned ${count} rows; none matched after normalization.)`);
    }

    // Filter by group/1:1 expectation. Inconclusive (kind === null) survives.
    const kindCompatible = matches.filter(m => m.kind === null || m.kind === entry.isGroup);
    const kindContradicts = matches.filter(m => m.kind !== null && m.kind !== entry.isGroup);
    if (kindCompatible.length === 0) {
        throw new Error(`Found "${entry.name}" but kind contradicts allowlist entry (allowlist says ${entry.isGroup ? 'group' : '1:1'}; row says ${kindContradicts[0].kind ? 'group' : '1:1'}). Aborting.`);
    }
    if (kindCompatible.length > 1) {
        throw new Error(`Multiple chats named "${entry.name}" in the sidebar (${kindCompatible.length}). Refusing to guess. Rename or pin the intended one and retry.`);
    }

    await kindCompatible[0].row.click();
    await page.waitForSelector('#main header', { timeout: 10_000 });
    // The header has several span[title] (e.g. avatar tooltip, "click here for contact info", chat name).
    // Match against title attributes AND visible text — robust to ordering / structure changes.
    const headerNames = await page.locator('#main header').evaluateAll(headers => {
        if (!headers[0]) return [];
        const h = headers[0];
        const titles = Array.from(h.querySelectorAll('span[title]')).map(s => s.getAttribute('title') || '');
        const texts = Array.from(h.querySelectorAll('span'))
            .map(s => (s.innerText || '').trim())
            .filter(t => t.length > 0 && t.length < 120);
        return [...titles, ...texts];
    }).catch(() => []);
    const headerMatch = headerNames.find(t => normalizeName(t) === entry.normalized);
    if (!headerMatch) {
        const sample = headerNames.slice(0, 8).map(t => `"${t}"`).join(', ');
        throw new Error(`Could not open chat "${entry.name}". Header candidates: [${sample}]. Aborting to avoid wrong-chat actions.`);
    }
    const openName = headerMatch;
    // Final group-vs-1:1 sanity check on the open header (best-effort).
    const headerKind = await classifyGroupKind(page.locator('#main header'));
    if (headerKind !== null && headerKind !== entry.isGroup) {
        throw new Error(`Header indicates this is a ${headerKind ? 'group' : '1:1'} but allowlist entry is ${entry.isGroup ? 'group' : '1:1'}. Aborting.`);
    }
    return openName;
}

// ---------- read ----------
async function cmdRead(args) {
    const chat = args.chat;
    if (!chat) { process.stderr.write('Missing --chat\n'); process.exit(1); }
    let limit = parseInt(args.limit, 10);
    if (!Number.isFinite(limit) || limit <= 0) limit = DEFAULT_READ_LIMIT;
    limit = Math.min(limit, MAX_READ_LIMIT);
    const since = parseSince(args.since);

    const allowlist = loadAllowlist();
    const entry = findAllowlistEntry(allowlist, chat);
    if (!entry) refuseNotAllowed(chat);

    const { ctx, page } = await launchContext({ headless: 'auto' });
    try {
        await gotoWhatsApp(page);
        await ensureLoggedIn(page);
        const openName = await openChat(page, entry);

        // Wait for at least one message to render. If a chat is empty, that's fine — fall through.
        await page.waitForSelector('#main div.copyable-text[data-pre-plain-text]', { timeout: 10_000 }).catch(() => {});

        const rows = page.locator('#main div.copyable-text[data-pre-plain-text]');
        const total = await rows.count();
        const start = Math.max(0, total - limit);
        const out = [];
        let unparsedTs = 0;
        for (let i = start; i < total; i++) {
            const row = rows.nth(i);
            const pre = (await row.getAttribute('data-pre-plain-text').catch(() => '')) || '';
            const text = (await row.locator('span.selectable-text').first().innerText().catch(() => null))
                ?? (await row.innerText().catch(() => ''));
            const { ts, sender } = parsePrePlainText(pre);
            if (!ts) unparsedTs++;
            // When --since is supplied, only include messages we can confidently date.
            if (since) {
                if (!ts) continue;
                if (ts < since) continue;
            }
            out.push({
                ts: ts ? ts.toISOString() : null,
                sender: sender || null,
                text: text || '',
            });
        }

        if (since && unparsedTs > 0) {
            // Surface to stderr so Nir knows some messages were dropped due to locale parsing.
            process.stderr.write(`Note: ${unparsedTs} message(s) had unparseable timestamps and were excluded by --since. WhatsApp Web locale may not match the parser.\n`);
        }

        process.stdout.write(JSON.stringify({ chat: openName, isGroup: entry.isGroup, count: out.length, messages: out }, null, 2) + '\n');
        logAction(`read chat='${openName}' count=${out.length} limit=${limit}${since ? ` since='${args.since}'` : ''}`);
    } finally {
        await ctx.close().catch(() => {});
    }
}

// ---------- send ----------
async function cmdSend(args) {
    const chat = args.chat;
    const message = args.message;
    if (!chat || !message) { process.stderr.write('Missing --chat or --message\n'); process.exit(1); }
    const confirmed = args.confirm === 'SEND'; // strict literal

    const allowlist = loadAllowlist();
    const entry = findAllowlistEntry(allowlist, chat);
    if (!entry) refuseNotAllowed(chat);

    if (!confirmed) {
        const preview = [
            'WhatsApp preview',
            `To:      ${entry.name}${entry.isGroup ? ' [group]' : ''}`,
            `Message: ${message}`,
            '',
            "(preview only — re-run with --confirm SEND to actually send)",
        ].join('\n');
        process.stdout.write(preview + '\n');
        logAction(`send (preview) chat='${entry.name}' body='${truncate(message, LOG_BODY_TRUNCATE)}'`);
        return;
    }

    const { ctx, page } = await launchContext({ headless: 'auto' });
    try {
        await gotoWhatsApp(page);
        await ensureLoggedIn(page);
        const openName = await openChat(page, entry);

        const composer = page.locator('#main footer div[contenteditable="true"][role="textbox"]').first();
        await composer.waitFor({ state: 'visible', timeout: 10_000 });
        await composer.click();

        // Snapshot existing outbound bubbles so we can confirm a NEW one appears.
        const outboundSel = '#main div.message-out';
        const beforeCount = await page.locator(outboundSel).count().catch(() => 0);

        // Paste via clipboard — far more reliable than keyboard.type for Unicode + newlines.
        // Falls back to keyboard.type if clipboard write fails.
        let pasteOk = false;
        try {
            await page.evaluate(async (text) => {
                await navigator.clipboard.writeText(text);
            }, message);
            // Ctrl+V into focused composer
            await page.keyboard.press('Control+V');
            pasteOk = true;
        } catch (e) {
            // Fallback: type line-by-line with Shift+Enter
            const lines = message.split(/\r?\n/);
            for (let i = 0; i < lines.length; i++) {
                await page.keyboard.type(lines[i], { delay: 20 });
                if (i < lines.length - 1) {
                    await page.keyboard.down('Shift');
                    await page.keyboard.press('Enter');
                    await page.keyboard.up('Shift');
                }
            }
        }
        // Re-check offline state immediately before pressing Enter — connection
        // can drop between openChat() and the send, and a stuck pending bubble
        // is the visible symptom (the wire issue Partner hit on 2026-05-02).
        const offlinePreEnter = await detectOfflineBanner(page);
        if (offlinePreEnter) {
            throw new Error(`WhatsApp Web went offline before send ("${offlinePreEnter}"). Reconnect on your phone and retry.`);
        }

        await page.waitForTimeout(400);
        await page.keyboard.press('Enter');
        const sendStartMs = Date.now();

        // Phase 1: wait up to 20s for a NEW outbound bubble to appear in #main.
        // Also fast-fail if the latest bubble carries an explicit error aria-label.
        const appearDeadline = Date.now() + 20_000;
        let bubbleAppeared = false;
        let appearanceMs = null;
        while (Date.now() < appearDeadline) {
            const state = await page.evaluate((selector) => {
                const bubbles = document.querySelectorAll(selector);
                if (!bubbles.length) return { count: 0 };
                const last = bubbles[bubbles.length - 1];
                const errEl = last.querySelector('[aria-label*="went wrong" i], [aria-label*="not sent" i], [aria-label*="failed" i]');
                return {
                    count: bubbles.length,
                    hasError: !!errEl,
                    errorLabel: errEl ? errEl.getAttribute('aria-label') : null,
                };
            }, outboundSel).catch(() => ({ count: beforeCount }));
            if (state.hasError) {
                throw new Error(`WhatsApp reported send failure: "${state.errorLabel || 'Something went wrong'}". Phone may be disconnected or message was rejected. The failed bubble is in the chat — delete it on your phone if needed.`);
            }
            if (state.count > beforeCount) {
                bubbleAppeared = true;
                appearanceMs = Date.now() - sendStartMs;
                break;
            }
            await page.waitForTimeout(250);
        }
        if (!bubbleAppeared) {
            throw new Error('Could not confirm send — no new outbound message bubble appeared within 20s. Phone may be disconnected or message rejected.');
        }

        // Phase 2: bind to the specific new bubble (nth(beforeCount)) and wait
        // for its status icon to transition out of pending. WhatsApp Web's
        // status icons (data-icon attribute):
        //   msg-time           = pending  (clock)            — NOT yet sent
        //   msg-check          = sent     (single grey tick) — server received
        //   msg-dblcheck       = delivered (double tick)
        //   msg-dblcheck-ack   = read     (blue double tick)
        // A bubble stuck on msg-time after 45s means the message never left the
        // Web client's outbox — the recipient hasn't received it. Fail CLOSED
        // ("unverified"), not as definite failure: it may still send later
        // after reconnect, and a definite "didn't deliver" risks a duplicate
        // resend on Nir's part.
        const deliveryDeadline = Date.now() + 45_000;
        let deliveryConfirmed = false;
        let lastIconState = null;
        let finalSuccessIcon = null;
        let deliveryMs = null;
        while (Date.now() < deliveryDeadline) {
            const state = await page.evaluate((selector, idx) => {
                const bubbles = document.querySelectorAll(selector);
                if (idx >= bubbles.length) return { exists: false };
                const target = bubbles[idx];
                const errEl = target.querySelector('[aria-label*="went wrong" i], [aria-label*="not sent" i], [aria-label*="failed" i]');
                const icons = Array.from(target.querySelectorAll('[data-icon]')).map(e => e.getAttribute('data-icon'));
                return {
                    exists: true,
                    hasError: !!errEl,
                    errorLabel: errEl ? errEl.getAttribute('aria-label') : null,
                    icons,
                };
            }, outboundSel, beforeCount).catch(() => ({ exists: false }));
            if (state.hasError) {
                throw new Error(`WhatsApp reported delayed send failure: "${state.errorLabel || 'Something went wrong'}". The message did not deliver.`);
            }
            if (state.exists) {
                lastIconState = state.icons;
                const successIcon = state.icons.find(i => i === 'msg-check' || i === 'msg-dblcheck' || i === 'msg-dblcheck-ack');
                if (successIcon) {
                    finalSuccessIcon = successIcon;
                    deliveryConfirmed = true;
                    deliveryMs = Date.now() - sendStartMs;
                    break;
                }
            }
            await page.waitForTimeout(500);
        }
        if (!deliveryConfirmed) {
            const offline = await detectOfflineBanner(page);
            const iconStr = lastIconState && lastIconState.length ? lastIconState.join(',') : 'none';
            const cause = offline
                ? `WhatsApp Web is offline ("${offline}").`
                : `WhatsApp Web may have a sync issue (phone background, multi-device hiccup).`;
            throw new Error(
                `Send unverified — bubble appeared but never transitioned to sent within 45s ` +
                `(last icons: [${iconStr}]). Delivery is UNVERIFIED — the message may still send ` +
                `later once the client recovers, or may be stuck in the outbox. ${cause} ` +
                `Reconnect (\`whatsapp.ps1 login\` if needed) and verify on the phone before ` +
                `retrying to avoid a duplicate.`
            );
        }

        process.stdout.write(`Sent to ${openName}.\n`);
        logAction(`send (sent) chat='${openName}' body='${truncate(message, LOG_BODY_TRUNCATE)}' appear_ms=${appearanceMs} delivery_ms=${deliveryMs} icon=${finalSuccessIcon}`);
    } finally {
        await ctx.close().catch(() => {});
    }
}

// ---------- login ----------
async function cmdLogin() {
    const { ctx, page } = await launchContext({ headless: false });
    try {
        await gotoWhatsApp(page);
        process.stdout.write('Opened WhatsApp Web. Scan the QR code with your phone (WhatsApp → Settings → Linked Devices → Link a device).\n');
        process.stdout.write('Waiting up to 10 minutes for login... (will exit as soon as you finish scanning)\n');
        const ok = await waitForLoggedIn(page, 10 * 60_000);
        if (ok) {
            process.stdout.write('Logged in. Session persisted; closing the browser.\n');
            logAction('login (success)');
            await page.waitForTimeout(2000);
        } else {
            process.stdout.write('Timed out waiting for QR scan. Re-run `.\\whatsapp.ps1 login` when you are ready.\n');
            logAction('login (timeout)');
        }
    } finally {
        await ctx.close().catch(() => {});
    }
}

// ---------- list-allowed ----------
function cmdListAllowed() {
    const allowlist = loadAllowlist();
    if (allowlist.length === 0) {
        process.stdout.write('Allowlist is empty. Edit .copilot/skills/whatsapp/allowlist.txt to add chats.\n');
        return;
    }
    process.stdout.write('WhatsApp allowlist:\n');
    for (const e of allowlist) {
        process.stdout.write(`  ${e.isGroup ? '[group] ' : '        '}${e.name}\n`);
    }
}

// ---------- main ----------
(async () => {
    const args = parseArgs(process.argv);
    try {
        switch (args._cmd) {
            case 'login':         await cmdLogin();        break;
            case 'list-allowed':  cmdListAllowed();        break;
            case 'read':          await cmdRead(args);     break;
            case 'send':          await cmdSend(args);     break;
            default:
                process.stdout.write([
                    'Usage:',
                    '  node whatsapp.js login',
                    '  node whatsapp.js list-allowed',
                    '  node whatsapp.js read --chat "<name>" [--limit 30] [--since 2h]',
                    '  node whatsapp.js send --chat "<name>" --message "<text>" [--confirm SEND]',
                ].join('\n') + '\n');
                process.exit(args._cmd ? 1 : 0);
        }
    } catch (err) {
        process.stderr.write(`Error: ${err && err.message ? err.message : err}\n`);
        process.exit(1);
    }
})();

