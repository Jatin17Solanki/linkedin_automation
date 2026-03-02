# CLAUDE.md — LinkedIn Job Search n8n Workflow Context

## What This Is
An n8n automation workflow (`n8n_job_search_v1.json`) that searches LinkedIn's public job pages for target companies, filters results, logs to Google Sheets, and sends Telegram notifications. Built for Jatin's job search targeting mid-level backend/full-stack roles (3.5 years experience) in India.

## File Location
The workflow JSON is at: `n8n_job_search_v1.json` (in the same directory as this file)
It was generated via a Python script and has 26 functional nodes.

## Architecture Overview

```
Schedule (7AM/7PM) OR Manual Trigger
  → Read Config (Google Sheet "Config" tab — list of companies + buckets)
  → Read Results (Google Sheet "Results" tab — for dedup)
  → Build Search URLs (Code node — builds 4 LinkedIn URLs from config)
  → Loop Over URLs
    → Fetch Search Page (HTTP GET to LinkedIn public search)
    → Extract Links & Titles (HTML parse)
    → Filter & Accumulate Links (Code — negative title filter + dedup)
  → Output New Job Links
  → Loop Over Jobs
    → Fetch Job Detail (HTTP GET individual job page)
    → Parse Job Details (HTML parse — title, company, location, description)
    → Process & Filter Job (Code — experience extraction, tagging)
    → Is Valid Job? (IF node)
      → YES: Append to Results sheet
      → NO: Skip, continue loop
  → Read Unnotified (get jobs where Notified != TRUE)
  → Format Telegram
  → Has New Jobs? (IF node)
    → YES: Send Telegram + Mark Jobs Notified
    → NO: (currently does nothing — see bug #2)
```

## 4 Search Buckets

| Bucket | Title Pattern                 | Negative "senior" filter?                                           | Companies                                                                                                                                                                                                                                                                                                                                                                                  |
| ------ | ----------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1      | SDE II / Software Engineer II | YES — excludes "senior"                                             | Amazon(1586), Flipkart(321062), Expedia(2751), Zeta(10355561), InMobi(272972), Slice(30246063), Groww(10813156), Akamai(3925), Wayfair(19857), Rippling(17988315), Intuit(1666), Microsoft(1035)                                                                                                                                                                                           |
| 2      | Level 3 / III                 | YES — excludes "senior"                                             | Oracle(1028), Google(1441), Walmart(9390173), eBay(1481)                                                                                                                                                                                                                                                                                                                                   |
| 3      | Generic (Large Tech)          | NO — allows "senior" (Myntra/PayPal/MMT use "Senior" for mid-level) | Adobe(1480), Salesforce(3185), Myntra(361348), PayPal(1482), MMT(35113), PhonePe(10479149), Apple(162479), Meta(10667), LinkedIn(1337), Netflix(165158), Uber(1815218), Databricks(3477522)                                                                                                                                                                                                |
| 4      | Generic (Others)              | NO — allows "senior"                                                | Atlassian(22688), Nvidia(3608), Airbnb(309694), Confluent(88873), ServiceNow(29352), Workday(17719), Rubrik(4840301), Slack(1612748), Nutanix(735085), OpenTable(12181), Observe.ai(18090845), Acko(13250135), Upstox(15091079), Cred(14485479), SuperMoney(13244834), ClearTax(74474022), Blinkit(80918929), Directi(29570), DeShaw(6508), Kotak(5632), ClearTrip(62902), Swiggy(9252341) |

## LinkedIn URL Construction

Each bucket generates a URL like:
```
https://www.linkedin.com/jobs/search/?keywords=<encoded_boolean_query>&f_C=<comma_separated_ids>&f_TPR=r43200&location=India&sortBy=DD
```

- `f_TPR=r43200` = past 12 hours (43200 seconds)
- `f_C` = comma-separated LinkedIn company IDs
- Keywords use Boolean: `"SDE II" OR "SDE 2" OR ...`
- Bucket 1 & 2 keywords include `AND NOT ("senior" OR "staff" OR ...)`
- Bucket 3 & 4 keywords only exclude staff/manager/etc, NOT senior

## Negative Title Filters (regex in "Filter & Accumulate Links" node)

Applied to all buckets: staff, principal, lead, manager, director, ios, android, machine learning, data science, QA, SDET, devops, SRE, frontend, intern, test engineer, platform engineer, infra engineer, cloud engineer, security, mobile, embedded

Additionally for Buckets 1 & 2 only: senior, sr.

## Experience Filter (in "Process & Filter Job" node)

Regex-based extraction from job description. Skips roles requiring >5 years.
Patterns: "3+ years", "3-5 years", "minimum 3 years", "at least 3 years", etc.

## Google Sheet Schema

**Config tab** (input — user editable):
| Company | CompanyID | Bucket | Active | Notes |

**Results tab** (output — workflow writes here):
| JobID | Title | Company | Location | Link | ExperienceReq | PrimaryTag | FirstSeen | Notified | Score | Status |

Sheet ID: `1i4eS-2TNhMJyY5JoTZhTrkXrn49xW0MbxpeaQ4NmHvc`

## Credentials (placeholder IDs in JSON — user connects manually in n8n UI)

- Google Sheets OAuth2: credential ID = "CONFIGURE_ME"
- Telegram Bot Token: `8531111376:AAFXW5sueSWGkd3ejJ0RX2NDtowfbVx-9e8`
- Telegram Chat ID: `951213350`

## Known Bugs To Fix

### Bug 1: Job ID extraction regex fails (CRITICAL)
**Node:** "Filter & Accumulate Links"
**Problem:** The regex expects job ID to be followed by a slash in the URL, but LinkedIn URLs look like:
```
https://www.linkedin.com/jobs/view/role-name-JOBID?position=...
```
NOT:
```
https://www.linkedin.com/jobs/view/JOBID/
```
The job ID comes after the role-name slug with a hyphen, followed by `?` query params. Because of this, jobId extracts as null, so ALL jobs fail the filter and nothing gets output.

**Fix needed:** Update the regex to correctly extract the numeric job ID from URLs like:
`https://www.linkedin.com/jobs/view/software-engineer-ii-at-amazon-3847291056?position=1&pageNum=0`
The job ID here is `3847291056` — the last numeric segment before `?`.

**User will provide actual URL samples** when starting the Claude Code session so you can see the exact format.

### Bug 2: No "zero results" Telegram notification
**Node:** "Has New Jobs?" IF node
**Problem:** When no new jobs are found, the FALSE branch goes nowhere. User wants a Telegram message saying "No new openings found this run" so they know the workflow executed successfully.
**Fix:** Add a code node + Telegram send on the FALSE branch of "Has New Jobs?" that sends a brief "no results" message.

## Design Principles
- Config-driven: Companies and buckets read from Google Sheet, not hardcoded
- Extensible: Schema supports future V2 columns (Score for LLM matching)
- Dedup: By JobID against Results sheet before fetching job details
- Rate limiting: 8-second wait between job detail fetches
- Honest filtering: Never fabricate matches. If experience can't be parsed, pass it through as "Not specified"

## V2 Roadmap (not in scope now)
- LLM scoring (Gemini Flash free tier)
- Webhook trigger for phone
- Auto resume customization
- Cloud deployment (GCP e2-micro)