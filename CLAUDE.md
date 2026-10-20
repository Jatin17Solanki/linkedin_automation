# CLAUDE.md — LinkedIn Job Search n8n Workflow Context

## Agent quickstart — read this first

This file is both the technical reference and the briefing for an AI assistant helping a person set up, run, debug or customise this project. If you are that assistant:

1. **Setting up for someone:** follow `SETUP_GUIDE.md` in its own order — Part 1 gather (checklist) → Part 2 run n8n → Part 3 connect → Part 4 optional workflows. Ask first: local or cloud (AWS is recommended)? Which workflows (Job Search is the core; Company Search is recommended and cloud-only)? Have them work through the Part 1 checklist *before* touching a server. Go one part at a time and confirm each step worked before the next.
2. **What you cannot do for them:** create cloud/Google/Telegram accounts, talk to @BotFather, click through OAuth consent, or operate the n8n web UI. Tell them exactly what to click and where each value goes. **Never ask them to paste secrets** (bot tokens, API keys, OAuth Client Secret) into the chat.
3. **Debugging:** ask for the actual failing data — the n8n execution output / error text, or `docker compose logs` — before naming a root cause, and reproduce with the real workflow code rather than only reading it. Past bugs here (duplicate node ids, a node reading the wrong input, a Sheets read fanning out) all looked like something else at first.
4. **Where things are:** `README.md` (human landing page), `SETUP_GUIDE.md` (walkthrough), `TROUBLESHOOTING.md` (known problems), `CONTRIBUTING.md` (rules for changes), `BACKLOG.md` (planned work, unverified claims, what will rot first — check it before proposing new work), this file (reference), `n8n_*.json` (the three workflows), `examples/google-sheet/` (bootstrap script + templates), `deploy/` (VM scripts), `mcp-server/`.
5. **Changing the workflows:** read "Editing workflow JSON — agent checklist" and "Title filters — agent instructions" below first. Logic is deliberately duplicated between the two main workflows, so edit both. `main` is branch-protected: work on a branch and open a PR.
6. Keep `README.md`, `SETUP_GUIDE.md` and this file consistent when behaviour changes. `README.md` is for humans — keep agent-level detail out of it.

## What This Is
An n8n automation workflow (`n8n_job_search_v1.json`) that searches LinkedIn's public job pages for target companies in **Bengaluru**, filters results by experience level, logs to Google Sheets, and sends Telegram notifications. Defaults target mid-level backend/full-stack roles (about 3.5 years' experience) in Bengaluru; the roles (title filters), location, experience range and companies are all configurable from the Sheet (see below).

## File Locations
- **Main workflow:** `n8n_job_search_v1.json` — scheduled job search with LLM resume matching (43 functional nodes + 5 sticky notes)
- **Company search:** `n8n_company_search_v1.json` — on-demand `/search` command with LLM resume matching (34 functional nodes + 4 sticky notes)
- **Job parser:** `n8n_job_parser_v1.json` — webhook API for parsing LinkedIn job pages (8 functional nodes + 1 sticky note)

## Architecture Overview

```
Schedule (8×/day — 7, 9:30, 11:30, 14, 16, 18, 20, 22 IST; 24h window)
  OR Manual Trigger (24h window)
  OR Webhook Trigger (?hours=N, custom window) ← local dev
  OR Telegram Trigger (/jobs N) ← production (needs HTTPS)
        → Parse Hours → Is Jobs Command? — anything that is not /jobs [hours] gets a usage reply (Send Usage Telegram) and STOPS; it must not start a run
    ↓
  → Read Config (Google Sheet "Config" tab — companies, plus optional per-company SearchTitles / ExtraExcludeWords)
  → Store Config (saves config to workflow static data)
  → Read Results (Google Sheet "Results" tab — for dedup)
  → Build Search URLs (Code node — groups companies with identical title filters, batches of ≤25 per search, Bengaluru location filter)
  → Loop Over URLs
    → Wait Between Searches (rate limit)
    → Fetch Search Page (HTTP GET to LinkedIn's guest search endpoint — one page of 10 per request)
    → Extract Links & Titles (HTML parse)
    → Filter & Accumulate Links (Code — exclude-word title filter + dedup + paging decision)
    → More Pages? (IF) — yes: Next Page URL → back to Wait Between Searches (max 30 pages / 300 results per search); no: next search
  → Output New Job Links
  → Loop Over Jobs
    → Wait Between Jobs (rate limit)
    → Skip If Dummy (IF node — skip dummy items from empty runs)
    → Fetch Job Detail (HTTP GET individual job page)
    → Parse Job Details (HTML parse — title, company, location, description)
    → Process & Filter Job (Code — experience extraction, tagging, skip if >4 yrs min)
    → Is Valid Job? (IF node)
      → YES: Append to Results sheet
      → NO: Skip, continue loop
  → Trigger Read (collapses loop output to single item)
  → Read Resume (Google Sheet "Resume" tab — candidate profile for LLM matching)
  → Prepare LLM Input (builds Gemini prompt with resume + job descriptions from staticData)
  → Call Gemini Flash (POST to Gemini 2.5 Flash API, continueOnFail)
  → Parse LLM Response (merges match scores into staticData, sorts by match %)
  → Read Unnotified (get jobs where Notified != TRUE)
  → Format Telegram (enriched with match % or plain fallback, splits long messages)
  → Has New Jobs? (IF node)
    → YES: Split Messages → Send Telegram → Mark Jobs Notified (with Score) → Update Notified Status (with Score)
    → NO: Send No Results Telegram ("no new openings found this run")
```

## Trigger Options

| Trigger | Time Window | How to Use | Requirements |
|---------|-------------|------------|--------------|
| Schedule | 24h (default) | Automatic at 7, 9:30, 11:30, 14, 16, 18, 20, 22 IST (8×/day) | Workflow must be **activated** (toggle) |
| Manual | 24h (default) | Click "Execute Workflow" in n8n UI | None |
| Webhook | Custom (default 12h) | `http://localhost:5678/webhook/job-search?hours=6` | Workflow must be **activated** |
| Telegram | Custom (default 12h) | Message bot: `/jobs 6` | **HTTPS required** — disabled locally, enable on cloud |

**Note:** The Telegram Trigger node is shipped **disabled**. Enable it after deploying to a cloud instance with HTTPS. On cloud, Telegram uses webhook push (zero CPU when idle), not polling.

## Title filters (what roles are searched)

Two Settings-tab keys decide the role, for **both** workflows, and two optional Config-tab columns override them per company. Defaults are software-engineering titles.

| Where | Key / column | Meaning | Blank |
|---|---|---|---|
| Settings | `search_titles` | Comma-separated titles; the workflow builds LinkedIn's `keywords` as `"a" OR "b" OR …` | built-in default (`software engineer, software developer, backend engineer, SDE, MTS, member of technical staff`) |
| Settings | `exclude_title_words` | Comma-separated words/phrases; a job card whose **title** contains one (whole word, case-insensitive, space = hyphen/no space) is dropped before its detail page is fetched | built-in default (staff, principal, lead, manager, director, ios, android, machine learning, data science, data scientist, QA, SDET, devops, SRE, site reliability, frontend, front end, intern, internship, test engineer, test automation, platform engineer, infra engineer, cloud engineer, security, mobile, embedded) |
| Config | `SearchTitles` | **Replaces** `search_titles` for that company | uses `search_titles` |
| Config | `ExtraExcludeWords` | **Added to** `exclude_title_words` for that company | only `exclude_title_words` |

