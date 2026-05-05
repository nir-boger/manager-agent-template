# Manager Agent Template

A starter kit for engineering managers who want a personal AI agent that
handles inbox triage, sprint reports, daily summaries, team milestones, and
related rituals.

## What you get

- An agent persona scaffold (prompts/CUSTOM_INSTRUCTIONS.md).
- Skills for inbox watching, sprint reports, PBI assignment, milestones,
  team personas, connect-buddy, and (optionally) WhatsApp.
- Scheduled-task runners with a migration-mode kill switch.
- A signature + joke pipeline driven by config.

## 5-minute setup

    git clone <this-repo> my-agent
    cd my-agent
    .\init.ps1                          # interactive setup
    .\doctor.ps1                        # validate environment
    .\smoke-test.ps1                    # safe end-to-end check

init.ps1 writes config/agent.json, renders AGENTS.md and
prompts/CUSTOM_INSTRUCTIONS.md from templates, and prompts you for a
banner / voice profile / feature toggles.

## Customize

- config/agent.json -- agent identity, manager identity, ADO/team scope,
  signature, voice, feature flags. Edit by hand or re-run init.ps1.
- config/banner.txt -- ASCII banner printed at session start.
- config/voice.md -- voice profile (tone, vocabulary, joke bank).
- config/signature-notice.txt -- one-line announcement appended to every
  signature; empty file = no notice.
- .copilot/skills/team-personas/people/ -- one Markdown file per direct
  report. Persona-dependent skills auto-disable while this directory is empty.

See docs/CUSTOMIZE.md and docs/SECURITY.md for the long form.

## Skills

The shipping skill set is defined in config/skills.json. Run init.ps1
to enable individual skills; persona-dependent ones (inbox-watch,
team-milestones, connect-buddy) require at least one persona file.

## License

MIT.
