#!/usr/bin/env python3
"""Filters Claude stream-json output into readable status lines."""
import sys
import json

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    t = msg.get("type", "")
    if t == "assistant" and "message" in msg:
        for block in msg["message"].get("content", []):
            bt = block.get("type", "")
            if bt == "text":
                print(block["text"], flush=True)
            elif bt == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input", {})
                if name == "Read":
                    p = inp.get("file_path", "")
                    print(f"  >> Read {p.split('/')[-1]}", flush=True)
                elif name == "Edit":
                    p = inp.get("file_path", "")
                    print(f"  >> Edit {p.split('/')[-1]}", flush=True)
                elif name == "Write":
                    p = inp.get("file_path", "")
                    print(f"  >> Write {p.split('/')[-1]}", flush=True)
                elif name == "Bash":
                    cmd = inp.get("command", "")[:80]
                    print(f"  >> Bash: {cmd}", flush=True)
                elif name in ("Glob", "Grep"):
                    pat = inp.get("pattern", "")
                    print(f"  >> {name}: {pat}", flush=True)
                else:
                    print(f"  >> {name}", flush=True)
    elif t == "result":
        for block in msg.get("content", []):
            if block.get("type") == "text":
                print(block["text"], flush=True)