Settings-only (no env var), like `notify_email`. Blank means default, never "no filter". The built-in defaults live in `Build Search URLs` / `Build Search URL` and must stay identical to `examples/google-sheet/settings_template.csv`.

**Grouping and batching (`Build Search URLs`):** companies whose effective titles and extra excludes are identical (compared case-insensitively, order-independent) form one group; each group is split into batches of `BATCH_SIZE = 25`; one LinkedIn search (URL item) per batch. Each URL item carries `searchLabel`, `targetTitles`, `excludeWords`, `companyCount` (and `configNote` when the Config tab still has a `Bucket` column but none of the new columns). `Filter & Accumulate Links` reads the exclude words from `$('Loop Over URLs')`, so they apply to every page of that search; `Next Page URL` passes the whole item through. Starter list with blank overrides → 4 searches (25/25/25/19).

**Why this replaced the four buckets (2026-09-27):** buckets 1–4 hardcoded tech-only search phrases in the Code nodes, so a non-software user had to edit JavaScript in two workflows. Measured live the same day: one search over all 94 companies at a 72h window hit the 300-result cap, while the same companies in batches of 25 returned 487 distinct jobs — batching also removes a silent-loss problem. LinkedIn matches a quoted phrase loosely and anywhere in the posting (a "software engineer" search also returns "Data Engineer", "Financial Model Engineer"), which is why the exclude list is required. The four old buckets map to override values listed in `SETUP_GUIDE.md` 5.2 ("Upgrading a Sheet that has a Bucket column"); bucket 3's `"Senior Member, Tech"` became `Senior Member Tech` (a comma can't live in a comma list; a live comparison found the same target roles).

**Tag (`PrimaryTag`):** `Process & Filter Job` / `Process Job` set it to the longest of the search's `targetTitles` that appears in the job title (same whole-word matching), else `Other` — `Other` means LinkedIn matched the phrase elsewhere in the posting.

**Known quirk (decision pending, BACKLOG #6):** default searches include "member of technical staff" but default excludes include `staff`, so "Member Technical Staff II"-style titles are found then dropped. Same as before the change.

## LinkedIn URL Construction

Each search (a batch of ≤25 companies sharing title filters) generates a URL like:
```
https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=<encoded_boolean_query>&f_C=<company_ids>&f_TPR=r<seconds>&location=India&geoId=102713980&f_PP=105214831&sortBy=DD&start=<n>
```

**Why the guest endpoint and paging (measured 2026-09-20):** the public `/jobs/search/` page returns at most 60 cards and cannot be paged by guests (`start=25` gets a login redirect, HTTP 303), so results beyond the newest 60 per search were silently never seen. The guest endpoint above returns a bare `<li>` list, **10 cards per request**, and pages with `start=0,10,20,…`; a short page is the last one. The workflows keep requesting pages while a page is full, up to `MAX_PAGES = 30` (300 results) per search, logging a `WARNING` (container logs only) if the cap is hit. Paging state (`searchStart`/`searchPages`) lives in static data and is reset by `Build Search URLs` / `Build Search URL` each run. The HTML node's selectors therefore have no `ul.jobs-search__results-list` prefix.

- `f_TPR=r<seconds>` = time window (e.g., `r86400` = 24 hours)
- `f_C` = comma-separated LinkedIn company IDs
- `geoId=102713980` = India (broad geo) — default, overridable via the Settings tab's `location_geo_id` or the `LOCATION_GEO_ID` env var
- `f_PP=105214831` = **Bengaluru, Karnataka** (precise location filter) — default, overridable via the Settings tab's `location_f_pp` or the `LOCATION_F_PP` env var; accepts a comma-separated list of place IDs for multi-city (OR-matched) — see `SETUP_GUIDE.md` §5.3 ("Location and multiple regions") for known place IDs
- Keywords use Boolean `OR`, built from the title list: `"SDE II" OR "SDE 2" OR ...`
- There is **no** `AND NOT` in the URL: exclusions happen *after* the fetch, on the job-card titles, in `Filter & Accumulate Links` / `Filter Links` (see "Title filters" above). A company with a blank `CompanyID` is skipped with a log line

## Filters

### Title Filter (in "Filter & Accumulate Links" node)
Drops a job card whose title contains any of the search's `excludeWords` (Settings `exclude_title_words` + the company's `ExtraExcludeWords`) as a whole word/phrase, case-insensitive, with a space in a phrase also matching a hyphen or no space. See "Title filters" above. (The old hardcoded regex never matched "data science/scientist", "test automation" or "internship", because `data.?scien` / `test.?auto` sat inside `\b…\b`; the new default list names them explicitly.)

### Location Filter (in "Process & Filter Job" node)
- Skips any job whose parsed location doesn't contain any of the `LOCATION_CITY_NAMES` substrings (default: "bengaluru", "bangalore", "karnataka"; case-insensitive), driven by `$env.LOCATION_CITY_NAMES` (comma-separated) with the default as fallback
- If LinkedIn returns an empty location field, the job passes through (avoids false negatives)
- Reason: LinkedIn's `f_PP` URL param alone is unreliable — non-Bangalore roles leak through

### Experience Filter (in "Process & Filter Job" node)
- Regex-based extraction from job description
- **Threshold:** `MAX_EXPERIENCE_YEARS`, driven by `$env.MAX_EXPERIENCE_YEARS` (default `4`) — skips roles where minimum experience exceeds the threshold
- Examples: "3-5 years" (minExp=3, valid), "4+ years" (minExp=4, valid), "5+ years" (minExp=5, filtered out)
- Patterns matched: "3+ years", "3-5 years", "minimum 3 years", "at least 3 years", etc.
- If experience can't be parsed, passes through as "Not specified" for manual review

### Job ID Extraction (in "Filter & Accumulate Links" node)
Regex: `/-(\d{8,})(?:\?|$)/` — extracts the numeric job ID from LinkedIn URLs like:
`https://in.linkedin.com/jobs/view/software-engineer-at-cleartrip-4370408479?position=1`

## Google Sheet Schema

**Config tab** (`gid=0`, input — user editable):
| Company | CompanyID | Active | SearchTitles (optional) | ExtraExcludeWords (optional) | Notes |

**Results tab** (`gid=812188810`, output — workflow writes here):
| JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status |

**Settings tab** (Key/Value, input — user editable, read live every run): a Google-Sheet-native override for the location/experience/match-threshold env vars, so they can be changed without a container restart. **Row 1 must be literally `Key` and `Value`** (exact spelling/case) — if your first data pair ends up in row 1 instead, n8n reads it as the header row and every setting silently falls back to its env var/default (see `TROUBLESHOOTING.md`; `Store Settings` logs a warning when this happens). Precedence for each: **Settings tab value (if non-blank) > matching env var > hardcoded default.** Read by `Read Settings` → `Store Settings` (populates `staticData.settings`), consumed in `Build Search URLs` (`location_geo_id`, `location_f_pp`, `search_titles`, `exclude_title_words`) and `Process & Filter Job` (`max_experience_years`, `min_experience_years`, `location_city_names`), and `Format Telegram` (`min_match_percent`, see below).

| Key | Maps to env var | Default if both blank |
|-----|------------------|------------------------|
| `location_geo_id` | `LOCATION_GEO_ID` | `102713980` (India) |
| `location_f_pp` | `LOCATION_F_PP` | `105214831` (Bengaluru) |
| `location_city_names` | `LOCATION_CITY_NAMES` | `bengaluru,bangalore,karnataka` |
| `max_experience_years` | `MAX_EXPERIENCE_YEARS` | `4` |
| `min_experience_years` | `MIN_EXPERIENCE_YEARS` | `0` |
| `min_match_percent` | `MIN_MATCH_PERCENT` | `0` (no suppression) |
| `notify_email` | *(none — Settings tab only)* | blank → Company Search email digest skipped |
| `search_titles` | *(none — Settings tab only)* | software-engineering titles (see "Title filters") |
| `exclude_title_words` | *(none — Settings tab only)* | staff/manager/QA/devops-type words (see "Title filters") |

