# LLM Resume Matching — Setup Steps

> **Delete this file after completing setup.** It's just a temporary guide.

---

## Step 1: Create the "Resume" Tab in Google Sheets

1. Open your Google Sheet: https://docs.google.com/spreadsheets/d/1i4eS-2TNhMJyY5JoTZhTrkXrn49xW0MbxpeaQ4NmHvc
2. Click the **+** button at the bottom-left to add a new tab
3. Name it exactly: **Resume**
4. In cell **A1** type: `Key`
5. In cell **B1** type: `Value`
6. Paste the following rows starting from **A2**:

| Key                  | Value                                                                                                                                                          |
|----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| name                 | Jatin Solanki                                                                                                                                                  |
| title                | Full-stack Software Engineer                                                                                                                                   |
| years_experience     | 3.5                                                                                                                                                            |
| target_roles         | SDE-II, Software Engineer, Backend Engineer, Full-Stack Engineer                                                                                               |
| skills_languages     | Java, SQL, JavaScript, TypeScript, Bash, Groovy, C/C++                                                                                                        |
| skills_frameworks    | Spring Boot, Hibernate/JPA, Apache Kafka, RESTful APIs, GraphQL, OAuth2/JWT, Node.js, Angular                                                                 |
| skills_databases     | Oracle, MySQL, MongoDB                                                                                                                                         |
| skills_cloud         | GCP, Docker, Kubernetes, OpenShift, Helm, Jenkins, Maven                                                                                                       |
| skills_other         | Microservices Architecture, Event-Driven Systems, Distributed Systems, Design Patterns, TDD, CI/CD Pipelines                                                  |
| experience_summary   | SDE-2 at Deutsche Bank (Oct 2024-present): Architected Kafka event-driven integration for monolith-to-microservices migration, redesigned data models for multi-entity access, built admin correction interfaces. SDE-1 at Deutsche Bank (Jul 2022-Sept 2024): Built exact-date-of-default calculation saving EUR 70mn annually, debugged Hibernate production issues, optimized CI/CD pipelines with 25% runtime reduction, led Angular v7-to-v15 upgrade across 4 microservices. |
| education            | B.Tech Computer Science, Manipal Institute of Technology, CGPA 9.52/10, 2022                                                                                  |
| highlights           | EUR 70mn annual cost savings from default-date feature, Kafka migration with zero user disruption, 25% CI/CD pipeline runtime reduction, Angular upgrade across 4 microservices |

**Tip:** Easiest way is to type/paste each Key in column A and its Value in column B, one row at a time. There should be 12 data rows (A2:B13).

The workflow references this tab by name (`Resume`), not by GID — same approach as the `Results` tab. No GID lookup needed.

---

## Step 2: Get a Gemini API Key (Free)

1. Go to https://aistudio.google.com/apikey
2. Sign in with any Google account
3. Click **"Create API Key"**
4. Select any GCP project (or let it create one)
5. Copy the generated key — it looks like `AIzaSy...` (39 characters)

> The free tier gives you 15 requests/minute and 1 million tokens/day — more than enough.

---

## Step 3: Set the Gemini API Key

**You already added it to `docker-compose.prod.yml` — good.** Just make sure the line looks like:
```yaml
environment:
  - GEMINI_API_KEY=AIzaSy...your_key_here...
  # ... other env vars ...
```

Then SSH into the VM and restart:
```bash
cd ~/linkedin_automation/deploy  # or wherever the compose file lives
docker compose -f docker-compose.prod.yml up -d
```

After restart, the n8n container will have `GEMINI_API_KEY` as an OS environment variable. The workflow's `{{ $env.GEMINI_API_KEY }}` expression reads directly from the container's OS environment — this is **not** the n8n Cloud Variables/Secrets feature (which requires Enterprise). `$env` always reads OS-level env vars, which Docker compose injects. So yes, restarting the VM will make it work.

---

## Step 4: Connect Gmail in n8n

Gmail sends the detailed match report email. The **sender** is whichever Google account you authorize. The **receiver** is whatever email you put in the `sendTo` field. You can use any Gmail account — using the same Google account you already use for Sheets is simplest.

### In the n8n UI:

1. Go to **Settings** (gear icon, left sidebar) > **Credentials**
2. Click **"Add Credential"**
3. Search for **"Gmail OAuth2"** and select it
4. Name it something like `Gmail account`
5. You'll see fields for **Client ID** and **Client Secret**. To get these:

   **Create OAuth2 credentials in Google Cloud Console:**
   a. Go to https://console.cloud.google.com/apis/credentials
   b. Use the same GCP project you used for Sheets (or any project)
   c. Click **"+ CREATE CREDENTIALS"** > **"OAuth client ID"**
   d. Application type: **Web application**
   e. Name: `n8n Gmail`
   f. Under **"Authorized redirect URIs"**, add your n8n OAuth callback URL:
      - Cloud: `https://YOUR_VM_IP.nip.io/rest/oauth2-credential/callback`
      - Local: `http://localhost:5678/rest/oauth2-credential/callback`
   g. Click **Create** — copy the **Client ID** and **Client Secret**

   **Enable the Gmail API:**
   a. Go to https://console.cloud.google.com/apis/library/gmail.googleapis.com
   b. Click **"Enable"** (if not already enabled)

   **If you see "OAuth consent screen" warnings:**
   a. Go to https://console.cloud.google.com/apis/credentials/consent
   b. User type: **External** (or Internal if using Workspace)
   c. Fill in app name (e.g., `n8n automation`) and your email
   d. Add scope: `https://www.googleapis.com/auth/gmail.send`
   e. Add yourself as a **test user** (your Gmail address)
   f. Save

6. Back in n8n, paste the **Client ID** and **Client Secret**
7. Click **"Sign in with Google"** — authorize with the Gmail account you want to send from
8. Click **Save**

> **Already have Google Sheets OAuth2 working?** You might be able to reuse the same GCP project and OAuth consent screen. But you'll still need a separate n8n credential for Gmail since it requires the `gmail.send` scope which Sheets doesn't include.

---

## Step 5: Configure the Workflow Nodes

After importing the updated `n8n_company_search_v1.json`, open it in the n8n UI:

### 5a. Read Resume node (node 24)
- Open it, connect your Google Sheets credential
- It should auto-detect the "Resume" tab. If not, select it from the dropdown.

### 5b. Send Gmail node (node 30)
- Open it, connect the Gmail credential you created in Step 4
- Change the **"To"** field from `CONFIGURE_ME@gmail.com` to your email (e.g., `007iamjatin@gmail.com`)

### 5c. Verify Call Gemini Flash node (node 26)
- Open it, check the URL field contains `{{ $env.GEMINI_API_KEY }}`
- No changes needed if you set the env var in Step 3

---

## Step 6: Test

1. **Test LLM matching:** `/search Oracle 30`
   - Telegram: match % with color-coded icons (green/yellow/red)
   - Email: detailed report with summaries, key matches, and gaps

2. **Test fallback:** Temporarily break the API key, run `/search Google`
   - Telegram: plain format + "AI matching unavailable this run"
   - No email sent

3. **Test unchanged paths:** `/search nonexistent` should still return "Company not found"

---

## Checklist

- [ ] Resume tab created in Google Sheet with 12 Key/Value rows
- [ ] Gemini API key added to `docker-compose.prod.yml` environment
- [ ] VM restarted (`docker compose up -d`)
- [ ] Gmail OAuth2 credential created in n8n
- [ ] Read Resume node connected to Google Sheets credential
- [ ] Send Gmail node has Gmail credential + correct recipient email
- [ ] Tested with `/search` command
