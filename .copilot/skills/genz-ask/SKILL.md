# Skill: genz-ask

## Purpose
A **prank-flavored task-assignment composer** for Nir. Whenever Nir says "send an ask GenZ style" (or a paraphrase — see triggers), draft a short Hebrew message that hands off a task / asks the team to look at something, in the **Your Team Group WhatsApp register, dialed up to 11**. Then deliver it via the channel Nir specifies (email by default; WhatsApp / Teams if asked).

This is a voice/composition skill, not a delivery channel — it composes the body and routes through an existing delivery skill (`email-team`, `post-to-teams`, `whatsapp`).

## Trigger → action mapping
| User intent | Action |
|---|---|
| "send an ask GenZ style", "ask the team GenZ style", "GenZ ask", "GenZ task assignment", "genz-ask" | **compose + deliver** — Hebrew GenZ task assignment |
| "draft a GenZ ask" / "GenZ ask (draft only)" / instruction contains `PREVIEW` or `draft only` | **compose only** — return the body to Nir in chat, do not send |

## Voice (the whole point)
Hebrew, **GenZ team slang dialed up**. Lean on the `Your Team Group` WhatsApp profile (single source of truth: `config/whatsapp-profiles.md` → "Your Team Group — work group (general team)") and amplify these signals:

1. **`וש`-suffix gimmick (mandatory anchor — at least one per message).** Add `וש` to a short concrete Hebrew noun: `תור` → `תורוש`, `באג` → `באגוש`, `סוף שבוע` → `סוף שבועוש`, `קומה` → `קומוש`, `מצב` → `מצבוש`, `דד-ליין` → `דד-ליינוש`, `שעה` → `שעהוש`. Goal: **one or two `וש` words per message**, never more (it stops landing). Restrictions:
   - **Don't `וש`-ify** people's names, English words written in Latin (ASAP / OMG / PR / API stay bare), anything already ending in `וש`/`ושש`, or anything with a hard guttural ending.
   - When in doubt, leave the word bare.
2. **`טובות`** — tail-end sweetener on the ask itself (`תקפצו לזה ASAP טובות`). Optional but encouraged.
3. **`ביוש`** — GenZ "OK?" / "deal?" tag, usually as a one-liner question (`ביוש?`). Optional. **Never both `טובות` and `ביוש` stacked on the same sentence** — pick one per sentence; both in one message is fine if spread.
4. **`יש אותך`** — closing sign-off / props beat. Default position: **last content line of the body**, before the joke + signature. Skip only if Nir explicitly says no `יש אותך` (or if the message has no clear addressee).
5. **Openers (optional, max one):** `היוש`, `סבבוש`, `מה ניש`. Sometimes none — bare-bones is fine.
6. **Reactions (only when warranted):** `שוקינג`, `OMG`. One per message max.
7. **Emojis:** a couple of warm/expressive ones are on-brand (🙌 🚀 😱 🔥 ✨ 😅 🤖). **No heart emojis** — same hard rule as the WhatsApp profile (`❤️ 🧡 💛 💚 💙 💜 🤍 🤎 🖤 💕 💖 💗 💘 💝 💞 💟 🩷 🥰 😘 🌹` — none of these, ever).
8. **No canon collisions in the body itself unless Nir asked:** stay off Sauvignon Blanc / Jura / Reformer / `טאביזזזז` / "7 or 8?" unless the actual task touches them. The skill is its own thing.

**Length:** keep it tight — 2–5 short paragraphs / lines. A GenZ ask that drones is no longer GenZ.

**Default leanness (calibrated 2026-05-14 — saved Nir preference):** the slang reads as parody when piled on, but too lean reads cold. Target the **middle**:

- **Body length:** 3–4 short lines (opener + ask + optional tag + `יש אותך` close).
- **`וש`-words:** 1 in the body as the anchor; optionally 1 more in the joke trailer. **Hard cap: 2 total** across body + joke. Never 3+.
- **Sweeteners:** both `טובות` and `ביוש` are welcome in the same message **only if they live on different sentences / lines** (e.g. `… ASAP טובות.` on one line, `ביוש?` on its own line). Never both inside the same sentence.
- **Emojis:** 2–3 total across subject + body + joke. 4+ tips into parody. 0 reads cold.
- **Opener:** light (`היוש,` or `היוש 👋`). Avoid stuffed openers like `היוש כפרות 👋` unless the moment really warrants it.
- **Always close with `יש אותך`** (typically paired with 🙌 emoji) unless Nir overrode.

**Composition order (skeleton):**
```
[optional opener]
<the actual ask, with one וש word and either טובות or ביוש>
[optional ביוש? or follow-up question]
יש אותך 🙌
```

