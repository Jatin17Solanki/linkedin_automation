# Troubleshooting

Real problems hit while running this on a GCP e2-micro VM (1GB RAM, Docker Compose + Caddy), and the fixes that resolved them. If you're self-hosting n8n behind a reverse proxy on a small VM, several of these will likely bite you too.

## "n8n task runner" 403 errors / workflows won't execute

**Symptom:** Code nodes fail, or the whole workflow errors out, with 403 errors related to task runners, shortly after starting a fresh n8n container.

**Root cause:** n8n 2.x made "task runners" (a separate process that executes Code-node JavaScript) mandatory. In a single-container Docker setup, the internal WebSocket auth between n8n and its task runner process doesn't come up reliably — this is a known upstream issue, not a config mistake.

**Fix:** Pin the image to **`n8nio/n8n:1.123.25`** — the last 1.x release where task runners are optional and can be fully disabled via `N8N_RUNNERS_ENABLED=false`, falling back to the old in-process Code node execution. `deploy/docker-compose.prod.yml` (and the auto-import `Dockerfile` from Phase 4 onward) pin this version deliberately. **Do not bump the n8n version without re-testing this specific failure mode** — we tried pinning to `2.11.4` with `N8N_RUNNERS_GRANT_TOKEN_TTL=60` first and it still wasn't reliable enough; only dropping back to 1.x resolved it for good.

## `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`

**Symptom:** n8n logs a rate-limiter validation error referencing `X-Forwarded-For` shortly after putting it behind Caddy.

**Root cause:** Caddy (the reverse proxy) sets an `X-Forwarded-For` header on every request. n8n's built-in rate limiter (`express-rate-limit`) validates that header and rejects it when it doesn't trust the immediate upstream as a proxy.

