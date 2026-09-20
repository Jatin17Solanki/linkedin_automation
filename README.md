# LinkedIn Job Search Automation

**Wake up to a short list of fresh openings at the companies you care about — already scored against your resume.**

This project watches LinkedIn for new roles at a list of target companies, drops the ones that don't fit (wrong seniority, wrong city, too much experience required), asks an AI how well each remaining role matches *your* resume, and sends the results to your phone on Telegram. It runs on its own, several times a day, and never sends you the same job twice.

It's built with [n8n](https://n8n.io) (a visual workflow tool), Google Sheets (where you keep your settings), and Gemini (free-tier AI). You don't need to write code to use it.

<br>

<img width="1375" height="455" alt="How the pieces fit together" src="https://github.com/user-attachments/assets/b87a7269-584b-47bd-8cbc-2d28f6753763" />

<br>

[Detailed architecture →](https://jatin17solanki.github.io/linkedin_automation/)

## What you get

### 1. A scheduled job digest — from Bot #1

Eight times a day, one message lists everything new, best match first. 🟢 is a strong match, 🟡 a decent one, 🔴 a long shot.

```
🔔 3 New Openings Found

1. 🟢 82% — SDE II (3-5 yrs) [SDE-II]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/123

2. 🟡 65% — Software Engineer (3+ yrs) [Backend]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/456

3. 🔴 38% — Cloud Engineer (5+ yrs) [Generic]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/789
```

*(Illustrative sample.)* Nothing new? You get a one-line "ran fine, no new openings" so you know it's alive. If the AI is unavailable one run, you still get the list, unscored, with a warning.

<!-- SCREENSHOT SLOT: docs/images/digest.png — real Telegram screenshot of the scheduled digest (Bot #1) -->

### 2. An on-demand company lookup — from Bot #2

Curious about one company right now? Message the second bot:

```
/search Oracle 30
```

```
🔍 Jobs at Oracle (last 30 days) — 5 openings

1. 🟢 82% — Software Engineer III (3-5 yrs) [SE-III]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/123
   …
```

It also emails you a fuller report: a one-line summary of each role, the skills you match, and the gaps. (Partial names work — `/search clear` finds ClearTrip and ClearTax.)

<!-- SCREENSHOT SLOT: docs/images/search.png — real Telegram screenshot of /search (Bot #2) -->
<!-- SCREENSHOT SLOT: docs/images/email.png — the Gmail report -->

### 3. A LinkedIn job parser for Claude — optional

A tiny web address that turns any LinkedIn job link into clean structured data, plus an MCP server so **Claude** can call it directly ("parse this job for me").

### Why two Telegram bots?

Telegram sends a bot's incoming commands to exactly one place. The scheduled digest (`/jobs`) and the company lookup (`/search`) each need to receive their own commands, so each gets its own bot:

| | Bot #1 | Bot #2 |
|---|---|---|
| **Workflow** | Job Search | Company Search |
| **Does** | Sends the digests; on a cloud VM also answers `/jobs 6` | Answers `/search Oracle 30` |
| **Needed?** | Yes | Only if you want `/search` |

Creating a bot takes a minute — the [setup guide](SETUP_GUIDE.md#12-telegram-bots) walks through it.

<!-- SCREENSHOT SLOT: docs/images/two-bots.png — the two bot chats side by side -->

## The three workflows

| Workflow | Triggered by | Gives you | Works locally? |
|----------|--------------|-----------|:---:|
| **Job Search** | A schedule (8×/day), or `/jobs N`, or a local webhook | The scheduled digest, logged to your Sheet | ✅ (scheduled + manual) |
| **Company Search** | `/search Company [days]` on Telegram | On-demand lookup + email report | ❌ needs a cloud VM |
| **Job Parser** | A web request | Structured JSON for one job URL | ✅ |

You only *need* the first. The other two are already inside the project and stay dormant until you turn them on.

## Features

- **Config-driven** — your companies, city, experience range and match threshold live in a Google Sheet you edit in a browser. No code, no restarts.
- **Smart filtering** — drops staff/principal/manager/QA/devops roles, other cities, and roles asking for more experience than your target range.
- **AI matching** — Gemini scores each role against your resume (skills 40%, experience 30%, domain 20%, seniority 10%). Optionally hide anything below a match % you choose.
- **No repeats** — remembers every job it has shown you.
- **Gentle on LinkedIn** — waits between requests; it reads only public job pages.
- **Graceful** — if the AI fails you still get your list.
- **Multi-city** — search one city or several at once.

## Choose your setup

You need somewhere for n8n to run. Three options:

| | **Your own computer** | **AWS EC2** ⭐ recommended | **GCP** |
|---|---|---|---|
| **Best for** | Trying it out before committing | Running it 24/7 | Running it 24/7 (if you already use GCP) |
| **Cost** | Free | New accounts get a **6-month Free plan** (up to $200 credit), then normal hourly pricing — a few dollars a month | Free indefinitely, *but only after upgrading out of the 90-day trial* — otherwise it's suspended |
| **Runs when your computer is off?** | ❌ | ✅ | ✅ |
| **Scheduled digests** | ✅ only while your computer and Docker are on | ✅ | ✅ |
| **`/jobs` and `/search` from your phone** | ❌ | ✅ | ✅ |
| **Company Search + email report** | ❌ | ✅ | ✅ |
| **Job Parser / Claude tool** | ✅ | ✅ | ✅ |
| **Status in this project** | Tested | **Tested end to end** | Written, not yet run end to end |

**What doesn't work on your own computer:** anything you trigger by *messaging a bot*. Telegram delivers commands to a public HTTPS address, which a laptop doesn't have. So the `/jobs N` command and the entire Company Search workflow need a cloud VM. The scheduled digest works locally — but only while your machine is running.

**Our advice:** if you just want to see it work, start locally; when you like it, move to **AWS** for the always-on version. If you're already sure you want it running around the clock, go straight to AWS. (Everything you set up — your Sheet, bots and keys — carries over.)

## Get started

Everything is in the **[Setup Guide](SETUP_GUIDE.md)**. It starts with a checklist so you gather every key and account *first* and never have to stop halfway.

**Index**

- **[Part 1 — Before you start](SETUP_GUIDE.md#part-1-before-you-start--gather-everything-first)** — the checklist
  - [Create your Telegram bot(s)](SETUP_GUIDE.md#12-telegram-bots) · [Get a Gemini key](SETUP_GUIDE.md#13-gemini-api-key) · [Build your Google Sheet & load your resume](SETUP_GUIDE.md#14-your-google-sheet-and-your-resume) · [Google OAuth client](SETUP_GUIDE.md#15-google-cloud-oauth-client)
- **[Part 2 — Run n8n](SETUP_GUIDE.md#part-2-run-n8n)** — [locally](SETUP_GUIDE.md#2a-locally-with-docker) · [AWS](SETUP_GUIDE.md#2b-on-aws-ec2-recommended-for-cloud) · [GCP](SETUP_GUIDE.md#2c-on-gcp)
- **[Part 3 — Connect n8n to your accounts](SETUP_GUIDE.md#part-3-connect-n8n-to-your-accounts)**
- **[Part 4 — Optional workflows](SETUP_GUIDE.md#part-4-the-optional-workflows)** — [Company Search](SETUP_GUIDE.md#41-company-search-search) · [Job Parser + Claude](SETUP_GUIDE.md#42-job-parser--mcp-server)
- **[Part 5 — Customizing](SETUP_GUIDE.md#part-5-customizing)** — [companies & buckets](SETUP_GUIDE.md#51-companies-and-buckets) · [title filters](SETUP_GUIDE.md#52-title-filters) · [location & multiple cities](SETUP_GUIDE.md#53-location-and-multiple-regions) · [experience range](SETUP_GUIDE.md#54-experience-range) · [schedule](SETUP_GUIDE.md#55-schedule-and-time-window)
- **[Part 6 — Operations](SETUP_GUIDE.md#part-6-operations)** — [updating](SETUP_GUIDE.md#62-updating-an-existing-instance) · [costs](SETUP_GUIDE.md#63-costs) · [optional CI/CD](SETUP_GUIDE.md#61-optional-github-actions-cicd)
- **[Troubleshooting](TROUBLESHOOTING.md)** — known problems and fixes

### The short version

```bash
# Cloud VM (Ubuntu 22.04): after Part 1's checklist, this one script does the server work
git clone https://github.com/Jatin17Solanki/linkedin_automation.git && cd linkedin_automation
sudo bash deploy/setup-aws.sh     # or deploy/setup-gcp.sh on GCP
# then open https://<VM_IP>.nip.io and connect your accounts (Part 3)

# Or locally, with Docker running:
docker compose up -d --build      # then open http://localhost:5678
```

## How the search is tuned

You don't have to touch any of this to get started — the defaults are Bengaluru, roles asking for up to 4 years, and ~50 pre-loaded companies. When you're ready:

- **Companies and buckets.** Each company in your Sheet's Config tab sits in one of four "buckets" that decide how it's searched (companies label the same level differently — "SDE II", "Level 3", plain "Software Engineer"). New company? Put it in Bucket 4. [Why buckets exist →](SETUP_GUIDE.md#51-companies-and-buckets)
- **Title filters.** Staff, principal, manager, QA, devops and similar are dropped automatically; "senior" is dropped only where it really means a step up. [Where and how to change →](SETUP_GUIDE.md#52-title-filters)
- **Location.** Bengaluru by default; any city or several at once, set in the Sheet. [Finding a city's code →](SETUP_GUIDE.md#53-location-and-multiple-regions)
- **Experience.** You give a bracket like "3 to 5 years"; a role is kept if its own range overlaps yours. Permissive on purpose: better one extra role to glance at than a good one silently missed. [Details →](SETUP_GUIDE.md#54-experience-range)
- **Schedule.** Eight runs a day by default. [Change the times →](SETUP_GUIDE.md#55-schedule-and-time-window)

## Claude / MCP server

`mcp-server/` is a small Node.js server that lets Claude call the Job Parser as a `parse-linkedin-job` tool. Setup: [Setup Guide, Part 4](SETUP_GUIDE.md#42-job-parser--mcp-server).

## What's in the repo

```
n8n_job_search_v1.json      # Job Search workflow (scheduled digest)
n8n_company_search_v1.json  # Company Search workflow (/search)
n8n_job_parser_v1.json      # Job Parser webhook
mcp-server/                 # MCP server for Claude
examples/google-sheet/      # bootstrap script + templates for your Google Sheet
Dockerfile, docker/         # image that auto-loads the 3 workflows on first start
deploy/                     # one-shot setup scripts for AWS/GCP, Docker Compose, Caddy (HTTPS)
SETUP_GUIDE.md              # the walkthrough
TROUBLESHOOTING.md          # known problems and fixes
CLAUDE.md                   # technical reference, written for AI coding assistants
```

## License

MIT.

---

<p align="center">
  <strong>Built by Jatin</strong><br>
  Questions, ideas, or something not working? Email me at
  <a href="mailto:jatin.dev.17@gmail.com">jatin.dev.17@gmail.com</a><br>
  <a href="https://github.com/Jatin17Solanki/linkedin_automation/issues">Open an issue</a> ·
  <a href="https://github.com/Jatin17Solanki">GitHub</a>
</p>