## Inputs Nir provides (parsed from the request)
- **The ask itself** — what task / problem the team should look at. Mandatory.
- **Phrases Nir wants verbatim** — e.g. *"Nirvana, maybe use `עולה בקצב טילים פסיכי`"*. **Honor these literally.** Drop them into the body as-is; do not "improve" the wording.
- **Closing override** — e.g. *"end with `יש אותך`"*. Honor verbatim.
- **Delivery channel** — `email` (default), `whatsapp`, `teams`. Inferred from the request ("email to self", "post to teams", "send on whatsapp"). If unclear → email to `team@example.com` by default; if the request says "to me" / "to self" → email to Nir's own address only.
- **Specific recipients** — explicit `To` / `Cc` if Nir names them, otherwise route to the channel's default.

## Delivery — route through an existing skill (never duplicate plumbing)
| Channel | How |
|---|---|
| `email` | Hand the composed HTML + subject to `email-team`. Subject **must** start with `[Nirvana] - ` (the email-team helper enforces this anyway). RTL HTML body (`dir="rtl"`). Honor `NOJOKE` / `NOSIG` from Nir's instruction. |
| `whatsapp` | Hand to `whatsapp` with `--chat "Your Team Group"` — auto-send carve-out applies. Append the `WhatsAppGroupHe` signature via `Get-NirvanaSignatureText`. |
| `teams` | Hand to `post-to-teams` (no signature, no joke — same as the regular Teams rules). |

**Default channel:** if the request says nothing about channel, ask Nir once which channel — don't guess. Exception: if the request explicitly says "to me" / "test it to me" / "to self" → email to Nir's own address (`you@example.com`) without asking.

## Email-specific rules
- Subject: short, GenZ-flavored. **Always prepend `[Nirvana] - `** (the email-team rule). Example: `[Nirvana] - תורוש עולה בקצב טילים פסיכי 🚀`.
- Body: HTML, `dir="rtl"`, font Segoe UI 14px, paragraphs separated by `<p>` blocks.
- Joke: the body itself is the joke (the whole GenZ register is the bit). Still **append one short Hebrew one-liner** in `<p><em>…</em></p>` above the signature — keep it in the same GenZ register (a `וש`-flavored quip works) unless `NOJOKE` is set.
- Signature: append via `Get-NirvanaSignature` — honors `NOSIG`. Default variant is fine.
- Log line: `email-team` writes the standard log entry to `reports/email/YYYY-MM-DD.md`. No extra logging needed from this skill.

## What this skill MUST NOT do
- **Never modify ADO work items.** This skill never opens / updates / assigns / comments on a work item, regardless of what the body says. The body is *language only* — the actual task assignment happens via the team reading the message and acting.
- **Never auto-broadcast.** No scheduled task, no auto-fire. Always Nir-initiated.
- **Never break the `WhatsApp` skill's preview/auto-send rules.** If the channel is WhatsApp, this skill is just the composer — `whatsapp`'s auto-send rules for the Your Team group still apply, and `PREVIEW` / `draft only` overrides still route to preview-first.
- **Never use heart emojis** (see the no-heart rule above).
- **Never call this from `agent-todos`'s dispatcher** without explicit `genz-ask:` directive in the TODO body — this is a deliberately silly voice and shouldn't get triggered by ambient "send the team an email" todos.

## Worked example (the original test ask)
**Nir's request:** *"Hi, the queue is raising like crazy (Nirvana, maybe use עולה בקצב טילים פסיכי), I need you to look at it ASAP. OK? (and end with יש אותך)"* — delivered as email to self.

**Composed body (calibrated middle):**
```
היוש 👋

התורוש עולה בקצב טילים פסיכי — תקפצו על זה ASAP טובות.

ביוש?

יש אותך 🙌
```

**Subject:** `[Nirvana] - תורוש עולה בקצב טילים פסיכי 🚀`

**Trailing one-liner (joke slot):** `אם הבאגוש שורד עד הצהריים, קומה 7 או 8 לבלאנץ'?` (one `וש` in the joke — total 2 across body+joke, at the cap; ties into the canonical lunch gag).

> **Calibration history (2026-05-14):** the first draft stacked `כפרות 👋` + two `וש`-words *plus* `באגוש` *plus* `צהריימוש` in the joke + four emojis — Nir flagged as "too much". The over-corrected next pass cut to one `וש`, one sweetener, one emoji — Nir flagged as too cold. The version above is the calibrated middle: light opener, one `וש` in body + one in joke, both `טובות` and `ביוש?` present but on separate lines, two emojis in the body (👋 + 🙌). That's the saved default.

## Pre-send self-check (run this once before delivery)
- [ ] At least one `וש`-suffixed word in the body? (anchor)
- [ ] No more than two `וש` words? (don't overdose)
- [ ] At least one of `טובות` / `ביוש`? (sweetener present)
- [ ] Closes with `יש אותך` (unless Nir overrode)?
- [ ] Verbatim phrases Nir asked for are present, unchanged?
- [ ] No heart emojis?
- [ ] No internal work info (designs / roadmap / ADO links) leaked into the body?
- [ ] Subject prefixed `[Nirvana] - ` (for email)?
- [ ] Length is 2–5 short lines, not a wall of text?

If any check fails → fix or omit the offending bit before sending. A missing element beats a forced one.


