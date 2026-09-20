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
- **Smart filtering** - negative title filters (staff, QA, devops, etc.) + experience-range matching against the bracket you're targeting (`min_experience_years`-`max_experience_years`) — see "Experience Range Filtering" below
- **LLM matching** - Gemini 2.5 Flash scores each job against your resume (skills 40%, experience 30%, domain 20%, seniority 10%)
- **Color-coded Telegram** - sorted by match %: green >= 70%, yellow 50-69%, red < 50%, with an optional `min_match_percent` to hide low-scoring roles entirely
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
   - **Automated:** paste [`examples/google-sheet/bootstrap.gs`](examples/google-sheet/bootstrap.gs) into Extensions → Apps Script and run it once — creates all four tabs, pre-fills Config with the example company list, Settings with working defaults, and Resume with placeholder values for you to edit.
   - **Manual:** create four tabs by hand and paste in the matching template from [`examples/google-sheet/`](examples/google-sheet/):

     | Tab | Columns | Template |
     |-----|---------|----------|
     | Config | Company, CompanyID, Bucket, Active, Notes | [`config_data.csv`](examples/google-sheet/config_data.csv) |
     | Results | JobID, Title, Company, Location, Link, ExperienceReq, PrimaryTag, FirstSeen, Notified, Score, Status | [`results_template.csv`](examples/google-sheet/results_template.csv) (headers only — the workflow writes rows here) |
     | Settings | Key, Value (location/experience/match-threshold overrides, plus `notify_email` for Company Search's email digest) | [`settings_template.csv`](examples/google-sheet/settings_template.csv) — edit anytime, no restart needed; blank a value to fall back to its env var |
     | Resume | Key, Value (your profile as key-value pairs) | [`resume_template.csv`](examples/google-sheet/resume_template.csv) |

   **Filling in the Resume tab from your actual resume:** typing 12 key/value rows by hand is tedious and easy to get wrong. Instead, give the prompt below (with your resume attached or pasted) to any LLM — it's not tied to a specific model or tool — and it'll return JSON in a single code block — click the block's copy button and paste it **between the two backticks** on the `var RESUME_JSON` line of `bootstrap.gs` (keep those backticks, and don't paste the opening/closing fence lines) before running it, which populates the Resume tab for you in the exact shape the workflow expects. Skip this and use the placeholder values from `resume_template.csv` if you'd rather fill it in by hand.

   <details>
   <summary>Resume → Sheet prompt (click to expand)</summary>

   ```
   Convert the attached/pasted resume into a JSON object with exactly these
   keys, and nothing else: name, title, years_experience, target_roles,
   skills_languages, skills_frameworks, skills_databases, skills_cloud,
   skills_other, experience_summary, education, highlights.

   Rules:
   - Reply with the JSON object inside ONE code block (start the block with
     ```json and end it with ```) so it can be copied with one click, and
     write nothing outside that block.
   - Do not put backtick characters or the two characters ${ inside any value.
   - All values are strings, except years_experience (a number, e.g. 3.5).
   - target_roles, skills_languages, skills_frameworks, skills_databases,
     skills_cloud, skills_other: comma-separated strings, not arrays.
   - experience_summary: 2-4 sentences covering key roles, scope, and
     quantified impact (numbers/metrics where the resume has them).
   - highlights: 3-5 semicolon-separated standout achievements.
   - education: one line — degree, institution, year.
   - Do NOT include phone number, email address, or social/portfolio links in
     any field, even if present in the resume — this data may end up in a
     spreadsheet that isn't strictly private, and none of it is needed for
     job matching.
   - If a field genuinely can't be determined from the resume, use an empty
     string for it rather than guessing or inventing content.

   Resume:
   [paste resume text here, or attach the file if your LLM supports it]
   ```

   </details>

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

### Location

Defaults to Bengaluru. Set via the Settings tab (`location_geo_id`/`location_f_pp`/`location_city_names`) or matching env vars — see `SETUP_GUIDE.md`. Supports multiple cities at once (comma-separated); `SETUP_GUIDE.md`'s "Adding multiple cities" has the exact fields to change, how to find a city's LinkedIn place ID, and a table of already-known IDs (Bengaluru, Mumbai, Hyderabad, Gurugram) so you don't have to re-derive them.

### Experience Range Filtering

