# Backlog and project status

*Last updated 2026-09-20, at the end of the open-source cleanup pass. This file is for whoever picks the project up next — including its author after a long break.*

## Where the project stands

- **Working, exercised on the author's own AWS instance:** the scheduled Job Search workflow (with Gemini resume matching), Company Search (`/search`) with its email report, result paging through LinkedIn's guest endpoint, the `/jobs` command gate and the owner-only lock on both bots, and the in-place update script (`deploy/import-workflow.sh`).
- **Written from documentation and reasoning, never run live:** the GCP path (`setup-gcp.sh`), the MCP server against a cloud instance, the interactive prompts of `setup-*.sh`, and a few external claims listed under *Verification debt* below.
- **Shape of the repo:** three n8n workflows (`n8n_*.json`), a Docker image that imports them on first start, VM setup scripts, a Google Sheet bootstrap script, and the docs. `main` is branch-protected: work on a branch, open a PR.
- **Decisions worth remembering:** the two main workflows deliberately duplicate their filtering logic instead of sharing a sub-workflow; chat ID and Gemini key are environment-only (never in the Sheet); the shipped Config list is 94 companies, all `Active=TRUE`; n8n is pinned to 1.123.25 (2.x's task runners broke in a single-container setup).

## Picking it up again

1. Read `README.md`, then `CLAUDE.md` (the technical reference, also written for AI assistants).
2. Before touching any workflow JSON, read "Editing workflow JSON — agent checklist" in `CLAUDE.md` and run its validation one-liner. Also read `CONTRIBUTING.md`.
3. To change a running instance, use `deploy/import-workflow.sh` (see `SETUP_GUIDE.md` §6.2): the Docker image only imports workflows on a container's *first* start.

## What will rot first (check these after a long gap)

| Thing | Why it can break | How you'd notice |
|---|---|---|
| LinkedIn's guest search endpoint and page HTML | Unofficial; the CSS selectors in `Extract Links & Titles` and the 10-cards-per-page paging are observed behaviour, not a contract | Digests suddenly empty, or the execution log shows 0 cards per page. Fetch the search URL by hand and compare with the selectors |
| Gemini model `gemini-2.5-flash` and its terms | Models get retired; free-tier quotas and data-use terms change | "AI matching unavailable this run" on every run; check Google's terms again before recommending the free tier |
| n8n 1.123.25 pin | 1.x will eventually lose support; upstream defaults (`N8N_BLOCK_ENV_ACCESS_IN_NODE`, task runners) are changing | n8n's startup deprecation warnings; see the version item below |
| AWS free plan / GCP free-trial rules | The docs quote both providers' current terms (AWS 6-month plan for accounts created since 2025-07-15; GCP needs an upgrade out of the trial) | A surprise bill or a suspended VM |
| Google OAuth consent-screen console | Menu names change; apps left in *Testing* lose sign-in after 7 days | Google Sheets credential errors about a week after setup |
| LinkedIn company IDs / place IDs | Rarely change | A company that stops returning anything |

## Backlog

### Next up

1. **Automated checks on every pull request, then make them a required check on `main`.** Today nothing automated gates a merge. The checks that would have caught real bugs here: workflow structure (unique node ids and names, no dangling connections — the duplicate-id bug), every Code node compiles, the `/jobs` gate and owner-lock logic, the import script against a mock n8n API, `bash -n` on the deploy scripts, doc links and anchors, `scripts/check-secrets.js`. The author's ad-hoc versions of most of these exist only on their machine and would need rebuilding in the repo.
2. **`import-workflow.sh` should keep each workflow's active/inactive state.** It currently activates every workflow it updates — including *Job Parser*, a public, unauthenticated web address, which someone may have switched off on purpose.
3. **Protect the Job Parser webhook.** Anyone who knows the URL can make the VM fetch LinkedIn pages. Options: an optional shared-secret header (the MCP server would send it), or document "leave it inactive unless you use the Claude tool".
4. **Skip the Gemini call when there is nothing to send.** `Call Gemini Flash` still runs when `Prepare LLM Input` skips (no resume, no jobs): a wasted failing request that `continueOnFail` hides, and `Parse LLM Response`'s `llmRequired === false` branch is unreachable. Fix: an IF between the two, in both workflows.

### Workflow improvements

5. **Show the result cap in Telegram, not only the log.** A search stops at 30 pages (300 results) per bucket and logs a `WARNING`; the user never sees it. Consider a note in the message and `MAX_PAGES` as a Settings-tab key.
6. **Watch Bucket 4 (68 companies).** Its 24h volume was 26 postings on the day it was measured, far under the cap, but every company added there grows it. If it ever nears 300, split a bucket into chunks of ~15 companies per request.
7. **Sheets write-quota burst (unverified).** Reasoned unlikely (n8n's Sheets node batches its writes), never tested with a large first run.
8. **Auto resume customization** — the old "V2" idea: tailor the resume to a matched posting.

### Reliability and safety

9. **Re-running `bootstrap.gs` wipes the tabs it manages,** including *Results*, which is the "already sent" history. Make it skip tabs that already hold data, or warn loudly.
10. **Non-interactive setup** for unattended VM provisioning (the scripts prompt for basic-auth credentials, the Gemini key and the chat ID).

### Verification debt (written from documentation, not run)

11. LinkedIn's *Company* filter putting `f_C=<id>` in the address bar (the guide's way to find a company ID); reading `geoId` for countries outside India.
12. The Google Cloud "Publish app" click path (menu names on the newer *Google Auth Platform* pages).
13. n8n's telemetry-off variables (`N8N_DIAGNOSTICS_ENABLED`, `N8N_VERSION_NOTIFICATIONS_ENABLED`) in a running container.
14. `import-workflow.sh` edge cases against a real n8n: `PUT` on an already-active workflow, workflows with more than 250 siblings.
15. The whole GCP path on a fresh VM, the MCP server against a cloud instance, and the interactive `setup-*.sh` prompts.

### Housekeeping

16. **Rename the project** to something more distinctive. Touches: the repo name, the GHCR image (`linkedin-automation-n8n`), the README title, `bootstrap.gs`'s `REPO_RAW_BASE`, clone URLs in the docs, the `DOCKER_IMAGE` default. GitHub redirects the old repo URL; the image must be rebuilt and re-published under the new name.
17. **Re-validate the n8n version pin** periodically: pull the latest tag, run all three workflows, confirm Code nodes still execute and `$env` access still works; bump the pin and re-run the Docker validation from the cleanup phase if so.
18. Optional repo setting: automatically delete merged branches.

## Known limits (not bugs)

- Reads only LinkedIn's public job pages — no login, so no personalised results, and roles LinkedIn doesn't show to guests are invisible.
- One search request per bucket of companies, at most 300 results per bucket per run.
- Location filtering is text matching on the job's location string (see `location_city_names`); experience is regex-parsed from the description and passes through as "Not specified" when it can't be read.
- The Gemini free tier may use submitted content to improve Google's products (documented in the README's Privacy section).
