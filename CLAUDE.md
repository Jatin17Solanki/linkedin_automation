# CLAUDE.md — LinkedIn Job Search n8n Workflow Context

## What This Is
An n8n automation workflow (`n8n_job_search_v1.json`) that searches LinkedIn's public job pages for target companies in **Bengaluru**, filters results by experience level, logs to Google Sheets, and sends Telegram notifications. Built for Jatin's job search targeting mid-level backend/full-stack roles (3.5 years experience).

## File Locations
- **Main workflow:** `n8n_job_search_v1.json` — scheduled job search with LLM resume matching (37 functional nodes + 5 sticky notes)
- **Company search:** `n8n_company_search_v1.json` — on-demand `/search` command with LLM resume matching (30 functional nodes + 4 sticky notes)

## Architecture Overview

```
Schedule (7AM/7PM, 24h window)
  OR Manual Trigger (24h window)
  OR Webhook Trigger (?hours=N, custom window) ← local dev
  OR Telegram Trigger (/jobs N) ← production (needs HTTPS)
    ↓
  → Read Config (Google Sheet "Config" tab — list of companies + buckets)
  → Store Config (saves config to workflow static data)
  → Read Results (Google Sheet "Results" tab — for dedup)
  → Build Search URLs (Code node — builds LinkedIn URLs per bucket, Bengaluru location filter)
  → Loop Over URLs
    → Wait Between Searches (rate limit)
    → Fetch Search Page (HTTP GET to LinkedIn public search)
    → Extract Links & Titles (HTML parse)
    → Filter & Accumulate Links (Code — negative title filter + dedup)
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
| Schedule | 24h (default) | Automatic at 7 AM and 7 PM IST | Workflow must be **activated** (toggle) |
| Manual | 24h (default) | Click "Execute Workflow" in n8n UI | None |
| Webhook | Custom (default 12h) | `http://localhost:5678/webhook/job-search?hours=6` | Workflow must be **activated** |
| Telegram | Custom (default 12h) | Message bot: `/jobs 6` | **HTTPS required** — disabled locally, enable on cloud |

**Note:** The Telegram Trigger node is shipped **disabled**. Enable it after deploying to a cloud instance with HTTPS. On cloud, Telegram uses webhook push (zero CPU when idle), not polling.

## 4 Search Buckets

| Bucket | Title Pattern | Negative "senior" filter? | Companies |
|--------|--------------|---------------------------|-----------|
| 1 | SDE II / Software Engineer II | YES — excludes "senior" | Amazon(1586), Flipkart(321062), Expedia(2751), Zeta(10355561), InMobi(272972), Slice(30246063), Groww(10813156), Akamai(3925), Wayfair(19857), Rippling(17988315), Intuit(1666), Microsoft(1035) |
| 2 | Level 3 / III | YES — excludes "senior" | Oracle(1028), Google(1441), Walmart(9390173), eBay(1481) |
| 3 | Generic (Large Tech) | NO — allows "senior" (Myntra/PayPal/MMT use "Senior" for mid-level) | Adobe(1480), Salesforce(3185), Myntra(361348), PayPal(1482), MMT(35113), PhonePe(10479149), Apple(162479), Meta(10667), LinkedIn(1337), Netflix(165158), Uber(1815218), Databricks(3477522) |
| 4 | Generic (Others) | NO — allows "senior" | Atlassian(22688), Nvidia(3608), Airbnb(309694), Confluent(88873), ServiceNow(29352), Workday(17719), Rubrik(4840301), Slack(1612748), Nutanix(735085), OpenTable(12181), Observe.ai(18090845), Acko(13250135), Upstox(15091079), Cred(14485479), SuperMoney(13244834), ClearTax(74474022), Blinkit(80918929), Directi(29570), DeShaw(6508), Kotak(5632), ClearTrip(62902), Swiggy(9252341) |

## LinkedIn URL Construction

Each bucket generates a URL like:
```
https://www.linkedin.com/jobs/search/?keywords=<encoded_boolean_query>&f_C=<company_ids>&f_TPR=r<seconds>&location=India&geoId=102713980&f_PP=105214831&sortBy=DD
```

- `f_TPR=r<seconds>` = time window (e.g., `r86400` = 24 hours)
- `f_C` = comma-separated LinkedIn company IDs
- `geoId=102713980` = India (broad geo)
- `f_PP=105214831` = **Bengaluru, Karnataka** (precise location filter)
- Keywords use Boolean: `"SDE II" OR "SDE 2" OR ...`
- Bucket 1 & 2 keywords include `AND NOT ("senior" OR "staff" OR ...)`
- Bucket 3 & 4 keywords only exclude staff/manager/etc, NOT senior

## Filters