**Fix:** Strip `X-Forwarded-For` at the Caddy layer instead of trying to get n8n to trust it (`N8N_TRUST_PROXY=1` alone wasn't sufficient in testing). See `deploy/Caddyfile` — the reverse-proxy block removes this header before forwarding to n8n.

## Caddy serving the wrong domain / certificate errors after `git checkout`

**Symptom:** Caddy's HTTPS cert doesn't match your VM, or Caddy fails to start, after pulling the repo onto a new VM or re-cloning.

**Root cause:** An earlier version of `deploy/Caddyfile` had the VM's IP hardcoded as a literal string. Every fresh checkout needed a manual find-and-replace before Caddy would work.

**Fix:** `deploy/Caddyfile` now reads `{$VM_IP}` from the environment, and `deploy/docker-compose.prod.yml` passes `VM_IP` through from `deploy/.env`. Set `VM_IP` once in `.env` and both n8n and Caddy pick it up — no more manual file edits after checkout.

## VM freezes completely under a heavy workflow run

**Symptom:** The entire VM becomes unresponsive (not just the n8n container) — SSH stops responding, you have to hard-reboot from the cloud console.

**Root cause:** e2-micro/t2.micro-class instances have only 1GB RAM. A workflow run that spikes memory (e.g. processing many job pages at once) can push total memory usage past what the VM has, and without a hard limit on the container, the Linux OOM killer can take out critical host processes instead of just the offending container.

**Fix:** Three things together, all in `deploy/docker-compose.prod.yml`:
- `NODE_OPTIONS=--max-old-space-size=512` caps n8n's own Node.js heap.
- `mem_limit: 600m` / `memswap_limit: 800m` on the container means Docker OOM-kills *the container* (which then restarts via `restart: unless-stopped`) instead of starving the host.
- `EXECUTIONS_DATA_PRUNE=true` with a 72-hour/500-execution retention window keeps the SQLite database from growing unbounded, which was itself contributing to memory pressure over time.

A 2GB swapfile on the VM's disk is the other half of this fix — see `deploy/MIGRATION.md` for the manual steps if `deploy/setup-gcp.sh`/`setup-aws.sh` in your checkout predates the automated swapfile setup.

## Docker Compose wipes your workflows/credentials on redeploy

**Symptom:** After running `docker compose up -d` again (e.g. to pick up a new image), n8n comes up with no workflows, no credentials — like a fresh install.

**Root cause:** An earlier compose file declared named volumes without `external: true`, so Compose would (re)create a fresh empty volume instead of reusing the one with your actual data.

**Fix:** `deploy/docker-compose.prod.yml` declares `n8n_n8n_data`, `n8n_caddy_data`, and `n8n_caddy_config` as `external: true` volumes. **These must exist before the first `docker compose up`** — the setup scripts create them for you; if you're running compose manually, create them yourself first: `docker volume create n8n_n8n_data` (and the same for the other two).

## Telegram "can't parse entities" 400 error

**Symptom:** The Telegram send node fails with a 400 error mentioning entity parsing, usually when a job title contains an underscore, asterisk, or square brackets.

**Root cause:** `parse_mode` (Markdown) was enabled on the Telegram node, and dynamic job-title text sometimes contains characters Telegram's Markdown parser treats as unclosed formatting.

**Fix:** Don't set `parse_mode` on the Send Telegram nodes. Two extra mitigations are already baked into the workflow's Code nodes: a `safe()` helper strips `_`/`*` from dynamic text before it's inserted into messages, and tags use `(SDE-II)` parentheses instead of `[SDE-II]` square brackets, since `[...]` triggers Markdown's link-entity parsing even without `parse_mode` in some clients.

## `docker pull` from GHCR fails with "denied" / "not found" for a public repo

**Symptom:** `.github/workflows/docker-publish.yml` runs green and pushes the image, but `docker pull ghcr.io/<owner>/linkedin-automation-n8n:latest` on the deploy VM fails with a 403/404 even though you never made the repo private.

**Root cause:** GitHub Container Registry packages default to **private** on first publish, independent of the source repo's visibility — publishing via `GITHUB_TOKEN` doesn't make the package public automatically.

**Fix:** After the first successful `docker-publish.yml` run, go to the package page (your GitHub profile/org → **Packages** → `linkedin-automation-n8n`) → **Package settings** → **Change visibility** → **Public**. One-time step; subsequent pushes stay public.

## n8n startup warning: "deprecations related to your environment variables"

**Symptom:** On every container start, n8n logs a deprecation block listing `DB_SQLITE_POOL_SIZE`, `N8N_RUNNERS_ENABLED`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`, and `N8N_GIT_NODE_DISABLE_BARE_REPOS`.

**Which of these actually matter here:**
- **`N8N_BLOCK_ENV_ACCESS_IN_NODE`** — matters a lot. Every Code node in both workflows reads config via `$env.X` (`LOCATION_GEO_ID`, `MAX_EXPERIENCE_YEARS`, `TELEGRAM_CHAT_ID`, `GEMINI_API_KEY`, etc. — this is the entire Phase 2 parameterization mechanism). This currently works only because n8n 1.123.25's *default* for this flag happens to be `false` (env access allowed). n8n's own warning says the default flips to `true` (blocked) in a future version — an unpinned upgrade would silently break every env-var-driven Code node with no obvious error, since `$env.X` would just start returning `undefined`. Both `docker-compose.yml` and `deploy/docker-compose.prod.yml` now set `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` explicitly so this can't silently regress.
- **`N8N_RUNNERS_ENABLED`** — already relevant per the task-runner entry above; both compose files now set `N8N_RUNNERS_ENABLED=false` explicitly (previously only `deploy/docker-compose.prod.yml` did).
- `DB_SQLITE_POOL_SIZE` (a performance tuning knob) and `N8N_GIT_NODE_DISABLE_BARE_REPOS` (only relevant if you use n8n's Git node, which this project doesn't) — safe to ignore, not set here.

**Fix:** already applied — see the two `N8N_*` lines above in both compose files. If you still see the `N8N_RUNNERS_ENABLED`/`N8N_BLOCK_ENV_ACCESS_IN_NODE` lines in the deprecation block after pulling the latest compose files, confirm your container actually picked up the new env (`docker compose up -d` recreates; a plain `restart` does not).

## Settings/Resume tab values silently ignored (everything falls back to defaults)

**Symptom:** You set a value in the Settings tab (e.g. `min_match_percent`) but the workflow behaves as if it were never set — no error, just silently uses the default.

**Root cause:** Any Key/Value tab (Settings, Resume) is read by n8n's Google Sheets node using **row 1 as the column headers**. If row 1 doesn't literally read `Key` / `Value` (exact spelling and case) — e.g. if you typed your first setting's actual key/value pair into row 1 instead of the header labels — n8n reads that first data pair as the headers instead, and every subsequent row's key/value gets misread. This is easy to hit when creating a tab by hand. `bootstrap.gs` gets the header row right for every tab **except** the Resume tab when you fill in `RESUME_JSON` — before 2026-09-20 that path wrote the data straight into row 1 with no `Key`/`Value` header (see the "AI matching unavailable" entry below).

**Fix:** Row 1 of the Settings/Resume tab must be exactly `Key` and `Value` as plain header text; your actual data starts at row 2. As of 2026-08-25, `Store Settings` logs an explicit warning (`WARNING: Settings tab has N row(s) but none had a recognizable Key column...`, visible in that node's execution output) when this happens, showing you exactly what row 1 was read as — check n8n's execution log for that node if a Settings value doesn't seem to be taking effect.

## "AI matching unavailable this run" even though the Resume tab has data

**Symptom:** Telegram (or the company-search email) comes through in the plain format with no match %, plus the "AI matching unavailable" warning — and in n8n's execution view, `Prepare LLM Input` outputs `{ "llmRequired": false, "reason": "resume_empty" }` even though `Read Resume` clearly returned rows (its output looks like resume data, but with odd field names).

**Quickest check (5 seconds):** open the **Resume** tab in your Google Sheet and look at cell **A1**. It must be the literal word `Key` (and B1 `Value`). If A1 is `name` (or anything else that is really data), this is your problem.

**Root cause (most likely): the Resume tab has no `Key`/`Value` header row.** n8n's Google Sheets node always treats row 1 as the column names. Before 2026-09-20, `bootstrap.gs` wrote the Resume tab **without** a header row whenever you filled in `RESUME_JSON` (the path for loading your own resume) — the first pair, `name` + your name, landed in row 1 and became the column headers, so every read saw no `Key`/`Value` columns and reported an empty resume even though all 12 rows were filled in correctly. The placeholder-CSV path was never affected (those CSVs start with a `Key,Value` row).

**Fix:**
1. **Existing sheet:** right-click row 1 → **Insert 1 row above**, then type `Key` in A1 and `Value` in B1. Nothing else to change or redeploy — the next run picks it up. (Or re-run the current `bootstrap.gs`, which now writes the header — note it clears and rewrites the tabs it manages.)
2. **New sheets:** use the current `bootstrap.gs` (already fixed).

**Other, less likely causes** — `Prepare LLM Input` used to be stricter than necessary: it required a row whose Key was exactly `name` with a non-blank Value, so a blank `name` cell (e.g. a `RESUME_JSON` that used `full_name`, which `bootstrap.gs` drops), a `Name`-cased key, or lowercase `key`/`value` headers also read as "empty". It now only needs at least one non-blank value and matches `Key`/`Value` case-insensitively.

**Reading the `reason`** (visible in `Prepare LLM Input`'s output panel, no server logs needed):
- `resume_missing_key_column` — none of the columns n8n read are named Key/Value. `columnsSeen` in the output shows what n8n actually treated as the header row — if it contains your own data (e.g. `["name", "Your Name"]`), that is the missing-header-row problem above. `columnsSeen: []` means `Read Resume` returned nothing at all: a headers-only/cleared Resume tab. `Read Resume` now has "Always Output Data" on, so that case degrades to the plain (no match %) notification instead of the run stopping silently with no Telegram message — the same fix `Read Config`/`Read Results`/`Read Unnotified` got earlier.
- `resume_all_values_blank` — the Key column is there but every Value cell is empty.
- `no_jobs` — nothing to do with the Resume tab; there were no new jobs to score this run.

**Already running an older workflow copy?** Fixing the sheet (above) is enough for the header-row cause. For the other causes, don't re-import the workflow (that resets your Google Sheets node selections — next entry); paste the updated code straight into the one node: open `Prepare LLM Input` → replace its code with the version from the current `n8n_job_search_v1.json` / `n8n_company_search_v1.json`.

## Re-importing a workflow resets your Google Sheets node selections

**Symptom:** After using **⋯ → Import from File** to pick up an updated `n8n_job_search_v1.json` (e.g. a new release, or a node you edited by hand), most Google Sheets nodes' **Document** field reverts to the placeholder, and re-selecting your Sheet also blanks out the **Sheet** field, requiring you to set both by hand again.

**Root cause:** the committed JSON always ships with a placeholder `documentId` (`YOUR_GOOGLE_SHEET_DOCUMENT_ID`) — a real Sheet ID can't be baked into a public template. A full reimport replaces a node's entire parameter block with what's in the file, placeholder included, wiping out whatever real Sheet you'd previously selected. n8n's resource-locator UI also clears the Sheet field's state whenever you touch the Document dropdown, even for fields using `name` mode — this appears to be inherent n8n UI behavior, not something fixable from the workflow JSON.

**Fix:** none available — this is expected any time you reimport the whole workflow (initial setup, or pulling a future release with workflow changes). After any reimport, re-check all 7 Google Sheets nodes (`Read Config`, `Read Results`, `Append to Results`, `Read Unnotified`, `Update Notified Status`, `Read Resume`, `Read Settings`) per `SETUP_GUIDE.md` Step 5. If you're only changing a Code node's JS logic (not adding/removing nodes), you can avoid this entirely by pasting the updated code directly into that one node instead of reimporting the whole file.

## AWS EC2: page never loads even though `docker compose ps` shows healthy containers

**Symptom:** After running `deploy/setup-aws.sh`, `docker compose ps` shows both `n8n-job-search` and `caddy-proxy` as healthy/running, but `https://<VM_IP>.nip.io` times out or refuses to connect from your browser — nothing in the container logs looks wrong.

**Root cause:** Unlike GCP (where the "Allow HTTP/HTTPS" checkboxes at VM creation are the only gate), AWS EC2 instances sit behind a **Security Group** that filters inbound traffic *before* it ever reaches the VM's network stack. `setup-aws.sh` opens ports 80/443 via `iptables` on the VM itself (same as `setup-gcp.sh`), but that's a second, independent gate — both the Security Group and iptables have to allow the traffic, and iptables being open does nothing if the Security Group blocks it first.

**Fix:** In the AWS Console, go to your instance → **Security** tab → click the attached Security Group → confirm inbound rules allow TCP 80 and 443 from `0.0.0.0/0` (Anywhere). See `SETUP_GUIDE.md` Part 3, Step 1.3 for the full rule table. This is the single most common "it's not working" report for the AWS path and has no GCP equivalent.

## Before you go live: check your Google Sheet's sharing settings

The workflows read/write your Config, Results, and Resume tabs via the Google Sheets OAuth2 credential — not a public link — but it's easy to accidentally leave a Sheet shared as "Anyone with the link" from earlier testing or copy-pasting. Your Resume tab in particular contains personal career details. Before activating any workflow against a real Sheet, open its Share settings and confirm it's restricted to your own account (or explicitly trusted collaborators) rather than link-shared.