`min_experience_years`/`max_experience_years` together describe the experience bracket you're targeting (e.g. "3 to 5 years"). A role matches if its own stated range overlaps this bracket at all, touching boundaries counted as a match — a "2-4 years" posting matches a `3-5` target, and so does an open-ended "5+ years" posting (no ceiling to compare against, so it always satisfies the upper bound). Deliberately permissive: implemented in `Process & Filter Job` as `jobMin <= MAX_EXPERIENCE_YEARS && jobMax >= MIN_EXPERIENCE_YEARS` (jobMax = `Infinity` for open-ended roles), biased toward false positives over dropping borderline roles. Defaults (`min=0`, `max=4`) reproduce the original single-ceiling behavior exactly. Unparseable job experience always passes through regardless of the range (see "Honest filtering" below).

`min_match_percent` hides jobs scoring below the threshold from the Telegram message only — it does **not** affect whether they're written to the Results sheet or marked `Notified`; suppressed jobs are still marked notified (via the full, unfiltered job list in `Format Telegram`'s `jobIds`) so they're never re-scored on a later run. Only applies when Gemini scoring succeeded — the plain-fallback format (LLM failed) never suppresses, since there's no score to filter on. **Also implemented in `n8n_company_search_v1.json`** (both its Telegram message and Gmail digest — Gmail additionally notes how many roles were hidden, since it has more room than Telegram's char limit) — the two workflows' Settings-tab handling stays in sync by design (the logic is deliberately duplicated in both workflows, not shared).

`notify_email` is Settings-only (no env var) and only used by the **Company Search** workflow: the recipient(s) of its email digest, comma-separated allowed. `Format Email` reads it and, if none are valid (blank / key missing / malformed), logs why and returns nothing so `Send Gmail` never runs — the Telegram results were already sent and are unaffected. Previously the address was hardcoded in `Send Gmail`'s `To` field; that field is now `={{ $json.sendTo }}` and an import/update drops any address typed there, so users upgrading must add the Settings row (a Settings tab from the current `bootstrap.gs` already has it, blank). The main workflow sends no email.

Sheet Document ID: `YOUR_GOOGLE_SHEET_DOCUMENT_ID` (find yours in the Google Sheets URL after `/d/`)

**Note:** The workflow references the sheet by Document ID, not by name. You can rename the Google Sheet freely without changing the JSON.

## Telegram Notification Format

**Send Telegram node** (main workflow) uses `parse_mode: HTML`; `Format Telegram`'s `safe()` HTML-escapes `&`, `<`, `>` in every dynamic field **including the tag**, which is user-typed text now (e.g. `FP&A analyst`) — an unescaped `&` makes Telegram reject the whole message ("can't parse entities"). Company Search's `Send Results Telegram` uses no parse mode and its `safe()` strips `_`/`*`. Tags use `(…)`, not `[…]`.

**When jobs are found (LLM enriched — sorted by match %):**
```
🔔 3 New Openings Found

1. 🟢 82% — Amazon — SDE II (3-5 yrs) (SDE II)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/123

2. 🟡 65% — Myntra — Software Engineer (3+ yrs) (software engineer)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/456

3. 🔴 38% — Cred — Backend Engineer, Payments (5+ yrs) (backend engineer)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/789
```
Color coding: 🟢 ≥70%, 🟡 50-69%, 🔴 <50%

**When jobs are found (LLM fallback — plain format):**
```
🔔 3 New Openings Found

1. Amazon — SDE II (3-5 yrs) (SDE II)
   📍 Bengaluru, India
   https://linkedin.com/jobs/view/123

⚠️ AI matching unavailable this run.
```

**When no jobs are found:**
```
✅ Job search ran successfully — no new openings found this run.
```

Messages exceeding Telegram's 4096 char limit are automatically split into multiple messages with `...contd` headers.

## Node Reference (43 functional nodes)

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Schedule Trigger | scheduleTrigger | Fires 8×/day: 7, 9:30, 11:30, 14, 16, 18, 20, 22 IST |
| 2 | Manual Trigger | manualTrigger | For ad-hoc runs from n8n UI |
| 3 | Telegram Trigger | telegramTrigger | Listens for `/jobs` commands (DISABLED — enable on cloud) |
| 4 | Webhook Trigger | webhook | Local dev trigger: `/webhook/job-search?hours=N` |
| 5 | Parse Hours | code | Parses hours from Telegram `/jobs N` command. **First ignores (returns no items) any message whose chat id != `$env.TELEGRAM_CHAT_ID`** (owner-only lock; off when the env var is empty) |
| 6 | Parse Webhook Hours | code | Parses hours from webhook query param |
| 7 | Read Config | googleSheets | Reads Config tab (companies + optional per-company title filters) |
| 8 | Store Config | code | Saves config to workflow static data, initializes processedJobs |
| 9 | Read Results | googleSheets | Reads Results tab for dedup |
| 10 | Build Search URLs | code | Groups companies by title filters, batches of ≤25, one LinkedIn search URL per batch |
| 11 | Loop Over URLs | splitInBatches | Iterates over search URLs |
| 12 | Wait Between Searches | wait | Rate limit between search page fetches |
| 13 | Fetch Search Page | httpRequest | HTTP GET LinkedIn search page |
| 14 | Extract Links & Titles | html | Parses job links, titles, companies from HTML |
| 15 | Filter & Accumulate Links | code | Exclude-word title filter + dedup + job ID extraction + paging decision |
| 16 | Output New Job Links | code | Outputs accumulated new job links |
| 17 | Loop Over Jobs | splitInBatches | Iterates over individual jobs |
| 18 | Wait Between Jobs | wait | Rate limit between job detail fetches |
| 19 | Skip If Dummy | if | Skips dummy items (empty run placeholder) |
| 20 | Fetch Job Detail | httpRequest | HTTP GET individual job page |
| 21 | Parse Job Details | html | Parses title, company, location, description |
| 22 | Process & Filter Job | code | Experience extraction, tagging, validation, accumulates descriptions for LLM |
| 23 | Is Valid Job? | if | Routes valid jobs to sheet, invalid back to loop |
| 24 | Append to Results | googleSheets | Writes valid job to Results tab |
| 25 | Trigger Read | code | Collapses loop output to single item (prevents multiplication) |
| 26 | Read Resume | googleSheets | Reads Resume tab (Key/Value pairs) for LLM matching |
| 27 | Prepare LLM Input | code | Builds Gemini prompt with resume + job descriptions |
| 28 | Call Gemini Flash | httpRequest | POST to Gemini 2.5 Flash API (60s timeout, continueOnFail) |
| 29 | Parse LLM Response | code | Validates & merges match scores into jobs, sorts by match % |
| 30 | Read Unnotified | googleSheets | Reads Results rows where Notified != TRUE |
| 31 | Format Telegram | code | Enriched (match %) or plain fallback, splits if too long |
| 32 | Has New Jobs? | if | Routes to send notification or "no results" message |
| 33 | Split Messages | code | Fans out message chunks for Telegram's 4096 char limit |
| 34 | Send Telegram | telegram | Sends job notification message(s) |
| 35 | Mark Jobs Notified | code | Collects job IDs + scores to mark as notified |
| 36 | Update Notified Status | googleSheets | Updates Notified=TRUE and Score in Results tab |
| 37 | Send No Results Telegram | telegram | Sends "no new openings" confirmation |
| 38 | Is Jobs Command? | if | Gate after Parse Hours: `/jobs [hours]` continues to Read Config; anything else goes to Send Usage Telegram (no run) |
| 39 | Send Usage Telegram | telegram | Replies with usage help to a message that is not a valid `/jobs` command (chat id comes from Parse Hours) |
| 40 | More Pages? | if | After Filter & Accumulate Links: page was full (and under the 30-page cap) → Next Page URL, else back to Loop Over URLs |
| 41 | Next Page URL | code | Builds the next page's request (same URL + `&start=`) and loops back into Wait Between Searches |
| 42 | Read Settings | googleSheets | Reads the Settings tab (Key/Value): location, experience range, match threshold. Sits between Store Config and Read Results |
| 43 | Store Settings | code | Parses the Settings rows into `staticData.settings` (logs a warning when row 1 is not the literal `Key`/`Value` header) |

## Setup Guide (for new users)

The human-facing walkthrough is `SETUP_GUIDE.md` (the README is the landing page: what it does, mockups, which setup to choose, an index). It is ordered so the user never has to stop mid-setup to fetch a key — **follow its order when guiding someone; don't improvise a different one:**

1. **Part 1 — gather first:** checklist (§1.1) → Telegram bot(s) (§1.2: one bot for Job Search, a *second* only for Company Search, because Telegram allows one webhook per bot) → Gemini key (§1.3) → Google Sheet via `bootstrap.gs` plus the resume→JSON prompt (§1.4) → Google OAuth client (§1.5) → decide settings (§1.6).
2. **Part 2 — run n8n:** local (§2A), AWS (§2B, recommended) or GCP (§2C). The setup scripts ask for exactly three things: n8n basic-auth username/password, Gemini key, Telegram chat ID.
3. **Part 3 — connect n8n:** Google Sheets + Telegram credentials, a worked example on the `Read Config` node, the other 6 Sheets nodes (each needs the credential **and** the Document re-selected, then the Sheet tab re-checked) and the Telegram nodes; on cloud enable the Telegram Trigger; test; activate.
4. **Parts 4-6:** optional workflows (Company Search §4.1, Job Parser + MCP §4.2), tuning (§5), operations/CI-CD/costs (§6).

Facts that must stay consistent with the guide (decided/verified 2026-09-20 — don't re-derive):
- `TELEGRAM_CHAT_ID` and `GEMINI_API_KEY` are **env-only**, deliberately not Settings-tab keys (secrets shouldn't live in a Sheet that may be shared). The chat ID is **not** typed into the Send Telegram nodes — the old instruction to do so was wrong.
- The Google OAuth consent screen must be **published** (In production): a Testing-mode app's sign-in expires after 7 days and the Sheets credential silently dies. Verification is not needed for personal use.
- Local runs can't do anything Telegram-webhook-driven: no `/jobs N`, no Company Search. Scheduled runs work only while the machine is on.
- Schedule: 8 cron rules in the `Schedule Trigger` node, timezone `Asia/Kolkata` from `GENERIC_TIMEZONE`/`TZ` in the compose file. (The old "7 AM / 7 PM" wording was stale.)
- New companies need only Company, CompanyID, Active; leave `SearchTitles`/`ExtraExcludeWords` blank. A company's LinkedIn ID comes from LinkedIn Jobs' Company filter (`f_C=` in the URL). **A user after a non-software role must change `search_titles` and `exclude_title_words` in the Settings tab** (SETUP_GUIDE §1.6 and §5.2) — ask about the target role during setup.
- **Both bots are owner-only.** A bot's `@username` is public, so `Parse Hours` and `Parse Search Command` return nothing (silently) for any chat other than `TELEGRAM_CHAT_ID`. Reply routing differs by design: the job bot's digest/no-results messages always go to `$env.TELEGRAM_CHAT_ID` (scheduled runs have no incoming message to answer), while Company Search replies to the chat that sent the command (now always the owner, thanks to the lock). Tell users that a wrong `TELEGRAM_CHAT_ID` looks like a bot that never answers; the execution log prints the id to use.
- README and SETUP_GUIDE show the user's real screenshots from `docs/images/` (`job_bot.jpeg`, `search_bot.jpeg`, `email.jpeg`). Two Telegram messages, not one format: the job-bot digest line is `N. icon pct% — Company — Title (exp) (Tag)`; the Company Search line omits the company (it is in the header). `/jobs N` is **hours** (default 12), `/search Company N` is **days** (default 7, 1-90); both need digits only.

### Customization (quick map)
- **Companies:** Config tab (§5.1). **Roles / title filters:** Settings tab `search_titles` / `exclude_title_words`, per-company Config columns (§5.2, and the agent section below).
- **Location, experience, match threshold:** Settings tab, env var as fallback (§5.3, §5.4, §5.6).
- **Schedule:** cron rules in the "Schedule Trigger" node (§5.5).
- **Cloud deployment:** enable "Telegram Trigger", optionally disable "Webhook Trigger".

### Title filters — agent instructions

If a user asks to change which roles/titles are searched or dropped, **it's a Sheet edit, not a code edit**:

- Their whole search: Settings tab `search_titles` / `exclude_title_words` (comma-separated plain phrases — no quotes, no OR/AND, no wildcards). For a non-software role, suggest **replacing** the exclude list, not appending: defaults like `manager`/`lead`/`security` drop legitimate titles in other fields.
- One company whose titles differ ("Amazon calls it SDE II"): that company's Config row, `SearchTitles` (replaces) and/or `ExtraExcludeWords` (adds). Tell them identical text shares a search; each different combination is one more LinkedIn search.
- Diagnose from the execution view: `Build Search URLs` output (one item per search: `searchLabel`, `targetTitles`, `excludeWords`), `Filter & Accumulate Links` output (`total`/`filtered`/`new` per page). Code-node `console.log` is **not** visible on a deployed instance (no `CODE_ENABLE_STDOUT`).

Only change code for the machinery: the built-in defaults (`DEFAULT_SEARCH_TITLES`, `DEFAULT_EXCLUDE_WORDS`, `BATCH_SIZE` in `Build Search URLs` / `Build Search URL`) and the matcher (`phrasePattern` in `Filter & Accumulate Links` / `Filter Links`, and the tag block in `Process & Filter Job` / `Process Job`). **Edit both workflows identically** (duplicated on purpose) and keep the defaults identical to `examples/google-sheet/settings_template.csv`. Then run the structural check below, and the offline suite if you have it (`local-harness/2026-09-title-filters/offline_tests.js`, untracked).

### Editing workflow JSON — agent checklist

Every "validated" check used earlier in this project (`JSON.parse`, `node --check`) is blind to structural mistakes, and one shipped anyway: `Read Settings` and `Send Gmail` in `n8n_company_search_v1.json` shared a node `id`, so n8n's editor opened the wrong node (fixed in PR #32). When you add, duplicate or edit nodes in any `n8n_*.json`:

- **Node `id`s must be unique within the file, and so must node `name`s** (connections reference nodes by *name*). Never copy an id from another node — grep the file for an unused one.
- **Every connection endpoint must match an existing node name.**
- **A node runs once per input item — and a Sheets read emits one item per ROW.** Anything wired after a loop's `done` output (one item per iteration) or directly after a multi-row Sheets read (e.g. `Read Config`, ~50 rows) fans out into that many runs; for Google Sheets (default quota 60 read requests/min/user) that is a 429 waiting to happen. Collapse first (a Code node returning one item — the main workflow's `Store Config` / `Trigger Read`) or set the node's `executeOnce`. Company Search's `Read Settings` (after `Read Config`) and `Read Resume` (after the job loop) shipped without either until PR #32.
- **Inserting a node into the middle of an existing chain? Re-check every downstream consumer of `$input` — its input just changed.** `Lookup Company` silently stopped finding any company when PR #25 put `Read Settings`/`Store Settings` in front of it (it read `$input`, which became Store Settings' status item). Prefer `$('Node Name')` for data that isn't the immediate predecessor's output, and test the chain with the real nodes wired as the graph says, not each node against hand-fed input.
- Edit as **text** and keep the file's CRLF endings — re-serializing with `JSON.stringify` reformats the whole file and buries the real diff.
- Keep the sanitized placeholders (`YOUR_GOOGLE_SHEET_DOCUMENT_ID`, `CONFIGURE_ME`); never commit a live n8n export as-is.
- Test data layouts produced by `bootstrap.gs` by simulating n8n's read (row 1 = column names), not just the parser that builds them.
- Before committing, run `node scripts/check-secrets.js --staged` (catches leaked tokens and any real credential/spreadsheet/chat id in the shipped workflows).
- After editing, run:
```bash
node -e "for (const f of ['n8n_job_search_v1.json','n8n_company_search_v1.json','n8n_job_parser_v1.json']) { const wf=JSON.parse(require('fs').readFileSync(f,'utf8')); const ids=wf.nodes.map(n=>n.id), names=wf.nodes.map(n=>n.name), nm=new Set(names); const dangling=Object.entries(wf.connections).flatMap(([s,c])=>[s,...(c.main||[]).flat().map(o=>o.node)]).filter(x=>!nm.has(x)); console.log(f,'| unique ids:',new Set(ids).size===ids.length,'| unique names:',nm.size===names.length,'| dangling connections:',dangling.length); }"
```

## Design Principles
- Config-driven: companies, roles (title filters), location and experience read from the Google Sheet, not hardcoded
- Location-filtered: Hardcoded to Bengaluru via LinkedIn's f_PP parameter
- LLM-enhanced: Gemini Flash scores each job against resume; enriched Telegram with match % and color coding; Score persisted to sheet. Graceful fallback to plain format on API failure.
- Dedup: By JobID against Results sheet before fetching job details
- Rate limiting: Wait nodes between fetches to avoid LinkedIn throttling
- Message splitting: Telegram messages auto-split at 4096 char limit
- Honest filtering: Never fabricate matches. If experience can't be parsed, pass through as "Not specified"

## Production Deployment (GCP e2-micro or AWS EC2)

### Architecture
```
Internet → Caddy (auto-HTTPS via nip.io, :443) → n8n (:5678) → SQLite (Docker volume)
```
- VM: GCP e2-micro (free indefinitely, but only once the account is upgraded out of its 90-day/$300 Free Trial into standard billing — staying in trial mode means the VM gets suspended when the trial lapses, regardless of the Always Free quota; see `SETUP_GUIDE.md` §2C) or AWS EC2 `t3.micro` (accounts created on/after 2025-07-15 get a 6-month Free plan with up to $200 credits; older accounts get the 12-month free tier; hourly billing after — `t2.micro` is only free-tier eligible on older accounts), Ubuntu 22.04
- Domain: `<VM_IP>.nip.io` (free, no DNS registration)
- HTTPS: Let's Encrypt via Caddy (automatic)

### Deployment Files
| File | Purpose |
|------|---------|
| `Dockerfile` | Thin image on `n8nio/n8n:1.123.25` that auto-imports the 3 workflow JSONs on first start |
| `docker/import-entrypoint.sh` | Runs `n8n import:workflow` for each bundled JSON (marker-gated, first start only), then hands off to the base image's entrypoint |
| `deploy/docker-compose.prod.yml` | Production compose with n8n (pulls the published GHCR image by default) + Caddy |
| `deploy/Caddyfile` | Caddy reverse proxy config |
| `deploy/setup-common.sh` | Shared provider-agnostic setup logic (Docker install, volumes, swapfile, `.env`, firewall, compose up) sourced by `setup-gcp.sh`/`setup-aws.sh` |
| `deploy/setup-gcp.sh` | One-time GCP VM setup — GCP IP autodetection + the shared logic above |
| `deploy/setup-aws.sh` | One-time AWS EC2 VM setup — EC2 IMDSv2 IP autodetection + the shared logic above |
| `deploy/import-workflow.sh` | Import/update workflow via n8n REST API; matches the target workflow by its `name` field (not a hardcoded substring), so the same script works for all 3 workflow JSONs. Stops with a specific error on connection/auth/list/merge failures and never creates a workflow unless `CREATE_IF_MISSING=true` (an earlier version hid the listing error and fell through to creating a duplicate) |
| `deploy/merge-workflow.py` | Used by import-workflow.sh: merges the live instance's per-node wiring (credentials, Sheets documentId/sheetName, disabled, webhookId) into the shipped JSON so an update does not reset it; new nodes reuse an existing credential of the same kind. `DRY_RUN=true` / `PRESERVE_WIRING=false` on the import script. Tested against a mock n8n API only |
| `.github/workflows/deploy.yml` | CI/CD — OPTIONAL, manual-only (`workflow_dispatch`): pushes all 3 workflow JSONs to a VM; only useful to fork maintainers (secrets are still named `GCP_*` for historical reasons, but the target VM can be on either cloud — see SETUP_GUIDE.md's AWS Step 4) |
| `.github/workflows/docker-publish.yml` | CI/CD — builds and publishes the Docker image to GHCR on push to main / version tags |

### Before either VM setup: gather these first
The setup script prompts for these interactively (Step 0 below), so have them ready before creating the VM, not mid-script:
- **Gemini API key** — free, [aistudio.google.com/apikey](https://aistudio.google.com/apikey), no billing account needed
- **Telegram chat ID** — message `@userinfobot` on Telegram, it replies with your numeric user ID
- **Telegram bot token** — `@BotFather` → `/newbot` (needed later, for the n8n credential, not the script) — also message your new bot once (e.g. `/start`) now, since bots can't message a user who hasn't initiated contact first

### GCP VM Setup
0. Have the 3 values above ready
1. Create e2-micro VM (Ubuntu 22.04, us-central1-a) with HTTP/HTTPS firewall enabled — **and upgrade the account out of Free Trial mode** (Billing → Upgrade) if you want the VM to keep running past 90 days, see the Architecture note above
2. SSH in, clone the repo, run `sudo bash deploy/setup-gcp.sh`
3. The script prompts in order: n8n basic-auth username/password (**tell the user to save these somewhere durable — not shown again, no recovery flow**), then Gemini API key, then Telegram chat ID (both of the latter two are echoed back with a y/n confirmation before being accepted; leave either blank to skip and set later — see "Editing env vars after deploy" below)
4. Open `https://<VM_IP>.nip.io`, log in with the basic-auth credentials from step 3, set up Google Sheets + Telegram credentials
5. Import workflow, enable Telegram Trigger node, activate workflow
6. Generate n8n API key (Settings > API) for CI/CD

### AWS EC2 VM Setup
0. Have the 3 values above ready. **If this is a brand-new AWS account**, check first whether it's under AWS's new-account verification hold (console shows "pending verification... may take up to 2 days") — this can block EC2 instance launches entirely and has nothing to do with this project; there's no status page for it beyond opening a free Support Case if it drags past 48h
1. Create a `t3.micro` VM (Ubuntu 22.04; `t2.micro` isn't free-tier eligible on accounts created since 2025-07-15) with a Security Group allowing inbound 22/80/443 — **AWS gates traffic at the Security Group before it ever reaches the VM's own iptables rules**, unlike GCP; both must allow 80/443 or nothing gets through
2. SSH in as `ubuntu` (not your AWS account name), clone the repo, run `sudo bash deploy/setup-aws.sh`
3. Same interactive prompt order/behavior as GCP step 3 above (basic auth → Gemini key → Telegram chat ID)
4. Open `https://<VM_IP>.nip.io`, log in, set up Google Sheets + Telegram credentials — identical to the GCP flow from here
5. Import workflow, enable Telegram Trigger node, activate workflow
6. Generate n8n API key (Settings > API) for CI/CD

Full walkthrough (Security Group config, Elastic IP, free-tier time limits, key-pair setup): `SETUP_GUIDE.md` §2B.

### Editing env vars after deploy
`setup-gcp.sh`/`setup-aws.sh` only prompt once, when first creating `/opt/n8n/.env` (**not** the repo checkout's `deploy/.env` — that's only ever a template, never read by the running stack). Re-running the script later never re-prompts or overwrites existing values, only refreshes `VM_IP`. To change `GEMINI_API_KEY`, `TELEGRAM_CHAT_ID`, or anything else in the file (rotate a key, fix a typo, add a value that was left blank at setup):
```bash
sudo nano /opt/n8n/.env      # edit the value
cd /opt/n8n && sudo docker compose up -d   # apply — a plain `restart` does NOT re-read .env
```
Verify what's actually set: `sudo docker compose exec n8n printenv | grep -E "GEMINI_API_KEY|TELEGRAM_CHAT_ID"`.

### VM Swap Configuration
The e2-micro/t2.micro/t3.micro class of VM has only 1GB RAM. Without swap, the VM freezes completely when n8n's workflow run exhausts memory. `deploy/setup-gcp.sh`/`deploy/setup-aws.sh` (via `setup-common.sh`'s `setup_swapfile`) does this automatically — creates a 2GB swapfile and sets `vm.swappiness=10`, skipped if swap is already active, or if invoked with `LOW_MEMORY=false` on a VM with more RAM. Manual steps below are only needed on a VM whose setup script predates this automation:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

This adds a 2GB swapfile on the persistent disk (free tier) and sets swappiness=10 so the kernel only swaps under real memory pressure. Combined with the `mem_limit`/`memswap_limit` (defaults `600m`/`800m`, overridable via `N8N_MEM_LIMIT`/`N8N_MEMSWAP_LIMIT` in `deploy/.env`) on the n8n container in `docker-compose.prod.yml`, this ensures a bad workflow run degrades gracefully (container OOM-kills and restarts) rather than freezing the whole VM.

### GitHub Actions CI/CD
Optional and **manual-only** (Actions tab → Run workflow; it used to fire on every push to `main` and failed for anyone without the VM secrets). Deploys all 3 workflow JSONs (`import-workflow.sh` matches each by its own `name` field, so this is a single loop, not per-file special-casing).

**Required GitHub Secrets** (names are `GCP_*` for historical reasons — set them the same way regardless of which cloud actually hosts the VM, AWS included):
| Secret | Value |
|--------|-------|
| `GCP_VM_IP` | VM external IP address (GCP or AWS) |
| `GCP_SSH_PRIVATE_KEY` | SSH private key for the VM |
| `GCP_SSH_USER` | SSH username — your Gmail username on GCP, `ubuntu` on AWS EC2 |
| `N8N_API_KEY` | n8n API key from Settings > API |

### Enabling Telegram Trigger on Cloud
1. In n8n UI, enable the "Telegram Trigger" node (right-click > Enable)
2. Optionally disable the "Webhook Trigger" node (not needed on cloud)
3. Save and activate the workflow — Telegram will auto-register its webhook with n8n's HTTPS URL

### Docker Operations Reference

All commands run from `~/linkedin_automation/deploy/` on the VM.

**Deploy / upgrade** (handles stop → remove → pull → start automatically):
```bash
docker compose -f docker-compose.prod.yml pull      # pull new image (if version changed)
docker compose -f docker-compose.prod.yml up -d     # recreate containers with new config/image
```
`up -d` detects changes in the image or environment and restarts only what changed. You do not need to stop manually first.

**Stop** (containers stop, volumes and data are untouched):
```bash
docker compose -f docker-compose.prod.yml stop
```

**Start** (after a stop):
```bash
docker compose -f docker-compose.prod.yml start
```

**Restart** (stop + start in one command — useful after a config tweak):
```bash
docker compose -f docker-compose.prod.yml restart
```

**Tear down completely** (stops and removes containers + network — data volumes are NOT deleted):
```bash
docker compose -f docker-compose.prod.yml down
```

**Tear down AND delete all data** (irreversible — wipes SQLite, credentials, workflows):
```bash
docker compose -f docker-compose.prod.yml down -v
```

**View logs** (live):
```bash
docker logs n8n-job-search -f
docker logs caddy-proxy -f
```

**Check running containers:**
```bash
docker ps
```

**Data persistence:** Everything (workflows, credentials, executions, login) is stored in the `n8n_n8n_data` Docker volume on the VM's disk. Swapping the image version, restarting, or running `down` (without `-v`) never touches this volume.

## On-Demand Company Search Workflow (`/search`)

A separate, stateless workflow (`n8n_company_search_v1.json`) for searching a specific company's openings on demand. Uses a **separate Telegram bot** (Telegram only supports one webhook per bot) and the same Config sheet (read-only), but does not write to Results or dedup against previous runs.

### Command Format
```
/search CompanyName [Days]
```
- `/search Oracle 30` — Oracle jobs from last 30 days
- `/search Google` — Google jobs, default 7 days
- `/search clear 14` — partial match (ClearTrip, ClearTax, etc.)
- Days clamped to 1-90 range

### Key Differences from Main Workflow
| Feature | Main (`/jobs`) | Company Search (`/search`) |
|---------|---------------|---------------------------|
| Scope | Only companies with `Active=TRUE` | Any company in Config, partial match — `Active` is **not** checked (an on-demand, deliberate lookup isn't gated by the flag that controls passive/scheduled inclusion) |
| Time unit | Hours | Days (default 7) |
| Dedup | Against Results sheet | Within-run only (no sheet dedup) |
| Title filters | Settings `search_titles`/`exclude_title_words` + Config per-company columns | Same (same Settings keys and columns, same matcher) |
| Experience filter | Same (Settings tab / env var, range-overlap match) | Same |
| Location/match-threshold Settings | Same (Settings tab / env var) | Same |
| Email recipient | n/a (sends no email) | Settings tab `notify_email` (Settings-only; blank → email skipped) |
| Sheet writes | Appends to Results | None (stateless) |
| Notification tracking | Marks Notified=TRUE | None |
| LLM matching | Gemini Flash resume matching (match % in Telegram, Score in sheet) | Gemini Flash resume matching (match %, summary, gaps) + Gmail |
| Email notification | None | Gmail digest with detailed match analysis, to the Settings tab's `notify_email` (only when the LLM succeeded **and** `notify_email` is set) |

### Architecture
```
Telegram Trigger (/search)
  → Parse Search Command (company + days)
  → Read Config (Google Sheet)
  → Read Settings → Store Settings (location/experience-range/match-threshold)
  → Lookup Company (case-insensitive partial match, regardless of Active status)
  → Company Found?
    ├─ NO → Send Error Telegram
    └─ YES → Build Search URL → Loop Over URLs
      → Wait 3s → Fetch → Extract → Filter → More Pages? (yes: Next Page URL → Wait 3s; no: loop back)
    → Output Job Links → Has Links?
      ├─ NO → Send No Results Telegram
      └─ YES → Loop Over Jobs
        → Wait 5s → Fetch Detail → Parse → Process Job (tag + save description) → loop back
      → Read Resume → Prepare LLM Input → Call Gemini Flash → Parse LLM Response
      → Format Telegram (enriched with match % if LLM succeeded, plain fallback if failed)
      → Split Messages → Send Results Telegram
      → LLM Succeeded?
        ├─ YES → Format Email → Send Gmail (detailed with summary + gaps)
        └─ NO → (end, no email)
```

### Node Reference (34 functional nodes + 4 sticky notes)

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Telegram Trigger | telegramTrigger | Listens for `/search` commands |
| 2 | Parse Search Command | code | Extracts company name + days (default 7, clamped 1-90). **First ignores any message whose chat id != `$env.TELEGRAM_CHAT_ID`** (owner-only lock, same as Parse Hours) |
| 3 | Read Config | googleSheets | Reads Config tab (same sheet as main workflow) |
| 4 | Read Settings | googleSheets | Reads Settings tab (location/experience-range/match-threshold, plus `notify_email`), same pattern as main workflow. **Execute Once is on**: its input is `Read Config`'s ~50 rows (one item per Config row) and a Sheets node runs once per input item, so without it every `/search` made ~50 reads of this tab (Sheets 429). |
| 5 | Store Settings | code | Parses Settings rows into `staticData.settings` |
| 6 | Lookup Company | code | Case-insensitive partial match against **all** companies in Config — `Active` is not checked (see Key Differences above). Reads the Config rows from **`$('Read Config')`, not `$input`** — its input is `Store Settings`' single status item, so reading `$input` made every lookup "not found" (bug from PR #25, fixed in #32) |
| 7 | Company Found? | if | Routes found/not-found |
| 8 | Send Error Telegram | telegram | "Company not found" or "Invalid command" error |
| 9 | Build Search URL | code | Groups matched companies by title filters, batches of ≤25, one URL per batch |
| 10 | Loop Over URLs | splitInBatches | One iteration per search (partial matches can span several) |
| 11 | Wait Between Searches | wait | 3s rate limit |
| 12 | Fetch Search Page | httpRequest | LinkedIn search page, 30s timeout |
| 13 | Extract Links & Titles | html | Same CSS selectors as main workflow |
| 14 | Filter Links | code | Exclude-word title filter + job ID extraction + paging decision, no dedup |
| 15 | Output Job Links | code | Fans out accumulated links or signals empty |
| 16 | Has Links? | if | Routes to job processing or no-results message |
| 17 | Send No Results Telegram | telegram | "No openings found in Bengaluru" |
| 18 | Loop Over Jobs | splitInBatches | Iterates job detail fetches |
| 19 | Wait Between Jobs | wait | 5s rate limit |
| 20 | Fetch Job Detail | httpRequest | Individual job page, 30s timeout |
| 21 | Parse Job Details | html | Same CSS selectors as main workflow |
| 22 | Process Job | code | Experience-range extraction + tagging + saves description for LLM |
| 23 | Format Telegram | code | Enriched format (match %, colors, `min_match_percent` suppression) or plain fallback |
| 24 | Split Messages | code | Fans out message chunks |
| 25 | Send Results Telegram | telegram | Sends result message(s) |
| 26 | Read Resume | googleSheets | Reads "Resume" tab (Key/Value pairs) from same sheet. **Execute Once is on**: `Loop Over Jobs`'s `done` output emits one item per job and feeds this node directly, so without it the tab was read once per job found (a burst of Sheets reads -> 429 "Read requests per minute per user"). The main workflow avoids the same problem with its `Trigger Read` collapse node |
| 27 | Prepare LLM Input | code | Builds Gemini prompt with resume + job descriptions |
| 28 | Call Gemini Flash | httpRequest | POST to Gemini 2.5 Flash API (60s timeout, continueOnFail) |
| 29 | Parse LLM Response | code | Validates & merges match scores into jobs, sorts by match % |
| 30 | LLM Succeeded? | if | Routes: LLM worked → email, LLM failed → end |
| 31 | Format Email | code | Builds detailed email with summary, matches, gaps per job; also applies `min_match_percent`; reads `notify_email` and returns nothing (skipping Send Gmail) if none valid, else passes `sendTo` downstream |
| 32 | Send Gmail | gmail | Sends detailed results email to `sendTo` from Format Email (= Settings tab `notify_email`); `To` is an expression, not a hardcoded address |
| 33 | More Pages? | if | After Filter Links: page was full (and under the 30-page cap) → Next Page URL, else back to Loop Over URLs |
| 34 | Next Page URL | code | Builds the next page's request (same URL + `&start=`) and loops back into Wait Between Searches |

### Telegram Message Formats

**Results found (LLM enriched — sorted by match %):**
```
🔍 Jobs at Oracle (last 30 days) — 5 openings

1. 🟢 82% — Software Engineer III (3-5 yrs) (software engineer III)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/123

2. 🟡 65% — Backend Engineer (3+ yrs) (backend engineer)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/456

3. 🔴 38% — Business Intelligence Engineer (5+ yrs) (Other)
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/789
```
Color coding: 🟢 ≥70%, 🟡 50-69%, 🔴 <50%

**Results found (LLM fallback — plain format):**
```
🔍 Jobs at Oracle (last 30 days)

Found 5 openings in Bengaluru:

1. Oracle — Software Engineer III (3-5 yrs) (software engineer III)
   📍 Bengaluru, India
   https://linkedin.com/jobs/view/123

⚠️ AI matching unavailable this run.
```

**Gmail (detailed — sent only when LLM succeeds):**
Subject: `Oracle — 5 matches found`
Body: Material Design HTML email with card-based layout — each job as an elevated card with clickable title link, color-coded match badge (green/yellow/red), one-line summary, blue chips for key matches, grey chips for key gaps. Gmail-safe inline styles only (no `<style>` blocks or `@media` queries).

**No results:** `🔍 Jobs at Oracle (last 30 days) — No openings found in Bengaluru for this time period.`

**Company not found:** `Company 'RandomCorp' not found in config. Add it to the Config sheet with its LinkedIn Company ID to enable search.`

**Invalid command:** Usage examples with `/search CompanyName [Days]` format.

### Resume Tab (Google Sheet)

New "Resume" tab in the same Google Sheet — two-column Key/Value layout:

| Key | Value |
|-----|-------|
| name | Your Name |
| title | Your Title |
| years_experience | N |
| target_roles | Target Role 1, Target Role 2, ... |
| skills_languages | Language 1, Language 2, ... |
| skills_frameworks | Framework 1, Framework 2, ... |
| skills_databases | DB 1, DB 2, ... |
| skills_cloud | Cloud/DevOps tools... |
| skills_other | Other skills... |
| experience_summary | (free text — key roles, achievements, companies) |
| education | Your degree, institution, year |
| highlights | Key achievement 1, Key achievement 2, ... |

**Row 1 must be the literal `Key` / `Value` header** — n8n's Google Sheets node treats row 1 as column names. `bootstrap.gs` writes it on both paths (placeholder CSV, and `RESUME_JSON`); the `RESUME_JSON` path did **not** until PR #30 — it wrote the first pair (`name` + the user's name) into row 1, so n8n read those as the headers and every read saw no Key/Value columns even though the tab looked fully populated (`Prepare LLM Input` then skipped matching). `Prepare LLM Input` needs at least one non-blank value (it no longer requires a `name` row) and matches `Key`/`Value` case-insensitively. When it skips, its output says why: `resume_missing_key_column` (with `columnsSeen` = what n8n read as headers; your own data appearing there means the header row is missing), `resume_all_values_blank`, or `no_jobs`. `Read Resume` has Always Output Data on, so an empty tab degrades to the plain format instead of silently stopping the run. See `TROUBLESHOOTING.md`.

### LLM Matching (Gemini Flash)

- API: `POST generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`
- API key hardcoded in node URL (env var via `$env.GEMINI_API_KEY` requires `N8N_EXTERNAL_ALLOWED_ENVIRONMENT_VARIABLES` — configured but may need manual setup)
- `responseMimeType: "application/json"` forces valid JSON output
- `thinkingBudget: 0` to disable chain-of-thought (Gemini 2.5 Flash thinking tokens eat into output budget)
- `maxOutputTokens: 65536` (model max)
- `temperature: 0.1` for consistent scoring
- Scoring: skills overlap (40%), experience fit (30%), domain relevance (20%), seniority alignment (10%)
- Job descriptions truncated to 3000 chars each to stay within token budget
- If LLM fails (rate limit, timeout, parse error): falls back to plain Telegram format, skips email

### Setup
1. Import `n8n_company_search_v1.json` into n8n (separate workflow from the main one)
2. **Telegram bot:** Create a **separate** bot via @BotFather (Telegram only supports one webhook per bot). Create a new Telegram Bot credential in n8n for this workflow.
3. Connect Google Sheets credential (same as main workflow) — **and repoint the Document field** on all 3 Sheets nodes (`Read Config`, `Read Settings`, `Read Resume`) from the placeholder `YOUR_GOOGLE_SHEET_DOCUMENT_ID` to the user's real Sheet; attaching the credential alone doesn't do this
4. **Resume tab:** Create a "Resume" tab in the Google Sheet with Key/Value columns (referenced by name, not GID), populate with your profile
5. **Gemini API key:** Get a free key from https://aistudio.google.com/apikey, add `GEMINI_API_KEY` to Docker compose environment, restart
6. **Gmail:** Create Gmail OAuth2 credential in n8n (enable Gmail API + `gmail.send` scope in GCP console) and attach it to `Send Gmail`. Then put the recipient in the **Settings tab**, not the node: row `notify_email` (comma-separated OK). `Send Gmail`'s `To` is `={{ $json.sendTo }}`, so nothing is typed into it. Blank/invalid → email skipped, Telegram still works. If the user's Settings tab predates this key, they add the row by hand (Key in A, Value in B; row 1 stays `Key`/`Value`)
7. Activate the workflow (requires HTTPS for Telegram webhook, so cloud only — its sole trigger is the Telegram Trigger, which is **not** shipped disabled here, unlike the main workflow's; activating is what registers the webhook, there is nothing to enable)

**Telegram bot setup:** Each workflow needs its own Telegram bot. The `/jobs` workflow uses one bot, the `/search` workflow uses another. Both bots can message the same chat (same `chatId`).

Full human-facing walkthrough: `SETUP_GUIDE.md` §4.1.

## Job Parser Webhook (`/parse-job`)

A stateless webhook that accepts a LinkedIn job URL and returns structured JSON with the parsed job details. Designed as an MCP tool backend for Claude.ai.

### Endpoint
```
POST https://<host>/webhook/parse-job
Body: {"url": "https://linkedin.com/jobs/view/4370408479"}
```

### Response (success)
```json
{
  "success": true,
  "job_id": "4370408479",
  "title": "Software Engineer II",
  "company": "Amazon",
  "location": "Bengaluru, India",
  "job_description": "Full text of the job description...",
  "apply_url": "https://company.com/careers/...",
  "experience": "3-5 years",
  "seniority_level": "Mid-Senior level",
  "criteria": ["Full-time", "Mid-Senior level", "Information Technology"],
  "source_url": "https://www.linkedin.com/jobs/view/4370408479"
}
```

### Response (error)
```json
{
  "success": false,
  "error": "Failed to fetch or parse job page.",
  "job_id": "4370408479",
  "source_url": "https://www.linkedin.com/jobs/view/4370408479"
}
```

### Architecture
```
Webhook (POST /parse-job, responseMode: responseNode)
  → Parse URL (Code — validate LinkedIn URL, extract job ID)
  → Valid URL? (IF)
    ├─ YES → Fetch Page (HTTP GET, 30s timeout, continueOnFail)
    │        → Parse HTML (same CSS selectors as main workflow + apply link)
    │        → Build Response (Code — clean text, extract apply URL, format JSON)
    │        → Respond Success (respondToWebhook)
    └─ NO → Respond Error (respondToWebhook)
```

### Node Reference (8 functional nodes + 1 sticky note)

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Webhook | webhook | POST /parse-job, waits for Respond node |
| 2 | Parse URL | code | Validates LinkedIn URL, extracts job ID |
| 3 | Valid URL? | if | Routes valid/invalid URLs |
| 4 | Fetch Page | httpRequest | HTTP GET LinkedIn job page, 30s timeout |
| 5 | Parse HTML | html | Extracts title, company, location, description, criteria, apply link |
| 6 | Build Response | code | Cleans text, extracts apply URL, formats structured JSON |
| 7 | Respond Success | respondToWebhook | Returns parsed job data |
| 8 | Respond Error | respondToWebhook | Returns error JSON for invalid URLs |

### Setup
1. Import `n8n_job_parser_v1.json` into n8n
2. Activate the workflow (webhook requires activation)
3. No credentials needed — uses public LinkedIn pages only
4. Test: `curl -X POST https://<host>/webhook/parse-job -H "Content-Type: application/json" -d '{"url": "https://linkedin.com/jobs/view/12345"}'`

### MCP Server (`mcp-server/`)

A lightweight Node.js MCP server that exposes the job parser webhook as a tool for Claude.ai (or any MCP-compatible client).

**Files:**
| File | Purpose |
|------|---------|
| `mcp-server/index.js` | MCP server — registers `parse-linkedin-job` tool, calls the n8n webhook |
| `mcp-server/package.json` | Dependencies (`@modelcontextprotocol/sdk`) |

**Tool:** `parse-linkedin-job`
- **Input:** `url` (string) — LinkedIn job URL
- **Output:** Formatted text with title, company, location, experience, seniority, apply URL, and full job description
- **Backend:** POST to `https://<VM_IP>.nip.io/webhook/parse-job`

**Claude Desktop config** (`claude_desktop_config.json`) — **the `env` block is required**, `mcp-server/index.js` reads `MCP_WEBHOOK_URL` from `process.env` at startup and exits immediately if it's unset:
```json
{
  "mcpServers": {
    "linkedin-job-parser": {
      "command": "node",
      "args": ["<path-to>/mcp-server/index.js"],
      "env": {
        "MCP_WEBHOOK_URL": "https://<VM_IP>.nip.io/webhook/parse-job"
      }
    }
  }
}
```

**Setup:**
1. `cd mcp-server && npm install`
2. Import + **activate** the `LinkedIn Job Parser` workflow in n8n first (plain webhook, no HTTPS/cloud required to test — works against a local instance too, `http://localhost:5678/webhook/parse-job`)
3. Add the config above to Claude Desktop settings (Developer > Edit Config), with `MCP_WEBHOOK_URL` pointing at that instance's real `/webhook/parse-job` URL
4. Restart Claude Desktop — the `parse-linkedin-job` tool appears automatically

Full human-facing walkthrough: `SETUP_GUIDE.md` §4.2.

## V2 Roadmap
- Auto resume customization
