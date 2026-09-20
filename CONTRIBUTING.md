# Contributing

Thanks for wanting to help. This is a small project run by one person, so the process is light — but a few rules exist because breaking them has already cost real time here.

## Ideas, bugs, questions

- **Something not working?** Open an [issue](https://github.com/Jatin17Solanki/linkedin_automation/issues) with what you ran, what you expected, and the error text or the n8n execution output. Check [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) first; many problems are listed there.
- **Want to build something?** Look at [`BACKLOG.md`](BACKLOG.md) — it lists what's planned, what's unverified, and what is likely to rot. For anything bigger than a small fix, open an issue first so we agree on the approach before you spend the time.
- **Otherwise,** email is in the footer of the [README](README.md).

## The rules

### 1. Work on a branch and open a pull request
`main` is protected: nothing goes straight to it, not even from the owner. Branch, commit, open a PR. A pull request description that says *what changed, why, how you checked it, and what you did **not** check* is the convention here — the last part matters most.

### 2. Never commit real personal data
This repo once shipped a real Google Sheet id, credential ids and a Telegram chat id, because a live export from n8n was committed on top of the clean template. The workflow files are **templates**:

- credentials are `CONFIGURE_ME`, the spreadsheet is `YOUR_GOOGLE_SHEET_DOCUMENT_ID`, the chat id is the expression `={{ $env.TELEGRAM_CHAT_ID }}`;
- there is no `pinData`, `staticData` or `meta.instanceId`.

**Never commit an n8n export as it comes out of the editor.** If you change a workflow in the n8n UI and want to contribute the change, re-apply your edit to the JSON in the repo instead of replacing the file, or sanitize the export first.

Before every commit, run:

```bash
node scripts/check-secrets.js --staged     # what you're about to commit
node scripts/check-secrets.js              # everything in the repo
```

It looks for tokens and keys (Telegram bot tokens, Google API keys and OAuth secrets, AWS keys, private keys), hard-coded IPs, and it checks the workflow JSON files structurally for real credential, spreadsheet and chat ids. It's a safety net, not a guarantee — read your own diff as well. To run it automatically, save this as `.git/hooks/pre-commit` and make it executable:

```bash
#!/bin/sh
node scripts/check-secrets.js --staged
```

### 3. Editing the workflow JSON
The workflows are big JSON files, and the validation most people reach for (`JSON.parse`) cannot see the mistakes that have actually happened here. When you edit `n8n_*.json`:

- **Node `id`s must be unique, and so must node `name`s** (connections refer to names). Never copy an id from another node.
- **Every connection must point at an existing node.**
- **A node runs once per input item, and a Google Sheets read emits one item per *row*.** Something wired after a multi-row read or after a loop's `done` output runs that many times — a recipe for Google's per-minute quota errors. Collapse to one item first, or set *Execute Once*.
- **Adding a node in the middle of a chain changes the input of everything after it.** Re-check every downstream node that reads `$input`; prefer `$('Node Name')`.
- **Edit as text and keep the file's CRLF line endings,** or the diff becomes unreadable. For the two main workflows, parsing the file, editing the object, and writing it back with `JSON.stringify(obj, null, 2)` converted to CRLF reproduces them byte for byte, so a small edit stays a small diff — check `git diff --stat` before committing. (The small job-parser file isn't formatted that way: edit it as text.)
- **The filtering logic is duplicated on purpose** between `n8n_job_search_v1.json` and `n8n_company_search_v1.json` (title filters, bucket keywords, experience and location checks, URL building, paging). Change both, or they silently disagree.

After editing, run this and expect `true` / `0` everywhere:

```bash
node -e "for (const f of ['n8n_job_search_v1.json','n8n_company_search_v1.json','n8n_job_parser_v1.json']) { const wf=JSON.parse(require('fs').readFileSync(f,'utf8')); const ids=wf.nodes.map(n=>n.id), names=wf.nodes.map(n=>n.name), nm=new Set(names); const dangling=Object.entries(wf.connections).flatMap(([s,c])=>[s,...(c.main||[]).flat().map(o=>o.node)]).filter(x=>!nm.has(x)); console.log(f,'| unique ids:',new Set(ids).size===ids.length,'| unique names:',nm.size===names.length,'| dangling connections:',dangling.length); }"
```

### 4. Test what you change — against the real thing where you can
The most useful checks so far were cheap: run a Code node's actual JavaScript in Node with mocked `$input` / `$getWorkflowStaticData` / `$env`, and compare its output with what you expect. For anything that talks to LinkedIn, run it against the live pages once (gently — a handful of requests). Say in your PR what you ran and what you couldn't.

### 5. Docs: one home for each fact
- [`README.md`](README.md) is for people meeting the project. [`SETUP_GUIDE.md`](SETUP_GUIDE.md) is the single step-by-step walkthrough. [`CLAUDE.md`](CLAUDE.md) is the technical reference (and briefing for AI assistants). [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) holds problem → cause → fix.
- Don't copy a set of instructions into a second file; link to the one that owns it. When behaviour changes, update the docs in the same PR, including the node counts and lists in `CLAUDE.md`.
- If you add or rename headings, check the links to them still resolve (GitHub's anchors drop punctuation and lower-case everything).

### 6. Shell scripts
`bash -n deploy/<script>.sh` at minimum. The setup scripts run as root on a fresh VM, so keep them boring and idempotent.

## Licence
By contributing you agree that your contribution is released under the project's [MIT licence](LICENSE).