### Negative Title Filters (in "Filter & Accumulate Links" node)
Applied to all buckets: staff, principal, lead, manager, director, ios, android, machine learning, data science, QA, SDET, devops, SRE, frontend, intern, test engineer, platform engineer, infra engineer, cloud engineer, security, mobile, embedded

Additionally for Buckets 1 & 2 only: senior, sr.

### Experience Filter (in "Process & Filter Job" node)
- Regex-based extraction from job description
- **Threshold:** `MAX_EXPERIENCE_YEARS = 4` — skips roles where minimum experience > 4 years
- Examples: "3-5 years" (minExp=3, valid), "4+ years" (minExp=4, valid), "5+ years" (minExp=5, filtered out)
- Patterns matched: "3+ years", "3-5 years", "minimum 3 years", "at least 3 years", etc.
- If experience can't be parsed, passes through as "Not specified" for manual review

### Job ID Extraction (in "Filter & Accumulate Links" node)
Regex: `/-(\d{8,})(?:\?|$)/` — extracts the numeric job ID from LinkedIn URLs like:
`https://in.linkedin.com/jobs/view/software-engineer-at-cleartrip-4370408479?position=1`

## Google Sheet Schema

**Config tab** (`gid=0`, input — user editable):
| Company | CompanyID | Bucket | Active | Notes |

**Results tab** (`gid=812188810`, output — workflow writes here):
| JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status |

Sheet Document ID: `YOUR_GOOGLE_SHEET_DOCUMENT_ID`

**Note:** The workflow references the sheet by Document ID, not by name. You can rename the Google Sheet freely without changing the JSON.

## Telegram Notification Format

**When jobs are found (LLM enriched — sorted by match %):**
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
Color coding: 🟢 ≥70%, 🟡 50-69%, 🔴 <50%

**When jobs are found (LLM fallback — plain format):**
```
🔔 3 New Openings Found

1. Amazon — SDE II (3-5 yrs) [SDE-II]
   📍 Bengaluru, India
   https://linkedin.com/jobs/view/123

⚠️ AI matching unavailable this run.
```

**When no jobs are found:**
```
✅ Job search ran successfully — no new openings found this run.
```

Messages exceeding Telegram's 4096 char limit are automatically split into multiple messages with `...contd` headers.

## Node Reference (37 functional nodes)

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Schedule Trigger | scheduleTrigger | Fires at 7 AM and 7 PM IST |
| 2 | Manual Trigger | manualTrigger | For ad-hoc runs from n8n UI |
| 3 | Telegram Trigger | telegramTrigger | Listens for `/jobs` commands (DISABLED — enable on cloud) |
| 4 | Webhook Trigger | webhook | Local dev trigger: `/webhook/job-search?hours=N` |
| 5 | Parse Hours | code | Parses hours from Telegram `/jobs N` command |
| 6 | Parse Webhook Hours | code | Parses hours from webhook query param |
| 7 | Read Config | googleSheets | Reads Config tab (companies + buckets) |
| 8 | Store Config | code | Saves config to workflow static data, initializes processedJobs |
| 9 | Read Results | googleSheets | Reads Results tab for dedup |
| 10 | Build Search URLs | code | Builds LinkedIn search URLs per bucket |
| 11 | Loop Over URLs | splitInBatches | Iterates over search URLs |
| 12 | Wait Between Searches | wait | Rate limit between search page fetches |
| 13 | Fetch Search Page | httpRequest | HTTP GET LinkedIn search page |
| 14 | Extract Links & Titles | html | Parses job links, titles, companies from HTML |
| 15 | Filter & Accumulate Links | code | Negative title filter + dedup + job ID extraction |
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

## Setup Guide (for new users)

### Prerequisites
- n8n instance (local or cloud)
- Google account with Sheets API access
- Telegram bot (create via @BotFather)

### Step-by-step
1. **Import** `n8n_job_search_v1.json` into n8n
2. **Google Sheets:**
   - Create a Google Sheet with two tabs: "Config" and "Results"
   - Config tab columns: `Company | CompanyID | Bucket | Active | Notes`
   - Results tab columns: `JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status`
   - Update the `documentId` value in the JSON (or re-select the sheet in each Google Sheets node)
   - If your Results tab has a different gid, update in JSON or re-select in n8n UI
3. **Credentials** (connect in n8n UI — all nodes show "CONFIGURE_ME"):
   - Google Sheets OAuth2: connect your Google account
   - Telegram Bot: add your bot token from @BotFather
4. **Telegram Chat ID:**
   - Update `chatId` in "Send Telegram" and "Send No Results Telegram" nodes with your chat ID
5. **Activate** the workflow (toggle in top-right) for scheduled runs
6. **Test** with Manual Trigger or Webhook: `http://localhost:5678/webhook/job-search?hours=24`

