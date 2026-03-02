# LinkedIn Job Search V1 — Setup Guide

> **Local development** setup is below. For **production deployment to GCP**, see [Part 2: Production Deployment](#part-2-production-deployment-gcp-e2-micro) further down.

## Prerequisites
- Docker Desktop running
- Google account (for Sheets)
- Telegram (bot already created)

---

## Step 1: Start n8n

```bash
mkdir -p ~/n8n-job-search
cd ~/n8n-job-search
# Copy docker-compose.yml here
docker compose up -d
```

Open: **http://localhost:5678**  
First time: Create an owner account (email + password). Local only.

---

## Step 2: Set Up Google Sheet

Open: https://docs.google.com/spreadsheets/d/1i4eS-2TNhMJyY5JoTZhTrkXrn49xW0MbxpeaQ4NmHvc

### Tab 1: "Config"
Rename default "Sheet1" to **Config**. Headers in Row 1:

| Company | CompanyID | Bucket | Active | Notes |

Paste the data from `config_data.csv`.

### Tab 2: "Results"
Create new tab **Results**. Headers in Row 1:

| JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status |

---

## Step 3: Configure Credentials in n8n

### Google Sheets OAuth2
1. Settings → Credentials → Add Credential
2. Search "Google Sheets" → select OAuth2
3. Click "Sign in with Google" → authorize
4. Save

### Telegram Bot
1. Settings → Credentials → Add Credential  
2. Search "Telegram"
3. Paste your Bot Token (get it from @BotFather on Telegram)
4. Save

---

## Step 4: Import Workflow

1. Workflows → Import from file
2. Select `n8n_job_search_v1.json`

---

## Step 5: Connect Credentials to Nodes

Each node with ⚠️ needs credentials linked:

**Google Sheets credential** → Read Config, Read Results, Append to Results, Read Unnotified, Update Notified Status  
**Telegram credential** → Send Telegram

Double-click node → select credential from dropdown → close.

---

## Step 6: Verify Sheet Connection

1. Double-click "Read Config" → verify Sheet Name = "Config" → Test step
2. Double-click "Read Results" → verify Sheet Name = "Results" → Test step

---

## Step 7: First Test Run

1. Click "Test workflow" (top right)
2. Watch nodes light up green
3. **For first test:** Edit "Build Search URLs" → change `TIME_WINDOW_SECONDS = 2592000` (30 days) to get results
4. Change back to `43200` after testing

---

## Step 8: Activate

Toggle "Active" switch → ON. Runs at 7 AM & 7 PM IST automatically.

---

## Instant/Ad-hoc Run

**Quick run:** Click "Test workflow" in editor (uses current TIME_WINDOW).

**Custom time window:** Edit "Build Search URLs" → change TIME_WINDOW_SECONDS:
- 7200 = 2 hours
- 14400 = 4 hours  
- 28800 = 8 hours
- 43200 = 12 hours (default)

Run, then change back.

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
3. Start n8n + Caddy containers
4. Print your n8n URL

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

1. In n8n: **Credentials** → **Add Credential** → search **Google Sheets OAuth2**
2. You'll see a **OAuth Redirect URL** — copy it
3. In [Google Cloud Console](https://console.cloud.google.com):
   - **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth Client ID**
   - Type: **Web application**
   - Authorized redirect URIs: paste the URI from n8n
4. Copy **Client ID** and **Client Secret** back into n8n
5. Click **Sign in with Google** → authorize → **Save**

### 3.2 — Set up Telegram credential

1. **Credentials** → **Add Credential** → search **Telegram**
2. Paste your bot token (from @BotFather)
3. Save

### 3.3 — Import workflow + connect credentials

1. **Workflows** → import `n8n_job_search_v1.json`
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

# Update n8n to latest
sudo docker compose pull n8n && sudo docker compose up -d
```
