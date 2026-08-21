# LinkedIn Job Search Automation

n8n workflows that automatically search LinkedIn for job openings at target companies, filter by experience level, score each role against your resume using Gemini Flash, and notify you via Telegram with match percentages.

## How It Works
[View detailed architecture →](https://jatin17solanki.github.io/linkedin_automation/)

<br>

<img width="1375" height="455" alt="image" src="https://github.com/user-attachments/assets/b87a7269-584b-47bd-8cbc-2d28f6753763" />

<br>

**Three workflows:**

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| **Job Search** (`n8n_job_search_v1.json`) | Cron 7AM/7PM or `/jobs N` | Scheduled search across all companies, dedup, sheet logging |
| **Company Search** (`n8n_company_search_v1.json`) | `/search Oracle 30` | On-demand single-company search with detailed email report |
| **Job Parser** (`n8n_job_parser_v1.json`) | POST `/webhook/parse-job` | Stateless API for parsing a single LinkedIn job page |

**MCP Server** (`mcp-server/`) exposes the job parser as a tool for Claude.ai.

## Features

- **Config-driven** - companies and search buckets managed in Google Sheets, not code
- **Smart filtering** - negative title filters (staff, QA, devops, etc.) + experience threshold (skips >4 yrs)
- **LLM matching** - Gemini 2.5 Flash scores each job against your resume (skills 40%, experience 30%, domain 20%, seniority 10%)
- **Color-coded Telegram** - sorted by match %: green >= 70%, yellow 50-69%, red < 50%
- **Dedup** - tracks seen jobs by ID in Google Sheets, never notifies twice
- **Rate limiting** - wait nodes between fetches to avoid LinkedIn throttling
- **Graceful fallback** - if LLM fails, sends plain Telegram format with warning

## Quick Start

### Prerequisites

- [n8n](https://n8n.io) instance (local or cloud)
- Google account with Sheets API access
- Telegram bot (create via [@BotFather](https://t.me/BotFather))
- [Gemini API key](https://aistudio.google.com/apikey) (free tier)

### Setup

1. **Start n8n** — `docker compose up -d --build` (builds this repo's `Dockerfile`, which auto-imports all 3 workflow JSONs on first start). Using a different n8n instance? Import `n8n_job_search_v1.json` manually instead.

2. **Google Sheet** - create a blank sheet, then either:
   - **Automated:** paste [`examples/google-sheet/bootstrap.gs`](examples/google-sheet/bootstrap.gs) into Extensions → Apps Script and run it once — creates all three tabs, pre-fills Config with the example company list and Resume with placeholder values for you to edit.
   - **Manual:** create three tabs by hand and paste in the matching template from [`examples/google-sheet/`](examples/google-sheet/):

     | Tab | Columns | Template |
     |-----|---------|----------|
     | Config | Company, CompanyID, Bucket, Active, Notes | [`config_data.csv`](examples/google-sheet/config_data.csv) |
     | Results | JobID, Title, Company, Location, Link, ExperienceReq, PrimaryTag, FirstSeen, Notified, Score, Status | [`results_template.csv`](examples/google-sheet/results_template.csv) (headers only — the workflow writes rows here) |
     | Resume | Key, Value (your profile as key-value pairs) | [`resume_template.csv`](examples/google-sheet/resume_template.csv) |

3. **Connect credentials** in n8n UI:
   - Google Sheets OAuth2
   - Telegram Bot token
   - Set `GEMINI_API_KEY` as environment variable (or hardcode in Call Gemini Flash node)

4. **Update** Telegram `chatId` in Send Telegram / Send No Results Telegram nodes

5. **Activate** the workflow and test with Manual Trigger

### Company Config

Add companies to the Config sheet with their [LinkedIn Company ID](https://www.linkedin.com/company/amazon/) and a bucket number:

| Bucket | Search Pattern | Filters "Senior"? |
|--------|---------------|-------------------|
| 1 | SDE II / Software Engineer II | Yes |
| 2 | Level 3 / III | Yes |
| 3 | Generic (large tech) | No |
| 4 | Generic (others) | No |

## Production Deployment

Runs on a GCP e2-micro (always-free tier) with Caddy for auto-HTTPS:

```
Internet --> Caddy (:443, nip.io) --> n8n (:5678) --> SQLite
```

```bash
# On a fresh Ubuntu 22.04 VM:
git clone <repo> && cd linkedin_automation
sudo bash deploy/setup.sh
# Then: open https://<VM_IP>.nip.io, connect credentials (workflows are pre-imported)
```

GitHub Actions auto-deploys workflow changes on push to main.

## MCP Server

The `mcp-server/` directory contains a Node.js MCP server that exposes the job parser webhook as a `parse-linkedin-job` tool for Claude.ai.

```bash
cd mcp-server && npm install
```

Add to Claude Desktop config:
```json
{
  "mcpServers": {
    "linkedin-job-parser": {
      "command": "node",
      "args": ["/path/to/mcp-server/index.js"]
    }
  }
}
```

## Project Structure

```
n8n_job_search_v1.json      # Main scheduled job search workflow (37 nodes)
n8n_company_search_v1.json  # On-demand /search workflow (30 nodes)
n8n_job_parser_v1.json      # Job parser webhook (8 nodes)
mcp-server/                 # MCP server for Claude.ai integration
Dockerfile                  # Auto-imports the 3 workflow JSONs on first start
docker/                     # Import entrypoint script
deploy/                     # Docker Compose, Caddy, setup scripts
.github/workflows/          # CI/CD pipeline
CLAUDE.md                   # Detailed technical reference (for AI)
```

## License

MIT