### Customization
- **Companies:** Edit the Config tab in Google Sheets (no JSON changes needed)
- **Location:** Change `LOCATION_FILTER` in "Build Search URLs" node (get `f_PP` value from LinkedIn URL)
- **Experience threshold:** Change `MAX_EXPERIENCE_YEARS` in "Process & Filter Job" node
- **Schedule:** Edit cron expression in "Schedule Trigger" node
- **For cloud deployment:** Enable the "Telegram Trigger" node and disable/remove "Webhook Trigger"

## Design Principles
- Config-driven: Companies and buckets read from Google Sheet, not hardcoded
- Location-filtered: Hardcoded to Bengaluru via LinkedIn's f_PP parameter
- LLM-enhanced: Gemini Flash scores each job against resume; enriched Telegram with match % and color coding; Score persisted to sheet. Graceful fallback to plain format on API failure.
- Dedup: By JobID against Results sheet before fetching job details
- Rate limiting: Wait nodes between fetches to avoid LinkedIn throttling
- Message splitting: Telegram messages auto-split at 4096 char limit
- Honest filtering: Never fabricate matches. If experience can't be parsed, pass through as "Not specified"

## Production Deployment (GCP e2-micro)

### Architecture
```
Internet → Caddy (auto-HTTPS via nip.io, :443) → n8n (:5678) → SQLite (Docker volume)
```
- VM: GCP e2-micro, Ubuntu 22.04, us-central1-a (always-free tier)
- Domain: `<VM_IP>.nip.io` (free, no DNS registration)
- HTTPS: Let's Encrypt via Caddy (automatic)

### Deployment Files
| File | Purpose |
|------|---------|
| `deploy/docker-compose.prod.yml` | Production compose with n8n + Caddy |
| `deploy/Caddyfile` | Caddy reverse proxy config |
| `deploy/setup.sh` | One-time VM setup (Docker, dirs, services) |
| `deploy/import-workflow.sh` | Import/update workflow via n8n REST API |
| `.github/workflows/deploy.yml` | CI/CD — auto-deploy on push to main |

### GCP VM Setup
1. Create e2-micro VM (Ubuntu 22.04, us-central1-a) with HTTP/HTTPS firewall enabled
3. SSH in, clone the repo, run `sudo bash deploy/setup.sh`
4. Open `https://<VM_IP>.nip.io`, set up Google Sheets + Telegram credentials
5. Import workflow, enable Telegram Trigger node, activate workflow
6. Generate n8n API key (Settings > API) for CI/CD

### GitHub Actions CI/CD
Auto-deploys workflow changes when `n8n_job_search_v1.json` is pushed to `main`.

**Required GitHub Secrets:**
| Secret | Value |
|--------|-------|
| `GCP_VM_IP` | VM external IP address |
| `GCP_SSH_PRIVATE_KEY` | SSH private key for the VM |
| `GCP_SSH_USER` | SSH username (your Gmail username) |
| `N8N_API_KEY` | n8n API key from Settings > API |

### Enabling Telegram Trigger on Cloud
1. In n8n UI, enable the "Telegram Trigger" node (right-click > Enable)
2. Optionally disable the "Webhook Trigger" node (not needed on cloud)
3. Save and activate the workflow — Telegram will auto-register its webhook with n8n's HTTPS URL

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
| Scope | All active companies | Single company (partial match) |
| Time unit | Hours | Days (default 7) |
| Dedup | Against Results sheet | Within-run only (no sheet dedup) |
| Negative title filters | Same | Same (staff, QA, devops, etc.; senior for buckets 1 & 2) |
| Experience filter | Same | Same (skips >4 yrs min) |
| Sheet writes | Appends to Results | None (stateless) |
| Notification tracking | Marks Notified=TRUE | None |
| LLM matching | Gemini Flash resume matching (match % in Telegram, Score in sheet) | Gemini Flash resume matching (match %, summary, gaps) + Gmail |
| Email notification | None | Gmail with detailed match analysis (when LLM succeeds) |

