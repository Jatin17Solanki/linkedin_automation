# LinkedIn Job Search V1 — Setup Guide

This project ships **3 independent workflows** — you don't need all three. Decide what you actually want before you start:

| I want... | Set up | Section |
|---|---|---|
| Automated scheduled searches across all my companies, pushed to Telegram | **Main Job Search** workflow | Part 1 (below) — start here, this is the core project |
| To look up one specific company on demand (`/search Oracle 30`), with a detailed email report | **Company Search** workflow (optional, additive) | [Part 1B](#part-1b-company-search-setup-search--optional) — needs a 2nd Telegram bot + Gmail |
| Claude.ai to parse LinkedIn job URLs for me | **Job Parser** webhook + MCP server (optional, standalone) | [Part 1C](#part-1c-job-parser--mcp-server-setup-optional) — no Telegram/Sheets needed at all |

All three get **imported automatically** the moment n8n starts (local or cloud) — "setting one up" past that point just means connecting its credentials and activating it. Skip Part 1B/1C entirely if you only want the main workflow; the other two just sit there imported-but-inactive with no side effects.

> **Local vs. cloud:** everything below (Part 1, 1B, 1C) works identically whether n8n is running locally (`docker compose up`, this page) or on a cloud VM ([Part 2: GCP](#part-2-production-deployment-gcp-e2-micro) / [Part 3: AWS EC2](#part-3-production-deployment-aws-ec2)) — only the URL you open in your browser changes (`localhost:5678` vs `https://<VM_IP>.nip.io`). Read Part 2/3 first if you're deploying straight to the cloud without testing locally.

---

# Part 1: Main Job Search Workflow (Local Setup)

## Prerequisites
- Docker Desktop running
- Google account (for Sheets)
- Telegram (bot already created)

---

## Step 1: Start n8n

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO
docker compose up -d --build
```

This builds the repo's own `Dockerfile` (pinned to `n8nio/n8n:1.123.25`) and auto-imports all 3 workflow JSONs on first start — you'll see them already in the Workflows list once n8n is up. **Auto-import only handles the workflow definitions.** Credentials (Google Sheets, Telegram, Gmail) still need one-time interactive setup in the n8n UI (Steps 3 and 5 below) — OAuth consent can't be scripted.

Open: **http://localhost:5678**  
First time: Create an owner account (email + password). Local only.

---

## Step 2: Set Up Google Sheet

Create a new Google Sheet (or open your existing one).

**Fastest path:** paste [`examples/google-sheet/bootstrap.gs`](../examples/google-sheet/bootstrap.gs) into Extensions → Apps Script and run the `bootstrap` function once — it creates all three tabs below with headers, pre-fills Config with the example company list, and pre-fills Resume with placeholder values you edit afterward. Skip to Step 3 if you use this.

Otherwise, create the tabs by hand using the templates in [`examples/google-sheet/`](../examples/google-sheet/):

### Tab 1: "Config"
Rename default "Sheet1" to **Config**. Headers in Row 1:

| Company | CompanyID | Bucket | Active | Notes |

Paste the data from [`examples/google-sheet/config_data.csv`](../examples/google-sheet/config_data.csv).

### Tab 2: "Results"
Create new tab **Results**. Headers in Row 1:

| JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status |

Header row only — copy from [`examples/google-sheet/results_template.csv`](../examples/google-sheet/results_template.csv). The workflow writes rows here at runtime.

### Tab 3: "Resume"
Create new tab **Resume**. Headers in Row 1:

| Key | Value |

Paste the data from [`examples/google-sheet/resume_template.csv`](../examples/google-sheet/resume_template.csv), then replace the placeholder values with your own profile — this is what the LLM matching step scores jobs against.

---

## Step 3: Configure Credentials in n8n

### Google Sheets OAuth2

Self-hosted n8n (local or cloud) doesn't ship with a pre-registered Google OAuth client the way n8n Cloud does — you register your own, once, in Google Cloud Console. **This is identical whether n8n is running locally or on the GCP VM from Part 2 — the only difference between the two is the redirect URI value in step 3.** The Google Cloud project you create here is unrelated to (and doesn't require) any VM — it's pure OAuth/API registration, separate from wherever n8n happens to be hosted.

1. In n8n: **Settings → Credentials → Add Credential** → search **Google Sheets OAuth2**. Leave this tab open — it shows an **OAuth Redirect URL** you'll need in step 3 (for local: `http://localhost:5678/rest/oauth2-credential/callback`; for the GCP VM from Part 2: `https://<VM_IP>.nip.io/rest/oauth2-credential/callback` — always copy the exact value n8n shows you rather than typing it from memory).
2. In [Google Cloud Console](https://console.cloud.google.com), create or pick any project (free, no billing/VM required):
   - **APIs & Services → Library** → search "Google Sheets API" → **Enable**
   - Also search "Google Drive API" → **Enable** — n8n's Sheets node uses this to list/browse your spreadsheets in its picker UI, even though actual reads/writes go through the Sheets API. Skipping this causes a 403 ("Drive API not enabled") the first time you open a node like Read Config.
   - **APIs & Services → OAuth consent screen** → User type **External** → fill in an app name/support email → **Save**. It'll be in "Testing" mode — add your own Google account under **Test users** so you can actually sign in (unverified apps otherwise reject everyone).
3. **APIs & Services → Credentials → Create Credentials → OAuth Client ID** → type **Web application** → under **Authorized redirect URIs**, paste the exact URL n8n showed you in step 1.
4. Google shows a dialog with your **Client ID** and **Client Secret**, plus a **Download JSON** button — click it and save the file somewhere safe (a password manager, not this repo). You'll need these values again if you ever recreate this credential in n8n (new instance, lost data, etc.), and the Client Secret isn't shown in full again from the Console afterward. Copy the Client ID and Client Secret back into the n8n credential form from step 1.
5. Click **Sign in with Google**. You'll hit Google's "unverified app" warning (expected — same mechanism as the `bootstrap.gs` Apps Script consent earlier, just for an OAuth Client instead of a script): **Advanced → Go to [your app name] (unsafe) → Allow**.
6. **Save** in n8n.

### Telegram Bot
1. Settings → Credentials → Add Credential  
2. Search "Telegram"
3. Paste your Bot Token (get it from @BotFather on Telegram — message it `/newbot` to create one, or `/mybots` → your bot → API Token to retrieve an existing one)
4. Save

**Also get your chat ID** (separate from the bot token — this is *where* the bot sends messages, set via the `TELEGRAM_CHAT_ID` env var, not stored as a credential): message **@userinfobot** on Telegram and it replies with your numeric user ID. Then **open a chat with your own bot and send it any message** (e.g. `/start`) — Telegram bots can't message a user who hasn't initiated contact first, so skipping this causes a "chat not found" error later even with a correct token and chat ID.

---

## Step 4: Confirm the Workflow Is Present

The Docker image auto-imports all 3 workflow JSONs on first start (see Step 1) — open **Workflows** in the n8n UI and confirm `LinkedIn Job Search V1` is listed. Nothing to import manually.

If you're running n8n a different way (not via this repo's `docker-compose.yml`/`Dockerfile`), import it yourself: Workflows → Import from file → select `n8n_job_search_v1.json`.

---

## Step 5: Connect Credentials to Nodes

Each node with ⚠️ needs credentials linked:

**Google Sheets credential** → Read Config, Read Results, Append to Results, Read Unnotified, Update Notified Status, Read Resume, Read Settings  
**Telegram credential** → Send Telegram, Send No Results Telegram, Telegram Trigger (leave this one — it's disabled by default; see the Telegram Trigger note earlier in this doc for when to enable it on cloud)

Double-click node → select credential from dropdown → close.

**This alone isn't enough to make the Google Sheets nodes work.** Attaching a credential only tells the node *how* to authenticate — it doesn't tell it *which* spreadsheet to use. Every Google Sheets node above still points at the placeholder `YOUR_GOOGLE_SHEET_DOCUMENT_ID` from the committed workflow JSON, not your actual Sheet. You must repoint each one individually:

For **each** of the 7 nodes listed above: double-click it → the **Document** field → click the dropdown/**From list** → select your actual Google Sheet (now that a credential is attached, it can browse your Drive) → the field switches from the placeholder to your real spreadsheet → close the node. There's no bulk/one-shot way to do this — n8n stores the document reference per-node, so all 7 need it individually.

---

## Step 6: Verify Sheet Connection

1. Double-click "Read Config" → verify Sheet Name = "Config" → Test step
2. Double-click "Read Results" → verify Sheet Name = "Results" → Test step

---

## Before you run it: what are you actually about to test?

A first run with no changes applies these defaults — worth knowing up front so the results (or lack of them) make sense:

| Filter | Default | Where it's set |
|--------|---------|-----------------|
| Time window | Last 24 hours | Built into `Build Search URLs`' code (`staticDataForTime.customTimeWindow \|\| 86400`); Manual Trigger doesn't override this |
| Location | Bengaluru, Karnataka (India, broad) | Settings tab (`location_f_pp`/`location_geo_id`/`location_city_names`) if set, else `.env` — blank in both means these Bengaluru defaults apply |
| Max experience required | 4 years | Settings tab (`max_experience_years`) if set, else `.env` — blank in both means this default applies |
| Match % shown in Telegram | All shown (no minimum) | Settings tab (`min_match_percent`) — see "Customizing Location, Experience & Role Filters" below |
| Companies searched | Every row in the Config tab with `Active=TRUE` | Config tab — see "Add/Remove Companies" below |

Because the window is only 24 hours, a first test run can easily come back with **zero results** simply because none of your configured companies happened to post a matching Bengaluru role in the last day — that's expected behavior, not a broken setup. Widen the window temporarily (next step) if you want to confirm the pipeline works end-to-end rather than waiting for real-time luck.

## Step 7: First Test Run

1. Click "Test workflow" (top right)
2. Watch nodes light up green
3. **To guarantee some results while testing** (rather than waiting on the last 24h): open `Build Search URLs`, find `const TIME_WINDOW_SECONDS = staticDataForTime.customTimeWindow || 86400;`, temporarily change the `86400` to something larger like `2592000` (30 days)
4. Change it back to `86400` afterward — leaving it widened would apply to real scheduled/manual runs too, not just your test

---

## Step 8: Activate

Toggle "Active" switch → ON. Runs at 7 AM & 7 PM IST automatically.

---

## Instant/Ad-hoc Run

**Quick run:** Click "Test workflow" in editor (uses the 24h default described above).

**Custom time window:** Same `Build Search URLs` edit as Step 7 — swap the `86400` fallback for:
- 7200 = 2 hours
- 14400 = 4 hours  
- 28800 = 8 hours
- 43200 = 12 hours
- 86400 = 24 hours (default)

Run, then change back to `86400`.

---

## Add/Remove Companies

Open Google Sheet → Config tab:
- **Add:** New row with Company, CompanyID, Bucket (1-4), Active=TRUE
- **Disable:** Set Active=FALSE
- **Remove:** Delete the row

### Bucket Reference
| Bucket | Title Pattern | Companies |
|--------|--------------|-----------|
| 1 | SDE II / SE II | Amazon, Flipkart, Expedia, Zeta, InMobi, Slice, Groww, Akamai, Wayfair, Rippling, Intuit, Microsoft |
| 2 | Level 3 / III | Oracle, Google, Walmart, eBay |
| 3 | Generic (Large) | Adobe, Salesforce, Myntra, PayPal, MMT, PhonePe, Apple, Meta, LinkedIn, Netflix, Uber, Databricks |
| 4 | Generic (Others) | Atlassian, Nvidia, Airbnb, Confluent, ServiceNow, Workday, Rubrik, Slack, Nutanix, OpenTable, Observe.ai, Acko, Upstox, Cred, SuperMoney, ClearTax, Blinkit, Directi, DeShaw, Kotak, ClearTrip, Swiggy |

---

## Customizing Location, Experience & Role Filters

**Two ways to set location/experience/match-threshold, in priority order:**

1. **Settings tab in your Google Sheet** (`location_geo_id`, `location_f_pp`, `location_city_names`, `max_experience_years`, `min_experience_years`, `min_match_percent`) — created by `bootstrap.gs`, pre-filled with the same defaults as below. Edit anytime in your browser; the workflow reads it fresh on every run, **no container restart needed**. Leave a value blank to fall back to its env var. **Row 1 must be the literal headers `Key` and `Value`** if you create this tab by hand instead of via `bootstrap.gs` — see `TROUBLESHOOTING.md` if values don't seem to be taking effect.
2. **Environment variables** (below) — the fallback when the matching Settings row is blank or the tab doesn't exist. Requires a container recreate (`docker compose up -d`, not just `restart`) to take effect.

Settings tab wins when both are set. Most users should just use the Settings tab day-to-day — env vars exist mainly for cloud deployments where you want values baked into the container config, or as the fallback if you're not using `bootstrap.gs`.

| Variable | Settings tab key | Default | Purpose |
|----------|-------------------|---------|---------|
| `TELEGRAM_CHAT_ID` | — (not settable via Sheet) | *(none — required)* | Chat ID the bot sends notifications to — message @userinfobot on Telegram to get your numeric ID, see Step 3 |
| `GEMINI_API_KEY` | — (not settable via Sheet) | *(none — required for LLM matching)* | Gemini Flash API key for resume matching — free key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey), no billing account required for the free tier (works even with an expired GCP trial — project creation and this API's free tier are unrelated to trial/billing status) |
| `LOCATION_GEO_ID` | `location_geo_id` | `102713980` (India) | LinkedIn `geoId` — broad country/region scope |
| `LOCATION_F_PP` | `location_f_pp` | `105214831` (Bengaluru) | LinkedIn `f_PP` place ID(s) — comma-separated for multi-city |
| `LOCATION_CITY_NAMES` | `location_city_names` | `bengaluru,bangalore,karnataka` | Substrings checked against each job's parsed location; keep in sync with `LOCATION_F_PP` |
| `MAX_EXPERIENCE_YEARS` | `max_experience_years` | `4` | Upper bound of the experience bracket you're targeting |
| `MIN_EXPERIENCE_YEARS` | `min_experience_years` | `0` (no floor) | Lower bound of the experience bracket you're targeting. Together with `MAX_EXPERIENCE_YEARS`: a role matches if its own stated range overlaps `[MIN, MAX]` at all — touching boundaries count as a match, and open-ended postings ("5+ years") always satisfy the upper-bound side since they have no ceiling to compare. Deliberately permissive: e.g. targeting `3-5`, a "2-4 years" posting matches, and so does "5+ years", but "8+ years" doesn't. Defaults reproduce the original single-ceiling behavior exactly. |
| `MIN_MATCH_PERCENT` | `min_match_percent` | `0` (no suppression) | Hide jobs scoring below this % from the Telegram message (still logged to the Results sheet and marked notified — see `CLAUDE.md`'s Settings tab section) |
| `VM_IP` | — | — | Set by `deploy/setup-gcp.sh` (or `setup-aws.sh`); used for the `nip.io` HTTPS domain |
| `DOCKER_IMAGE` | — | `ghcr.io/jatin17solanki/linkedin-automation-n8n:latest` | Pre-built image to pull for production; override if you've forked the repo and publish your own |
| `N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD` | — | — | Protects the n8n web UI on cloud deployments |
| `MCP_WEBHOOK_URL` | — | *(none — required for the MCP server)* | Base URL the `parse-linkedin-job` MCP tool calls |
| `N8N_MEM_LIMIT` / `N8N_MEMSWAP_LIMIT` / `NODE_MAX_OLD_SPACE` | — | `600m` / `800m` / `512` | Memory tuning, sized for a 1GB-RAM free-tier VM — only raise these on a larger instance. See `TROUBLESHOOTING.md`'s "VM freezes completely" entry |

Set env vars in `deploy/.env` (copy from `deploy/.env.example`) for cloud deployments, or pass them as `environment:` values in `docker-compose.yml` for local dev. `n8n_company_search_v1.json` (the on-demand `/search` workflow) uses the same Settings tab and precedence — both workflows stay in sync.

### Updating these values later

On a cloud VM (GCP or AWS), `deploy/setup-gcp.sh`/`setup-aws.sh` only prompt for these once, when they first create `/opt/n8n/.env` — re-running the script later doesn't re-ask or overwrite anything you've already set. To change a value after initial setup (rotate `GEMINI_API_KEY`, fix a mistyped `TELEGRAM_CHAT_ID`, adjust `N8N_MEM_LIMIT`, etc.):

```bash
sudo nano /opt/n8n/.env      # edit the value directly
cd /opt/n8n && sudo docker compose up -d   # apply -- a plain `restart` does NOT re-read .env
```

This applies to any variable in the table above, not just the two the setup script prompts for.

### Adding multiple cities

Two fields change, both comma-separated lists — `location_geo_id` (Settings tab) / `LOCATION_GEO_ID` (env var) does **not** need to change for multi-city within the same country; it stays at the broad India-level default.

1. **`location_f_pp` / `LOCATION_F_PP`** — LinkedIn's actual search filter. Accepts a comma-separated list of place IDs, OR-matched (LinkedIn returns results matching *any* listed city).
2. **`location_city_names` / `LOCATION_CITY_NAMES`** — this project's own post-fetch safety check (see `CLAUDE.md`'s Filters section: "LinkedIn's `f_PP` URL param alone is unreliable — non-target-city roles leak through"). Add every city (and its state, as a fallback — see below) you added to `location_f_pp`, or jobs from that city will pass LinkedIn's filter but then get silently rejected by this project's own location check.

**Getting a city's place ID:** go to `linkedin.com/jobs/search`, use the **Location** filter box, and pick the city from LinkedIn's own autocomplete dropdown (free-typed text won't generate a real place ID). Copy the `f_PP=<number>` value from the resulting URL.

**Known place IDs** (found this way during this project's own testing — reuse these instead of re-deriving them):

| City | `f_PP` value |
|------|--------------|
| Bengaluru | `105214831` |
| Mumbai | `90009551` |
| Hyderabad | `105556991` |
| Gurugram | `106442238` |

**Worked example** — Bengaluru + Hyderabad + Gurugram:

```
LOCATION_F_PP=105214831,105556991,106442238
LOCATION_CITY_NAMES=bengaluru,bangalore,karnataka,hyderabad,telangana,gurugram,gurgaon,haryana
```

Two things about the city-names list above worth noting as a pattern for any city you add: include the **state name** alongside the city (LinkedIn's parsed location text sometimes only surfaces the state), and include **known alternate spellings** (Gurugram was officially renamed from Gurgaon, and job postings inconsistently use either — matching only one would silently drop real matches under the other spelling).

Find a city's `f_PP` value by searching LinkedIn Jobs with that location filter applied and reading the `f_PP` param out of the resulting URL. `LOCATION_GEO_ID` stays a single broad value (e.g. `102713980` for all of India) — it isn't per-city.

### Customizing role/seniority keywords

The 4 search buckets (title patterns + which companies use "senior" for mid-level titles) and the negative title filter (excluded keywords like "staff", "principal", "QA") are inline JavaScript, not env-driven — this is intentional (see `CLAUDE.md`'s "4 Search Buckets" and "Filters" sections for the full logic). To change them, edit directly in the n8n UI:

- **Bucket keywords:** `Build Search URLs` node (main workflow) / `Build Search URL` node (company search) — the `bucketKeywords` object
- **Negative title filter:** `Filter & Accumulate Links` node (main workflow) / `Filter Links` node (company search)

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No data from search | Test URL in incognito. Increase wait time to 15s. |
| Sheets permission denied | Re-authorize credential |
| Telegram not sending | Send /start to bot first |
| Too few results | Increase TIME_WINDOW_SECONDS for testing |

---
---

# Part 1B: Company Search Setup (`/search` — optional)

On-demand lookup for one specific company (`/search Oracle 30`), with a detailed email report on top of the Telegram reply. **Completely independent of the main workflow above** — has its own Telegram bot, doesn't touch the Results sheet, doesn't affect the main workflow's dedup or schedule. Skip this whole section if you only want scheduled automatic searches.

**Where to do this:** Company Search's *only* trigger is a Telegram webhook, which needs HTTPS — so unlike the main workflow (which also has a Manual/local Webhook trigger for testing), **`/search` only actually responds on a cloud VM** ([Part 2](#part-2-production-deployment-gcp-e2-micro) / [Part 3](#part-3-production-deployment-aws-ec2)).
- **Already deployed to the cloud?** Do steps 1–7 below in order, in your **cloud** n8n (`https://<VM_IP>.nip.io`) — that's the instance where this workflow will run. (Credentials live per-n8n-instance, so a bot/Gmail credential you set up in a local n8n doesn't carry over to the VM.)
- **Setting up locally first?** Steps 1–5 and the credential/Sheet wiring in step 6 work locally right now; activating it and testing (step 6's last paragraph, and step 7) only work once you're on a cloud VM.

### 1 — Confirm the workflow is present

Same as Part 1 Step 4 — open **Workflows** in n8n, confirm `LinkedIn Company Search V1` is listed (auto-imported by Docker, same as the other two).

### 2 — Create a second, separate Telegram bot

Telegram only supports **one webhook per bot** — you can't reuse the bot from Part 1. Message **@BotFather** → `/newbot` → save the new API token. **Message this new bot once** (e.g. `/start`) — same reason as Part 1: bots can't message a user who hasn't initiated contact first.

### 3 — Add the Telegram credential in n8n

**Credentials → Add Credential → Telegram** → paste the *new* bot's token → Save. This is a second, separate Telegram credential from Part 1's — don't reuse that one.

### 4 — Reuse your existing Google Sheets credential

No new OAuth setup needed — Company Search reads the **same** Google Sheet (Config, Settings, Resume tabs) via the **same** Google Sheets credential from Part 1, Step 3. You'll just attach that existing credential to this workflow's nodes in Step 6 below.

### 5 — Set up a Gmail credential (for the email digest)

1. In the same Google Cloud project you used for the Sheets OAuth Client (Part 1, Step 3) — **APIs & Services → Library** → search "Gmail API" → **Enable**
2. **APIs & Services → Credentials → Create Credentials → OAuth Client ID** (or reuse the existing one — the **gmail.send** scope will be requested on first sign-in either way)
3. In n8n: **Credentials → Add Credential → Gmail OAuth2** → connect using that Client ID/Secret → sign in, approve the `gmail.send` scope
4. Open the **Send Gmail** node in the workflow → set **To** to your own email address. It ships as `CONFIGURE_ME@example.com` and is set per-node (not an env var), so nothing will be sent to you until you change it.

### 6 — Connect credentials, point the Sheets nodes at your Sheet, then activate

Open the `LinkedIn Company Search V1` workflow and, for each node with a ⚠️:

**Credentials:**
- **Google Sheets credential** (the existing one from Part 1) → `Read Config`, `Read Settings`, `Read Resume`
- **Telegram credential** (the *new* bot from step 2) → `Send Error Telegram`, `Send No Results Telegram`, `Send Results Telegram`, `Telegram Trigger`
- **Gmail credential** → `Send Gmail`

**Then point the 3 Sheets nodes at your actual Sheet — attaching a credential alone isn't enough.** `Read Config`, `Read Settings` and `Read Resume` all still point at the placeholder `YOUR_GOOGLE_SHEET_DOCUMENT_ID`. For each: double-click → **Document** → **From list** → pick your Sheet → close. (Same as Part 1, Step 5 — there's no bulk option, so it's 3 nodes individually.)

**Activate (cloud only):** toggle **Active** (top-right). Unlike the main workflow, the `Telegram Trigger` here is **not** shipped disabled — there's nothing to enable; activating the workflow is what makes n8n register the webhook with Telegram.

### 7 — Test

Message your **new** bot: `/search Oracle 30`. You should get a Telegram reply, and — if Gemini matching succeeds — a follow-up email.

---

# Part 1C: Job Parser + MCP Server Setup (optional)

A stateless webhook that turns a LinkedIn job URL into structured JSON — no Telegram, no Google Sheets, no credentials at all. Useful standalone, or as a tool Claude.ai can call directly via the included MCP server. Skip this section if you don't need either.

### 1 — Confirm the workflow is present and activate it

Open **Workflows** in n8n, confirm `LinkedIn Job Parser` is listed (auto-imported). Open it → toggle **Active** (top-right) — plain webhooks (unlike Telegram Trigger) don't need HTTPS, so this works locally right now, no cloud deployment required.

### 2 — Test it directly

```bash
curl -X POST http://localhost:5678/webhook/parse-job \
  -H "Content-Type: application/json" \
  -d '{"url": "https://linkedin.com/jobs/view/4370408479"}'
```
(Swap in a real LinkedIn job URL — replace `localhost:5678` with `https://<VM_IP>.nip.io` once deployed to the cloud.) You should get back structured JSON — title, company, location, experience, description, etc.

If you just wanted the webhook itself (e.g. for your own scripts), you're done — stop here.

### 3 — Set up the MCP server (optional — lets Claude.ai/Claude Desktop call this directly)

1. `cd mcp-server && npm install`
2. Add this to your Claude Desktop config (Developer → Edit Config) — **the `env` block is required**, `mcp-server/index.js` refuses to start without `MCP_WEBHOOK_URL` set:
   ```json
   {
     "mcpServers": {
       "linkedin-job-parser": {
         "command": "node",
         "args": ["/absolute/path/to/mcp-server/index.js"],
         "env": {
           "MCP_WEBHOOK_URL": "http://localhost:5678/webhook/parse-job"
         }
       }
     }
   }
   ```
   Use your n8n instance's real address — `http://localhost:5678/webhook/parse-job` for local, `https://<VM_IP>.nip.io/webhook/parse-job` once deployed to the cloud (Part 2/3).
3. Restart Claude Desktop — the `parse-linkedin-job` tool appears automatically. Try asking Claude to parse a LinkedIn job URL to confirm it works.

---
---

# Part 2: Production Deployment (GCP e2-micro)

Deploy n8n to a free GCP VM with HTTPS (needed for Telegram Trigger) and GitHub Actions CI/CD.

## Architecture

```
Internet → Caddy (auto-HTTPS via nip.io, :443) → n8n (:5678) → SQLite (Docker volume)
```

- **VM:** GCP e2-micro, Ubuntu 22.04, us-central1-a (always-free tier)
- **Domain:** `<VM_IP>.nip.io` (free wildcard DNS, no registration)
- **HTTPS:** Let's Encrypt via Caddy (fully automatic)
- **Cost:** $0/month (within GCP free tier — but see the note below before you rely on that)

> **GCP's free tier has two separate parts, easy to conflate:** the **Free Trial** ($300 credit, 90 days) every new account starts on, and the **Always Free** tier (1 e2-micro instance/month, indefinitely) that this whole guide assumes. The Always Free tier only actually applies once you've **upgraded your account out of trial mode** (Billing → Upgrade — still $0 charged as long as you stay inside the always-free quota). If you let the 90-day trial lapse without upgrading, GCP suspends your resources at that boundary regardless of what you're actually using — you never get to "indefinite" at all. Do this before or right after creating your VM below, not after the trial has already run out.

---

## Before You Start — Gather These

Two values the setup script will ask you for in Step 2.2 — get them ready now so you're not stuck mid-setup:

| What | Where to get it | Notes |
|------|------------------|-------|
| **Gemini API key** | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Free, no billing account needed. Powers the resume-matching % in your notifications. |
| **Telegram chat ID** | Message **@userinfobot** on Telegram | It replies with your numeric user ID. This is *where* notifications get sent — separate from the bot token below. |

You'll also need a Telegram **bot** (separate from the chat ID above) for Step 3.2 — if you haven't made one yet, message **@BotFather** → `/newbot` now and save the API token it gives you. **Also send your new bot any message right now** (e.g. `/start`) — bots can't message a user who hasn't initiated contact first, and skipping this causes a "chat not found" error later even with a correct token and chat ID.

You can skip either of the first two at the setup script's prompt and set them later (see "Updating these values later" further down) — but having them ready now saves a round trip.

---

## Step 1: Create the GCP VM

### 1.1 — Create a GCP project

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Click the project dropdown (top-left) → **New Project**
3. Name: `n8n-automation` → click **Create**
4. Select the new project from the dropdown

### 1.2 — Enable Compute Engine

1. In the left sidebar: **Compute Engine** → **VM instances**
2. Click **Enable** if prompted (takes ~1 minute)

### 1.3 — Create the VM

Click **Create Instance** and fill in:

| Setting | Value |
|---------|-------|
| Name | `n8n-server` |
| Region | `us-central1` |
| Zone | `us-central1-a` |
| Series | E2 |
| Machine type | **e2-micro** (2 vCPU, 1 GB) — free tier |
| Boot disk | Ubuntu 22.04 LTS, 30 GB — click **Change** to set this |
| Firewall | ✅ Allow HTTP, ✅ Allow HTTPS |

Click **Create**. Wait for the green checkmark.

> **Note:** No network tags needed. The HTTP/HTTPS firewall checkboxes above handle port access.

### 1.4 — Note your external IP

Find the **External IP** column on the VM instances page. Write it down (e.g., `34.71.123.45`).

**Make the IP static** (optional but recommended — free while VM is running):
1. **VPC Network** → **IP addresses** → find your VM's IP
2. Click **Reserve** under the Type column

---

## Step 2: Set Up the VM

### 2.1 — SSH into the VM

On the VM instances page, click the **SSH** button next to your VM (opens a browser terminal).

Or from your local terminal (requires [gcloud CLI](https://cloud.google.com/sdk/docs/install)):
```bash
gcloud compute ssh n8n-server --zone=us-central1-a
```

### 2.2 — Clone and run setup

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO
sudo bash deploy/setup-gcp.sh
```

The script will:
1. Install Docker and Docker Compose
2. Set up a 2GB swapfile if none is active yet (required on the 1GB-RAM e2-micro — see `TROUBLESHOOTING.md`; set `LOW_MEMORY=false` before the command above to skip this on a larger VM)
3. Create the Docker volumes n8n/Caddy data lives in
4. **Ask for n8n username and password** (protects the web UI) — **save these somewhere durable** (password manager, not just your terminal scrollback). This is your login for `https://<VM_IP>.nip.io` once the stack is up, it's not shown again after this prompt, and there's no "forgot password" flow — losing it means manually editing `/opt/n8n/.env` to reset it.
5. **Ask for your Gemini API key and Telegram chat ID** from "Before You Start" above — each is echoed back and asks you to confirm before accepting it, since a typo here fails silently later (no error, notifications/LLM matching just don't work). Leave either blank to skip and set it later (see "Updating these values later" below).
6. Open ports 80/443 via iptables
7. Pull the pre-built image from GitHub Container Registry (`ghcr.io/jatin17solanki/linkedin-automation-n8n:latest` by default — override via `DOCKER_IMAGE` in `deploy/.env` if you've forked the repo and publish your own) and start n8n + Caddy containers
8. Print your n8n URL

All 3 workflow JSONs are already imported into the image (see Part 1, Step 1) — no manual import needed once the container is up.

Shared logic between this and the AWS EC2 script lives in `deploy/setup-common.sh` — only IP autodetection and the walkthrough text are GCP-specific.

### 2.3 — Verify

Open `https://<YOUR_VM_IP>.nip.io` in your browser. You should see the n8n login.

> **If the page doesn't load:**
> - Wait 1-2 minutes for Caddy to get the SSL certificate from Let's Encrypt
> - Check containers: `cd /opt/n8n && sudo docker compose ps`
> - Check logs: `sudo docker compose logs caddy`
> - Make sure HTTP/HTTPS firewall checkboxes were enabled in Step 1.3

---

## Step 3: Configure n8n on the VM

### 3.1 — Set up Google Sheets credential

Same steps as Part 1's **Google Sheets OAuth2** section — the OAuth Client ID setup in Google Cloud Console is identical regardless of where n8n runs. The only difference: the redirect URI n8n shows you here will be `https://<VM_IP>.nip.io/rest/oauth2-credential/callback` instead of the `localhost` one. Use that value in place of the local one; everything else (enabling the Sheets API, OAuth consent screen, Client ID creation, unverified-app warning) is the same.

### 3.2 — Set up Telegram credential

1. **Credentials** → **Add Credential** → search **Telegram**
2. Paste your bot token (from @BotFather)
3. Save

### 3.3 — Connect credentials

1. **Workflows** → open `LinkedIn Job Search V1` (already imported — see Step 2.2)
2. Open each node with a ⚠️ warning → select the correct credential from the dropdown
3. **Enable** the Telegram Trigger node (right-click → Enable)
4. **Disable** the Webhook Trigger node (not needed on cloud)
5. Toggle **Active** (top-right) to start the workflow

### 3.4 — Test

Send your Telegram bot: `/jobs 24`

You should get job listings or "no new openings found."

### 3.5 — Generate an API key (for CI/CD)

1. In n8n: **Settings** (bottom-left) → **API**
2. Click **Create an API Key**
3. Copy it — you'll need it in Step 4

### 3.6 — Optional: turn on the other two workflows

Everything above set up the **main** Job Search workflow. This project ships two more, already imported into your n8n but inactive until you connect them:

- **Company Search** (`/search Oracle 30` — on-demand lookup of one company, with an email report): needs a **second Telegram bot** and a Gmail credential, and — because its only trigger is a Telegram webhook — **can only run on this cloud VM**, not locally. Full steps: [Part 1B](#part-1b-company-search-setup-search--optional). Do them here, in this n8n instance.
- **Job Parser + MCP server** (lets Claude.ai parse LinkedIn job URLs): no credentials needed. Full steps: [Part 1C](#part-1c-job-parser--mcp-server-setup-optional). Point `MCP_WEBHOOK_URL` at `https://<VM_IP>.nip.io/webhook/parse-job`.

---

## Step 4: Set Up GitHub Actions CI/CD

This auto-deploys workflow changes when you push to `main`.

### 4.1 — Generate an SSH key pair

On your **local machine** (not the VM):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gcp_n8n_deploy -C "github-actions" -N ""
```

This creates:
- `~/.ssh/gcp_n8n_deploy` — **private** key (goes to GitHub secrets)
- `~/.ssh/gcp_n8n_deploy.pub` — **public** key (goes to the VM)

**On Windows (PowerShell):**
```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\gcp_n8n_deploy" -C "github-actions" -N ""
```

### 4.2 — Add the public key to the VM

1. **Compute Engine** → **VM instances** → click `n8n-server`
2. Click **Edit**
3. Scroll to **SSH Keys** → **Add Item**
4. Paste the contents of `gcp_n8n_deploy.pub`
5. Note the username that appears (left side) — this is your `GCP_SSH_USER`
6. Click **Save**

### 4.3 — Add secrets to GitHub

Go to your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret | What to paste |
|--------|---------------|
| `GCP_VM_IP` | VM external IP, e.g., `34.71.123.45` |
| `GCP_SSH_PRIVATE_KEY` | Full contents of `~/.ssh/gcp_n8n_deploy` (include `-----BEGIN` and `-----END` lines) |
| `GCP_SSH_USER` | Username from step 4.2 (e.g., `jatin`) |
| `N8N_API_KEY` | API key from step 3.5 |

### 4.4 — Test the pipeline

1. Make any small edit to `n8n_job_search_v1.json`
2. Commit and push to `main`
3. Go to repo → **Actions** tab → watch the "Deploy Workflow to n8n" run
4. Once green, check n8n UI — your change should be reflected

---

## Costs

| Resource | Cost |
|----------|------|
| e2-micro VM (us-central1) | Free |
| 30 GB boot disk | Free |
| Static IP (while VM runs) | Free |
| Egress (< 1 GB/month) | Free |
| nip.io domain | Free |
| Let's Encrypt SSL | Free |
| **Total** | **$0/month** |

---

## Maintenance Commands

```bash
# SSH into VM
gcloud compute ssh n8n-server --zone=us-central1-a

# Check status
cd /opt/n8n && sudo docker compose ps

# View logs
sudo docker compose logs -f --tail=50

# Restart everything
sudo docker compose restart

# Pull the latest published image and recreate the container
sudo docker compose pull n8n && sudo docker compose up -d
```

---
---

# Part 3: Production Deployment (AWS EC2)

Deploy n8n to a free-tier AWS EC2 VM with HTTPS and GitHub Actions CI/CD — the same architecture as Part 2 (GCP), just a different cloud. Pick **one** of Part 2 or Part 3, not both, unless you deliberately want two separate deployments (that needs a second copy of `.github/workflows/deploy.yml` under a different name, since the shipped one only targets one VM at a time — not covered here).

## Architecture

```
Internet → Caddy (auto-HTTPS via nip.io, :443) → n8n (:5678) → SQLite (Docker volume)
```

- **VM:** AWS EC2 `t2.micro` or `t3.micro` (1 GB RAM — same class as GCP's e2-micro), Ubuntu 22.04 LTS
- **Domain:** `<VM_IP>.nip.io` (free wildcard DNS, no registration)
- **HTTPS:** Let's Encrypt via Caddy (fully automatic)

> **Cost difference from GCP, read before you start:** GCP's e2-micro can be free indefinitely (1 instance/month in an eligible region), but only once you've upgraded that account out of its 90-day Free Trial (see Part 2's note above) — AWS has no equivalent "upgrade" step to unlock an indefinite tier. AWS's free tier for `t2.micro`/`t3.micro` is **750 hours/month for the first 12 months only, full stop**, after which normal hourly billing applies (a few dollars/month for this instance class) unless you stop/terminate it. Set a calendar reminder. See **Costs** below for more detail, including a public-IPv4 charge AWS introduced in 2024 that GCP doesn't have an equivalent of.

---

## Before You Start — Gather These

Same two values as Part 2 (GCP) — the setup script asks for them in Step 2.2:

| What | Where to get it | Notes |
|------|------------------|-------|
| **Gemini API key** | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Free, no billing account needed. Powers the resume-matching % in your notifications. |
| **Telegram chat ID** | Message **@userinfobot** on Telegram | Numeric user ID — where notifications get sent, separate from the bot token below. |

You'll also need a Telegram **bot** (for Step 3 below) — @BotFather → `/newbot`, save the token. **Message your new bot once** (e.g. `/start`) — bots can't message you first, and skipping this causes a "chat not found" error later even with a correct token/chat ID.

You can leave either of the first two blank at the setup script's prompt and set them later (see Part 2's "Updating these values later").

> **New AWS account?** A brand-new account is often placed under a verification hold ("Your account is pending verification... may take up to 2 days") that can block EC2 instance launches entirely — this has nothing to do with this project, it's a standard AWS anti-fraud check. There's no status tracker for it beyond opening a free Support Case (Account and Billing) if it drags past 48 hours. Confirm you can actually launch a `t2.micro` before working through the rest of this section.

---

## Step 1: Create the EC2 VM

### 1.1 — Sign in to the AWS Console

Go to [console.aws.amazon.com](https://console.aws.amazon.com) and sign in (or create an account — requires a credit card even for free-tier usage, unlike GCP's trial).

Pick a region in the top-right corner (e.g. `us-east-1`) — note it down, you'll need it for later CLI/SSH commands and to find your instance again.

### 1.2 — Launch the instance

Go to **EC2** → **Instances** → **Launch instances**, and fill in:

| Setting | Value |
|---------|-------|
| Name | `n8n-server` |
| AMI | **Ubuntu Server 22.04 LTS** (search "Ubuntu" in Quick Start — pick the 64-bit x86 free-tier-eligible one) |
| Instance type | **t2.micro** or **t3.micro** — whichever is marked "Free tier eligible" in your region (usually both) |
| Key pair | Click **Create new key pair** → name it `n8n-ec2-key` → type **ED25519** → format **.pem** → **Create key pair** (this downloads the private key — save it somewhere durable, e.g. `~/.ssh/n8n-ec2-key.pem`; AWS never shows it again) |
| Network settings | Click **Edit** — see Step 1.3 below before launching |
| Storage | 30 GB **gp3** (default is usually 8GB — increase it; still within the free tier's 30GB EBS allowance) |

### 1.3 — Configure the Security Group (this is the AWS-specific step — GCP has no equivalent)

Unlike GCP, where iptables + the "Allow HTTP/HTTPS" checkboxes are enough, **AWS EC2 traffic is gated by a Security Group first** — `setup-aws.sh` opening ports via iptables on the VM itself does nothing if the Security Group blocks the traffic before it even reaches the VM. Under **Network settings** → **Edit**, create a security group with these inbound rules:

| Type | Protocol | Port | Source | Why |
|------|----------|------|--------|-----|
| SSH | TCP | 22 | **My IP** (recommended) or `0.0.0.0/0` | So you can SSH in. "My IP" is safer — Anywhere works if your home/office IP changes often |
| HTTP | TCP | 80 | `0.0.0.0/0` (Anywhere) | Required for Let's Encrypt's HTTP challenge and Caddy's redirect to HTTPS |
| HTTPS | TCP | 443 | `0.0.0.0/0` (Anywhere) | The actual n8n traffic, once Caddy has HTTPS working |

Click **Launch instance**.

### 1.4 — Allocate an Elastic IP (strongly recommended)

By default, an EC2 instance's public IP **changes every time you stop and start it** (a plain reboot is fine, it's stop/start that changes it). Since this project's HTTPS domain (`<VM_IP>.nip.io`) and Caddy config are tied to that IP, an IP change means redoing setup. Avoid this:

1. **EC2** → **Elastic IPs** → **Allocate Elastic IP address** → **Allocate**
2. Select the new address → **Actions** → **Associate Elastic IP address** → choose your `n8n-server` instance → **Associate**
3. This is now your stable `VM_IP` — write it down

> **Cost note:** an Elastic IP is free **only while associated with a running instance**. If you stop the instance but keep the IP allocated, or leave it unassociated, AWS bills it hourly. Release it (**Actions** → **Release Elastic IP address**) if you ever terminate the instance for good.

### 1.5 — Note your public IP

Find it on the **Instances** page (or the Elastic IP you just allocated) — e.g. `54.123.45.67`.

---

## Step 2: Set Up the VM

### 2.1 — SSH into the VM

```bash
chmod 600 ~/.ssh/n8n-ec2-key.pem   # required, AWS/SSH rejects overly-open key file permissions
ssh -i ~/.ssh/n8n-ec2-key.pem ubuntu@<YOUR_VM_IP>
```

The default username for Ubuntu AMIs is `ubuntu` (not your AWS account name — this trips up first-time EC2 users coming from GCP, where the SSH username is derived from your Google account).

### 2.2 — Clone and run setup

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO
sudo bash deploy/setup-aws.sh
```

The script will:
1. Install Docker and Docker Compose
2. Set up a 2GB swapfile if none is active yet (required on the 1GB-RAM `t2.micro`/`t3.micro` — see `TROUBLESHOOTING.md`; set `LOW_MEMORY=false` before the command above to skip this on a larger instance)
3. Create the Docker volumes n8n/Caddy data lives in
4. **Ask for n8n username and password** (protects the web UI) — **save these somewhere durable** (password manager, not just your terminal scrollback). This is your login for `https://<VM_IP>.nip.io` once the stack is up, it's not shown again after this prompt, and there's no "forgot password" flow.
5. **Ask for your Gemini API key and Telegram chat ID** from "Before You Start" above — each is echoed back and asks you to confirm before accepting it, since a typo here fails silently later. Leave either blank to skip and set it later (see Part 2's "Updating these values later").
6. Open ports 80/443 via iptables **on the VM itself** — this is in addition to, not instead of, the Security Group you configured in Step 1.3. Both must allow the traffic
7. Pull the pre-built image from GitHub Container Registry and start n8n + Caddy containers
8. Print your n8n URL

All 3 workflow JSONs are already imported into the image (see Part 1, Step 1) — no manual import needed once the container is up.

Shared logic between this and the GCP script lives in `deploy/setup-common.sh` — only IP autodetection (EC2's IMDSv2 metadata service here, vs. GCP's metadata server) and the walkthrough text are AWS-specific.

### 2.3 — Verify

Open `https://<YOUR_VM_IP>.nip.io` in your browser. You should see the n8n login.

> **If the page doesn't load:**
> - Wait 1-2 minutes for Caddy to get the SSL certificate from Let's Encrypt
> - Check containers: `cd /opt/n8n && sudo docker compose ps`
> - Check logs: `sudo docker compose logs caddy`
> - **Double-check the Security Group** (Step 1.3) — this is the #1 AWS-specific cause of "nothing loads" that doesn't exist on GCP. `sudo docker compose ps` showing healthy containers but the browser timing out almost always means the Security Group, not Caddy/n8n, is the problem

---

## Step 3: Configure n8n on the VM

Identical to [Part 2, Step 3](#step-3-configure-n8n-on-the-vm) — Google Sheets/Telegram credential setup, connecting credentials to nodes, enabling the Telegram Trigger, and generating an API key all work exactly the same regardless of which cloud n8n runs on. The only value that differs is the redirect URI n8n shows for the Google Sheets OAuth2 credential, which will use your AWS VM's IP: `https://<VM_IP>.nip.io/rest/oauth2-credential/callback`.

**Also on this VM — the other two workflows** (already imported, inactive until you connect them): [Part 2, Step 3.6](#36--optional-turn-on-the-other-two-workflows) explains them. **Company Search** (`/search`) in particular can *only* run on a cloud VM like this one, so this is where you set it up — follow [Part 1B](#part-1b-company-search-setup-search--optional) in this n8n instance.

---

## Step 4: Set Up GitHub Actions CI/CD

Same flow as [Part 2, Step 4](#step-4-set-up-github-actions-cicd) — generate an SSH key pair, add the public half to the VM, add secrets to GitHub, push a change to test it.

**One naming gotcha:** `.github/workflows/deploy.yml`'s secrets are still named `GCP_VM_IP`/`GCP_SSH_USER`/`GCP_SSH_PRIVATE_KEY` — that's a legacy name from when this project only supported GCP, not a sign you're doing something wrong. Use those exact secret names in GitHub even though your VM is on AWS; the workflow doesn't care which cloud the IP/user/key actually point at.

1. Generate a fresh SSH key pair for CI/CD (don't reuse your EC2 key pair from Step 1.2 — keep the human-login key and the CI/CD key separate):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/aws_n8n_deploy -C "github-actions" -N ""
   ```
2. Add the public key (`~/.ssh/aws_n8n_deploy.pub`) to the VM's `~/.ssh/authorized_keys` (as the `ubuntu` user):
   ```bash
   ssh-copy-id -i ~/.ssh/aws_n8n_deploy.pub -o IdentityFile=~/.ssh/n8n-ec2-key.pem ubuntu@<YOUR_VM_IP>
   ```
3. Add these secrets in your repo → **Settings** → **Secrets and variables** → **Actions**:

   | Secret | What to paste |
   |--------|---------------|
   | `GCP_VM_IP` | Your EC2 instance's (Elastic) IP, e.g., `54.123.45.67` |
   | `GCP_SSH_PRIVATE_KEY` | Full contents of `~/.ssh/aws_n8n_deploy` (include `-----BEGIN`/`-----END` lines) |
   | `GCP_SSH_USER` | `ubuntu` |
   | `N8N_API_KEY` | API key from Step 3's equivalent of Part 2's 3.5 |

4. Test: edit any of the 3 workflow JSONs, commit, push to `main`, watch the **Actions** tab.

---

## Costs

| Resource | Cost |
|----------|------|
| `t2.micro`/`t3.micro` instance | Free for 750 hrs/month during your **first 12 months** only — after that, standard hourly billing applies (check the current [EC2 pricing page](https://aws.amazon.com/ec2/pricing/on-demand/) for your region) |
| 30 GB gp3 EBS storage | Free tier covers up to 30GB — matches what this guide provisions |
| Elastic IP (while associated with a running instance) | Free |
| Elastic IP (unassociated, or instance stopped) | Billed hourly — release it if not in active use |
| Public IPv4 address | AWS began charging a small hourly fee for public IPv4 addresses in 2024; this is typically covered by free-tier allowances during your first 12 months, but **verify current terms in the AWS Billing console** — this is the one AWS-specific cost GCP's e2-micro path doesn't have |
| Data transfer out | Free tier covers ~100GB/month — this workflow's traffic is far below that |
| nip.io domain | Free |
| Let's Encrypt SSL | Free |

**Unlike Part 2's GCP path, this is not a genuinely indefinite $0/month setup** — budget for either migrating off `t2.micro`/`t3.micro` pricing after 12 months, or terminating the instance before then if you're done testing.

---

## Maintenance Commands

```bash
# SSH into VM
ssh -i ~/.ssh/n8n-ec2-key.pem ubuntu@<YOUR_VM_IP>

# Check status
cd /opt/n8n && sudo docker compose ps

# View logs
sudo docker compose logs -f --tail=50

# Restart everything
sudo docker compose restart

# Pull the latest published image and recreate the container
sudo docker compose pull n8n && sudo docker compose up -d
```
