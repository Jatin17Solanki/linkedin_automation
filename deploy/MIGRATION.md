# GCP Account Migration Guide

Moving the n8n stack from an old GCP account to a new one.
All n8n state (workflows, credentials, executions, login) lives in a Docker volume —
the migration is a backup → new VM → restore operation. No re-configuration of n8n
credentials is needed if the volume is transferred intact.

Estimated time: **45–60 minutes**

---

## Before You Start — Gather These

From the **old VM**, run `cat ~/linkedin_automation/deploy/.env` and note down:

| Variable | Where you'll use it |
|---|---|
| `N8N_BASIC_AUTH_USER` | Recreate `.env` on new VM |
| `N8N_BASIC_AUTH_PASSWORD` | Recreate `.env` on new VM |
| `GEMINI_API_KEY` | Recreate `.env` on new VM |

The old `VM_IP` is no longer needed — the new VM will have a new IP.

---

## Phase 1 — Backup n8n Data (Old VM)

SSH into the old VM.

**Step 1.1 — Stop n8n cleanly**
```bash
cd ~/linkedin_automation/deploy
docker compose -f docker-compose.prod.yml stop n8n
```
Stopping before backup ensures SQLite is not mid-write.

**Step 1.2 — Create the backup archive**
```bash
docker run --rm \
  -v n8n_n8n_data:/data \
  -v /tmp:/backup \
  alpine tar czf /backup/n8n_backup.tar.gz -C /data .

ls -lh /tmp/n8n_backup.tar.gz   # verify it exists and has size > 0
```

**Step 1.3 — Download the backup to your local machine**

Run this **on your local machine** (not on the VM):
```bash
gcloud compute scp --project=<OLD_PROJECT_ID> \
  <OLD_VM_NAME>:/tmp/n8n_backup.tar.gz \
  ./n8n_backup.tar.gz

# Example:
# gcloud compute scp --project=my-old-project \
#   n8n-server:/tmp/n8n_backup.tar.gz ./n8n_backup.tar.gz
```