### Architecture
```
Telegram Trigger (/search)
  → Parse Search Command (company + days)
  → Read Config (Google Sheet)
  → Lookup Company (case-insensitive partial match)
  → Company Found?
    ├─ NO → Send Error Telegram
    └─ YES → Build Search URL → Loop Over URLs
      → Wait 3s → Fetch → Extract → Filter → loop back
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

### Node Reference (30 functional nodes + 4 sticky notes)

| # | Node Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | Telegram Trigger | telegramTrigger | Listens for `/search` commands |
| 2 | Parse Search Command | code | Extracts company name + days (default 7, clamped 1-90) |
| 3 | Read Config | googleSheets | Reads Config tab (same sheet as main workflow) |
| 4 | Lookup Company | code | Case-insensitive partial match against active companies |
| 5 | Company Found? | if | Routes found/not-found |
| 6 | Send Error Telegram | telegram | "Company not found" or "Invalid command" error |
| 7 | Build Search URL | code | Builds LinkedIn URL using company's bucket keywords |
| 8 | Loop Over URLs | splitInBatches | Handles multi-bucket partial matches |
| 9 | Wait Between Searches | wait | 3s rate limit |
| 10 | Fetch Search Page | httpRequest | LinkedIn search page, 30s timeout |
| 11 | Extract Links & Titles | html | Same CSS selectors as main workflow |
| 12 | Filter Links | code | Negative title filter + job ID extraction, no dedup |
| 13 | Output Job Links | code | Fans out accumulated links or signals empty |
| 14 | Has Links? | if | Routes to job processing or no-results message |
| 15 | Send No Results Telegram | telegram | "No openings found in Bengaluru" |
| 16 | Loop Over Jobs | splitInBatches | Iterates job detail fetches |
| 17 | Wait Between Jobs | wait | 5s rate limit |
| 18 | Fetch Job Detail | httpRequest | Individual job page, 30s timeout |
| 19 | Parse Job Details | html | Same CSS selectors as main workflow |
| 20 | Process Job | code | Experience extraction + tagging + saves description for LLM |
| 21 | Format Telegram | code | Enriched format (match %, colors) or plain fallback |
| 22 | Split Messages | code | Fans out message chunks |
| 23 | Send Results Telegram | telegram | Sends result message(s) |
| 24 | Read Resume | googleSheets | Reads "Resume" tab (Key/Value pairs) from same sheet |
| 25 | Prepare LLM Input | code | Builds Gemini prompt with resume + job descriptions |
| 26 | Call Gemini Flash | httpRequest | POST to Gemini 2.5 Flash API (60s timeout, continueOnFail) |
| 27 | Parse LLM Response | code | Validates & merges match scores into jobs, sorts by match % |
| 28 | LLM Succeeded? | if | Routes: LLM worked → email, LLM failed → end |
| 29 | Format Email | code | Builds detailed email with summary, matches, gaps per job |
| 30 | Send Gmail | gmail | Sends detailed results email |

### Telegram Message Formats

**Results found (LLM enriched — sorted by match %):**
```
🔍 Jobs at Oracle (last 30 days) — 5 openings

1. 🟢 82% — Software Engineer III (3-5 yrs) [SE-III]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/123

2. 🟡 65% — Backend Engineer (3+ yrs) [Backend]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/456

3. 🔴 38% — Cloud Engineer (5+ yrs) [Generic]
   📍 Bengaluru, India
   🔗 https://linkedin.com/jobs/view/789
```
Color coding: 🟢 ≥70%, 🟡 50-69%, 🔴 <50%

**Results found (LLM fallback — plain format):**
```
🔍 Jobs at Oracle (last 30 days)

Found 5 openings in Bengaluru:

1. Oracle — Software Engineer III (3-5 yrs) [SE-III]
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
| name | Jatin Solanki |
| title | Full-stack Software Engineer |
| years_experience | 3.5 |
| target_roles | SDE-II, Software Engineer, Backend Engineer, Full-Stack Engineer |
| skills_languages | Java, SQL, JavaScript, TypeScript, Bash, Groovy, C/C++ |
| skills_frameworks | Spring Boot, Hibernate/JPA, Apache Kafka, RESTful APIs, GraphQL, OAuth2/JWT, Node.js, Angular |
| skills_databases | Oracle, MySQL, MongoDB |
| skills_cloud | GCP, Docker, Kubernetes, OpenShift, Helm, Jenkins, Maven |
| skills_other | Microservices Architecture, Event-Driven Systems, Distributed Systems, Design Patterns, TDD, CI/CD Pipelines |
| experience_summary | (free text — key roles, achievements, companies) |
| education | B.Tech Computer Science, Manipal Institute of Technology, CGPA 9.52/10, 2022 |
| highlights | EUR 70mn annual cost savings, Kafka migration with zero disruption, 25% CI/CD runtime reduction |

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
3. Connect Google Sheets credential (same as main workflow)
4. **Resume tab:** Create a "Resume" tab in the Google Sheet with Key/Value columns (referenced by name, not GID), populate with your profile
5. **Gemini API key:** Get a free key from https://aistudio.google.com/apikey, add `GEMINI_API_KEY` to Docker compose environment, restart
6. **Gmail:** Create Gmail OAuth2 credential in n8n (enable Gmail API + `gmail.send` scope in GCP console), update `sendTo` email in Send Gmail node
7. Activate the workflow (requires HTTPS for Telegram webhook)

**Telegram bot setup:** Each workflow needs its own Telegram bot. The `/jobs` workflow uses one bot, the `/search` workflow uses another. Both bots can message the same chat (same `chatId`).

## V2 Roadmap
- Auto resume customization
