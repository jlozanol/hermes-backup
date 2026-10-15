#!/usr/bin/env python3
"""fetch_emails.py: fetch the last 24h of Gmail via Composio and save it for the morning brief.

Runs on the SERVER (systemd user timer), outside the agent sandbox, so the
Composio login in ~/.composio is never visible to the agent. Writes
~/workspace/emails.json atomically; process_emails.py (inside the sandbox) reads it.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

OUT = os.path.expanduser(os.environ.get("EMAILS_JSON", "~/workspace/emails.json"))
QUERY = {"query": "in:inbox newer_than:1d", "max_results": 25}


def find_composio():
    for c in (shutil.which("composio"), os.path.expanduser("~/.local/bin/composio"),
              "/usr/local/bin/composio", os.path.expanduser("~/.composio/bin/composio")):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def fetch():
    composio = find_composio()
    if not composio:
        return {"successful": False, "error": "Composio CLI not found on the server"}
    try:
        r = subprocess.run([composio, "execute", "GMAIL_FETCH_EMAILS", "--data", json.dumps(QUERY)],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return {"successful": False, "error": "Composio call timed out after 120s"}
    if r.returncode != 0:
        return {"successful": False, "error": (r.stderr.strip() or "composio call failed")[:500]}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"successful": False, "error": "Could not parse Composio output as JSON"}


def inline_stored(result):
    """Large Composio responses are saved to a file (storedInFile/outputFilePath); pull them back in."""
    if not (result.get("storedInFile") and result.get("outputFilePath")):
        return result
    path = os.path.expanduser(result["outputFilePath"])
    try:
        with open(path) as f:
            stored = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        return {"successful": False, "error": f"Composio output file could not be read: {e}"}
    data = stored.get("data", stored) if isinstance(stored, dict) else stored
    if isinstance(data, list):
        data = {"messages": data}
    if isinstance(data, dict) and "messages" not in data:
        for v in data.values():
            if isinstance(v, dict) and "messages" in v:
                data = v
                break
    merged = dict(result)
    merged["data"] = data if isinstance(data, dict) else {}
    if isinstance(stored, dict) and "successful" in stored:
        merged["successful"] = stored["successful"]
    return merged


def main():
    result = inline_stored(fetch())
    payload = {"fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "result": result}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT), prefix=".emails.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, OUT)
    ok = result.get("successful", False)
    data = result.get("data") if isinstance(result.get("data"), dict) else {}
    n = len(data.get("messages", [])) if ok else 0
    print(f"fetch {'OK' if ok else 'FAILED'}: {n} message(s) -> {OUT}" + ("" if ok else f" ({result.get('error')})"))
    if ok and "messages" not in data:
        print(f"warning: no 'messages' field found; data keys: {list(data.keys())}; response keys: {list(result.keys())}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
