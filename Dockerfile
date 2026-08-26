# Thin image on top of the official n8n image that auto-imports this repo's
# 3 workflow JSONs on first container start. Credentials (Google Sheets OAuth2,
# Telegram bot token, Gmail OAuth2) still require one-time interactive setup in
# the n8n UI — OAuth consent can't be scripted.
#
# n8n is pinned to 1.123.25 — do not bump without re-validating against
# TROUBLESHOOTING.md's n8n task-runner/version notes.
FROM n8nio/n8n:1.123.25

USER root

COPY n8n_job_search_v1.json n8n_company_search_v1.json n8n_job_parser_v1.json /workflows/
COPY docker/import-entrypoint.sh /docker-entrypoint-import.sh
RUN chmod +x /docker-entrypoint-import.sh && chown -R node:node /workflows

USER node

ENTRYPOINT ["tini", "--", "/docker-entrypoint-import.sh"]
