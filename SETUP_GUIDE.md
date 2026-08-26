# LinkedIn Job Search V1 — Setup Guide

> **Local development** setup is below. For **production deployment to GCP**, see [Part 2: Production Deployment](#part-2-production-deployment-gcp-e2-micro) further down.

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
| `VM_IP` | — | — | Set by `deploy/setup.sh`; used for the `nip.io` HTTPS domain |
| `DOCKER_IMAGE` | — | `ghcr.io/jatin17solanki/linkedin-automation-n8n:latest` | Pre-built image to pull for production; override if you've forked the repo and publish your own |
| `N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD` | — | — | Protects the n8n web UI on cloud deployments |
| `MCP_WEBHOOK_URL` | — | *(none — required for the MCP server)* | Base URL the `parse-linkedin-job` MCP tool calls |

Set env vars in `deploy/.env` (copy from `deploy/.env.example`) for cloud deployments, or pass them as `environment:` values in `docker-compose.yml` for local dev. `n8n_company_search_v1.json` (the on-demand `/search` workflow) uses the same Settings tab and precedence — both workflows stay in sync.

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

# Part 2: Production Deployment (GCP e2-micro)

Deploy n8n to a free GCP VM with HTTPS (needed for Telegram Trigger) and GitHub Actions CI/CD.

## Architecture

```
Internet → Caddy (auto-HTTPS via nip.io, :443) → n8n (:5678) → SQLite (Docker volume)
```

- **VM:** GCP e2-micro, Ubuntu 22.04, us-central1-a (always-free tier)
- **Domain:** `<VM_IP>.nip.io` (free wildcard DNS, no registration)
- **HTTPS:** Let's Encrypt via Caddy (fully automatic)
- **Cost:** $0/month (within GCP free tier)

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
sudo bash deploy/setup.sh
```

The script will:
1. Install Docker and Docker Compose
2. Ask for n8n username and password (protects the web UI)
3. Pull the pre-built image from GitHub Container Registry (`ghcr.io/jatin17solanki/linkedin-automation-n8n:latest` by default — override via `DOCKER_IMAGE` in `deploy/.env` if you've forked the repo and publish your own) and start n8n + Caddy containers
4. Print your n8n URL

All 3 workflow JSONs are already imported into the image (see Part 1, Step 1) — no manual import needed once the container is up.

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
