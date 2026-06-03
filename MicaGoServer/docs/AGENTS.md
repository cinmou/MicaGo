# Workspace

You are a general-purpose assistant running on Codex web. This repo is your workspace.

## Workflow

Your context window will be compacted during long tasks. Use checkpoint files to survive this.

### Checkpoint File

Your first action on any task is to create `checkpoint.md`, commit and push. This is your single source of truth — always read it after context compaction to resume.

Use these as `##` headings:

- **Goal** — one-line summary
- **Context** — additional detail, constraints, and background that the goal line doesn't capture
- **Notes** — credentials, URLs, environment details, and key findings discovered during work. Pure reference, no narrative.
- **Progress** — what's been done, what's next, what's blocked

After every meaningful step — commit your work, update the checkpoint, commit and push again. The checkpoint should always reflect your current state so you can resume from it.

### When things go wrong

- **Failed attempt** → `git checkout .`, update checkpoint with what you learned, try a different approach
- **New user instruction** → update the current checkpoint or create a new one

### Key rules
- Always push immediately after every commit — never batch pushes
- Never carry forward work from a failed attempt
- Prefer clean solutions over workarounds

## Environment

- gVisor container (Ubuntu 24.04) with root access. Install whatever you need with `apt`.
- Internet access is only available through an HTTP proxy:
  - Direct outbound TCP/UDP to external IPs is blocked.
  - Proxy env vars are set by default; if a program can't reach the internet, verify it's using them.
  - No DNS server — use DoH through the proxy.
- The gVisor environment has various limitations. Never say "can't do this" — find a workaround first.

## Saving Reusable Procedures

When you discover a non-obvious procedure that would help future sessions (e.g. environment workarounds, tool setup, build fixes), save it as a **skill** so the user can cherry-pick it to main.

- Save them as **skills** (`.Codex/skills/<name>/SKILL.md`). Before writing your first skill, study the official skill-creator at https://github.com/anthropics/skills/tree/main/skills/skill-creator to learn the format and best practices.
- Don't over-create — only save procedures that were genuinely hard to figure out and would save real time next session.

## Conventions

- You are working autonomously, not presenting to a human. No one is reading your intermediate output — don't spend effort making it look nice.
- The user can see everything pushed to your branch but cannot read `/tmp`
- When cloning external repos, `.gitignore` them — don't commit other people's code unless asked to do so
