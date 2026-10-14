"""Prepares a fresh copy of the demo vault. Standard library only.

1. Shifts trail and sidecar timestamps by whole days so the newest trail session lands
   today. Wall-clock times are kept, so "Tuesday 14:05" stays 14:05 in any time zone.
2. Stamps each file with the `com.flamingo.id` xattr named in its sidecar (xattrs do not
   survive git), so rename healing works in the demo.
"""
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone

vault = sys.argv[1]
state = os.path.join(vault, ".flamingo")
trail_path = os.path.join(state, "trail.jsonl")

with open(trail_path) as f:
    events = [json.loads(line) for line in f if line.strip()]
# Fixture times are wall-clock in the fixture's zone (+08:00); keep the wall clock, not the instant.
fixture_tz = timezone(timedelta(hours=8))
walls = [datetime.fromisoformat(e["at"].replace("Z", "+00:00")).astimezone(fixture_tz).replace(tzinfo=None) for e in events]
shift = timedelta(days=(date.today() - max(walls).date()).days)

with open(trail_path, "w") as f:
    for e, wall in zip(events, walls):
        e["at"] = (wall + shift).astimezone().astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")

stamp = re.compile(r"^- \[(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\]", re.M)
stamped = 0
for root, _, files in os.walk(os.path.join(state, "notes")):
    for name in files:
        if not name.endswith(".md"):
            continue
        path = os.path.join(root, name)
        with open(path) as f:
            text = f.read()
        text = stamp.sub(lambda m: "- [" + (datetime.strptime(m[1], "%Y-%m-%d %H:%M") + shift).strftime("%Y-%m-%d %H:%M") + "]", text)
        with open(path, "w") as f:
            f.write(text)
        front = dict(re.findall(r"^(target|id): (.+)$", text.split("\n---", 1)[0], re.M))
        target = os.path.join(vault, front.get("target", ""))
        if "id" in front and os.path.exists(target):
            subprocess.run(["xattr", "-w", "com.flamingo.id", front["id"], target], check=True)
            stamped += 1

print(f"shifted {shift.days} days, stamped {stamped} files", file=sys.stderr)
