# LinkedIn Job Search V1 — Setup Guide

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

Open: https://docs.google.com/spreadsheets/d/YOUR_GOOGLE_SHEET_DOCUMENT_ID

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
3. Paste Bot Token: `YOUR_TELEGRAM_BOT_TOKEN`
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
