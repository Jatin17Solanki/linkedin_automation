# Privacy Policy

This document covers the Google OAuth client used by this project's self-hosted n8n workflows (`n8n_job_search_v1.json`, `n8n_company_search_v1.json`).

## What this is

This is a self-hosted automation tool, not a hosted service. Each user deploys their own n8n instance and creates their own Google Cloud OAuth client (see `SETUP_GUIDE.md` §1.5). There is no shared backend — your credentials, data, and Google Cloud project belong only to you.

## What data is accessed

The Google Sheets and Google Drive scopes are used solely to let your own n8n instance read and write the Google Sheet you create and own (Config, Results, Settings, Resume tabs). Google Drive access is used only so n8n's spreadsheet picker can list your own files.

No data is transmitted to the repository maintainer or any third party controlled by this project. The only outbound calls your workflow makes are:
- To LinkedIn's public job-search pages (to find and parse job postings)
- To your own Google Sheet (via the OAuth client you created)
- Optionally, to Google's Gemini API (if you configure `GEMINI_API_KEY`), sending job descriptions and the resume data from your own "Resume" sheet tab for match scoring
- Optionally, to Telegram's Bot API (sending you notifications) and Gmail's API (sending you an email digest), using credentials you configure

## Data retention

Data (job listings, match scores, your resume) is stored only in the Google Sheet you created and in your own n8n instance's database. Nothing is retained by this project's maintainer.

## Contact

Questions about this policy or the project: open an issue at https://github.com/Jatin17Solanki/linkedin_automation/issues
