#!/usr/bin/env python3
"""Carry an instance's own wiring over into a freshly shipped workflow JSON.

The workflow files in this repo are sanitized templates: every node's credential is a placeholder and every
Google Sheets node points at a placeholder spreadsheet. Importing one over a workflow you already wired up would
reset all of that. This script takes the live workflow (from the n8n API) and the new file and writes a merged
payload in which, for every node that already exists on the instance (matched by node name):

  * credentials             are kept (the ones you attached),
  * Google Sheets           documentId and sheetName are kept (the spreadsheet and tab you picked),
  * disabled                is kept (e.g. the Telegram Trigger you enabled on the cloud),
  * webhookId               is kept (so Telegram/webhook URLs don't change).

A node that is NEW in the shipped file has no counterpart on the instance, so it gets a credential of the same
kind already in use on that workflow (e.g. a new Telegram node reuses your Telegram credential).

Everything else - node code, parameters, connections - comes from the new file. Only keys the n8n REST API
accepts are written (name, nodes, connections, settings).

Usage: merge-workflow.py <live-workflow.json> <shipped-workflow.json> <merged-out.json>
"""
import json
import sys

# `settings` keys accepted by the n8n public API's workflow update; anything else (e.g. keys from a newer n8n
# export) is dropped so the request is not rejected.
ALLOWED_SETTINGS = {
    "executionOrder", "saveExecutionProgress", "saveManualExecutions", "saveDataErrorExecution",
    "saveDataSuccessExecution", "executionTimeout", "errorWorkflow", "timezone", "callerPolicy", "callerIds",
}
PLACEHOLDER = "CONFIGURE_ME"


def merge(old, new):
    old_nodes = {n["name"]: n for n in old.get("nodes", [])}

    known = {}                                   # credential kind -> a real credential already used here
    for n in old.get("nodes", []):
        for kind, cred in (n.get("credentials") or {}).items():
            if cred and cred.get("id") and cred["id"] != PLACEHOLDER:
                known.setdefault(kind, cred)

    stats = {"kept": 0, "new": 0, "new_nodes_wired": [], "new_nodes_unwired": []}
    for node in new["nodes"]:
        prev = old_nodes.get(node["name"])
        if prev is not None:
            stats["kept"] += 1
            prev_creds = prev.get("credentials") or {}
            if prev_creds:
                node["credentials"] = {**(node.get("credentials") or {}), **prev_creds}
            if node.get("type") == "n8n-nodes-base.googleSheets":
                for key in ("documentId", "sheetName"):
                    if key in (prev.get("parameters") or {}):
                        node.setdefault("parameters", {})[key] = prev["parameters"][key]
            if prev.get("disabled"):
                node["disabled"] = True
            else:
                node.pop("disabled", None)
            if prev.get("webhookId"):
                node["webhookId"] = prev["webhookId"]
        else:
            stats["new"] += 1
            kinds = list((node.get("credentials") or {}).keys())
            if not kinds:
                continue                         # a node that needs no credential (IF, Code, ...): nothing to wire
            wired = False
            for kind in kinds:
                if kind in known:
                    node["credentials"][kind] = known[kind]
                    wired = True
            (stats["new_nodes_wired"] if wired else stats["new_nodes_unwired"]).append(node["name"])

    body = {k: new[k] for k in ("name", "nodes", "connections") if k in new}
    body["settings"] = {k: v for k, v in (new.get("settings") or {}).items() if k in ALLOWED_SETTINGS}
    return body, stats


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    with open(argv[1], encoding="utf-8") as f:
        old = json.load(f)
    with open(argv[2], encoding="utf-8") as f:
        new = json.load(f)
    body, stats = merge(old, new)
    with open(argv[3], "w", encoding="utf-8") as f:
        json.dump(body, f)
    print("Merged: kept the wiring of %d existing node(s), %d new node(s)." % (stats["kept"], stats["new"]))
    if stats["new_nodes_wired"]:
        print("  New nodes given an existing credential: " + ", ".join(stats["new_nodes_wired"]))
    if stats["new_nodes_unwired"]:
        print("  New nodes with NO credential to reuse (attach one in the n8n editor): " + ", ".join(stats["new_nodes_unwired"]))


if __name__ == "__main__":
    main(sys.argv)