`min_experience_years`/`max_experience_years` (Settings tab or env vars, see `SETUP_GUIDE.md`) describe **the experience bracket you're targeting** — e.g. "3 to 5 years." A role matches if its own stated range overlaps your bracket at all, touching boundaries included: a "2-4 years" posting matches a `3-5` target, and so does an open-ended "5+ years" posting (no stated ceiling means it always satisfies the upper-bound check). Only a role whose range falls entirely outside your bracket — e.g. "8+ years" against a `3-5` target — gets rejected.

This is intentionally permissive: borderline/adjacent postings are shown rather than dropped, on the theory that a false positive (one extra role to glance at and skip) costs less than a false negative (a real match silently never shown). Defaults are `min_experience_years=0` (no floor) and `max_experience_years=4`, which reproduces the original single-ceiling behavior exactly for anyone not using the Settings tab. If a role's experience can't be parsed from its description at all, it always passes through unfiltered rather than being guessed at (see `CLAUDE.md`'s "Honest filtering" design principle).

### Title/Seniority Filters (hardcoded, not env-configurable)

Unlike location/experience (env vars — see `SETUP_GUIDE.md`), the negative-title filter and the 4 bucket keyword templates are plain JS regex inside specific Code nodes, not parameterized. This was a deliberate choice (kept simple over configurable), but worth knowing if you want to change what gets filtered:

- **Negative filter** — node `Filter & Accumulate Links` (main workflow) / `Filter Links` (company search): excludes titles matching `staff|principal|lead|manager|director|ios|android|machine learning|data science|QA|SDET|devops|SRE|frontend|intern|test engineer|platform engineer|infra engineer|cloud engineer|security|mobile|embedded`. Buckets 1 & 2 additionally exclude `senior|sr`.
- **Bucket keyword templates** (what counts as a "SDE II" vs "Level 3" vs generic search) — node `Build Search URLs` / `Build Search URL`.

To change either: edit the regex/keyword string directly in the Code node, in **both** `n8n_job_search_v1.json` and `n8n_company_search_v1.json`, since this logic is intentionally duplicated rather than shared (see the workflows' own design notes) — an edit in only one file will make the two workflows disagree on what counts as a match.

## Production Deployment

Runs on a free-tier GCP e2-micro or AWS EC2 t2.micro/t3.micro VM with Caddy for auto-HTTPS:

```
Internet --> Caddy (:443, nip.io) --> n8n (:5678) --> SQLite
```

```bash
# On a fresh Ubuntu 22.04 VM:
git clone <repo> && cd linkedin_automation
sudo bash deploy/setup-gcp.sh   # or deploy/setup-aws.sh on AWS EC2
# Then: open https://<VM_IP>.nip.io, connect credentials (workflows are pre-imported)
```

See `SETUP_GUIDE.md` Part 2 (GCP) or Part 3 (AWS) for the full VM provisioning walkthrough. Both scripts prompt interactively for your Gemini API key and Telegram chat ID — have them ready (see each Part's "Before You Start"). Cost-wise: GCP's e2-micro can be free indefinitely, but only if you upgrade the account out of its 90-day Free Trial; AWS's free tier is 12 months, full stop — see each Part's cost note before you commit to one.

Optional: if you maintain your own fork and edit the workflow JSONs, a manually-triggered GitHub Action (`deploy.yml`) can push them to your VM — see `SETUP_GUIDE.md` Step 4. Regular users can ignore it. Separately, every push to `main` that touches the Dockerfile or a workflow JSON rebuilds and publishes the Docker image to GHCR automatically.

## MCP Server

The `mcp-server/` directory contains a Node.js MCP server that exposes the job parser webhook as a `parse-linkedin-job` tool for Claude.ai. Full step-by-step (including activating the Job Parser workflow first): `SETUP_GUIDE.md` Part 1C.

```bash
cd mcp-server && npm install
```

Add to Claude Desktop config — **the `env` block is required**, the server refuses to start without `MCP_WEBHOOK_URL` set:
```json
{
  "mcpServers": {
    "linkedin-job-parser": {
      "command": "node",
      "args": ["/path/to/mcp-server/index.js"],
      "env": {
        "MCP_WEBHOOK_URL": "https://<your-host>/webhook/parse-job"
      }
    }
  }
}
```

## Project Structure

```
n8n_job_search_v1.json      # Main scheduled job search workflow (37 nodes)
n8n_company_search_v1.json  # On-demand /search workflow (32 nodes)
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