> **Alternative (if gcloud isn't set up locally):** In GCP Console on the old account,
> go to Compute Engine → VM → SSH (browser) → click the gear icon → Download file →
> enter `/tmp/n8n_backup.tar.gz`

Verify the file downloaded correctly:
```bash
ls -lh n8n_backup.tar.gz   # should be several MB
```

---

## Phase 2 — Create New GCP VM

Do this in the **new GCP account** (the one with the free trial).

**Step 2.1 — Enable Compute Engine API**
1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Select your new project (or create one)
3. Search "Compute Engine" in the top search bar → click Enable if prompted

**Step 2.2 — Create the VM**
1. Go to Compute Engine → VM instances → **Create Instance**
2. Fill in:

| Field | Value |
|---|---|
| Name | `n8n-server` |
| Region | `us-central1` ← **required for always-free tier** |
| Zone | `us-central1-a` |
| Machine type | **e2-micro** (under "General purpose" → "Shared-core") |
| Boot disk OS | Ubuntu 22.04 LTS |
| Boot disk size | 30 GB (default is fine) |

3. Under **Firewall**, tick both:
   - ✅ Allow HTTP traffic
   - ✅ Allow HTTPS traffic

4. Click **Create**

**Step 2.3 — Note the external IP**

Once the VM is created, the external IP appears in the VM list.
Write it down — this is your new `VM_IP`.

**Step 2.4 — Set up SSH access**

In GCP Console, click the **SSH** button next to your VM. This opens a browser-based
terminal. You'll use this for all VM commands in the steps below.

> If you prefer using your local terminal:
> ```bash
> gcloud compute ssh n8n-server --project=<NEW_PROJECT_ID> --zone=us-central1-a
> ```

---

## Phase 3 — Initial VM Setup (New VM)

Run all commands in this phase on the **new VM**.

**Step 3.1 — Configure swap (required — e2-micro only has 1GB RAM)**
```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

Verify swap is active:
```bash
free -h   # should show ~2G under "Swap"
```

**Step 3.2 — Clone the repo and run setup**
```bash
git clone https://github.com/Jatin17Solanki/linkedin_automation.git
cd linkedin_automation
sudo bash deploy/setup.sh
```

`setup.sh` installs Docker and Docker Compose. When it finishes, log out and back in
so your user is added to the `docker` group:
```bash
exit
# reconnect via SSH or browser terminal, then:
docker ps   # should return empty list with no permission error
```

**Step 3.3 — Create the `.env` file**
```bash
cat > ~/linkedin_automation/deploy/.env << 'EOF'
VM_IP=<YOUR_NEW_VM_IP>
N8N_BASIC_AUTH_USER=<from old .env>
N8N_BASIC_AUTH_PASSWORD=<from old .env>
GEMINI_API_KEY=<from old .env>
EOF
```

Replace the placeholders with the values you noted in Phase 1.

**Step 3.4 — Create Docker volumes**

These must be created manually before `docker compose up` because they are declared
as `external` in the compose file:
```bash
docker volume create n8n_n8n_data
docker volume create n8n_caddy_data
docker volume create n8n_caddy_config
```

---

## Phase 4 — Restore n8n Data (New VM)

**Step 4.1 — Upload backup to new VM**

Run this on your **local machine**:
```bash
gcloud compute scp --project=<NEW_PROJECT_ID> \
  ./n8n_backup.tar.gz \
  n8n-server:/tmp/n8n_backup.tar.gz \
  --zone=us-central1-a
```

> **Alternative:** In GCP Console on the new account, open the browser SSH terminal →
> gear icon → Upload file → select `n8n_backup.tar.gz` → it lands in `$HOME` (~/)
>
> Then move it: `mv ~/n8n_backup.tar.gz /tmp/`

**Step 4.2 — Restore into the Docker volume**
```bash
docker run --rm \
  -v n8n_n8n_data:/data \
  -v /tmp:/backup \
  alpine tar xzf /backup/n8n_backup.tar.gz -C /data

echo "Restore complete"
```

---

## Phase 5 — Start the Stack

**Step 5.1 — Pull images and start**
```bash
cd ~/linkedin_automation/deploy
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

**Step 5.2 — Watch startup logs**
```bash
docker logs n8n-job-search -f
```

Wait for these lines:
```
n8n ready on ::, port 5678
Editor is now accessible via:
https://<NEW_IP>.nip.io
```

No task runner errors should appear (we're on `1.123.25`).
Press `Ctrl+C` to stop following logs.

**Step 5.3 — Verify health**
```bash
curl -s http://localhost:5678/healthz
# Expected: {"status":"ok"}
```

---

## Phase 6 — Verify in the Browser

1. Open `https://<NEW_VM_IP>.nip.io` in your browser
2. Log in with your `N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD`
3. Go to **Workflows** — all three workflows should be there:
   - LinkedIn Job Search V1
   - LinkedIn Company Search V1
   - LinkedIn Job Parser
4. Check **Credentials** — Google Sheets, Gmail, and Telegram credentials should all
   be present (migrated from the volume)

**Step 6.1 — Re-activate workflows**

Telegram webhooks are tied to the HTTPS URL, which changed with the new IP.
n8n re-registers them automatically when you activate the workflow.

For each workflow:
1. Open the workflow
2. If it shows as inactive (grey toggle), click the toggle to activate it
3. n8n will call Telegram's API to register the new webhook URL automatically

**Step 6.2 — Test**

Send `/jobs 1` to your Telegram job search bot — you should get a response.
Send `/search Google 1` to your company search bot — you should get a response.

---

## Phase 7 — Cleanup

Only do this **after confirming everything works on the new VM**.

**Step 7.1 — Delete the old VM**
1. Go to old GCP account → Compute Engine → VM instances
2. Select `n8n-server` → Delete
3. Also go to **Disks** and confirm no orphaned disks remain

**Step 7.2 — Update local `.env` on your dev machine**
```bash
# In E:\Dev\n8n\linkedin_automation\deploy\.env
VM_IP=<NEW_VM_IP>
```

---

## Troubleshooting

**Browser shows 502 after startup**
n8n is still initialising. Wait 60 seconds and refresh. If it persists:
```bash
docker logs n8n-job-search --tail 30
docker logs caddy-proxy --tail 10
```

**Workflows are there but credentials show as broken**
This can happen if the encryption key changed. n8n uses an encryption key stored in
the volume — since we transferred the volume intact, it should be the same key.
If credentials are broken, you'll need to re-enter them in the n8n UI under
Settings → Credentials.

**Telegram bot not responding after activation**
Check that the workflow is activated (green toggle). Then send a message to the bot.
If still no response, open the workflow → Telegram Trigger node → check the webhook
URL shown matches `https://<NEW_IP>.nip.io/...`.

**`docker ps` shows permission denied**
You haven't logged out and back in after `setup.sh`. Run `exit`, reconnect, try again.

**`docker volume create` says volume already exists**
That's fine — it was created by a previous attempt. Continue.
