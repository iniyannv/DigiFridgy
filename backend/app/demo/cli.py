"""Terminal remote for a running server (same actions as the /demo page).

    python -m app.demo.cli buy weekly
    python -m app.demo.cli advance 3
    python -m app.demo.cli sweep
    python -m app.demo.cli text "what's expiring?"      # mock Photon only
    python -m app.demo.cli state
    python -m app.demo.cli reset [--wipe-nessie]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import httpx


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.demo.cli")
    p.add_argument("--url", default=os.environ.get("DIGIFRIDGEY_URL", "http://127.0.0.1:8000"))
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("buy")
    b.add_argument("basket", nargs="?", default="weekly")
    a = sub.add_parser("advance")
    a.add_argument("days", type=float)
    a.add_argument("--hours", type=float, default=0)
    sub.add_parser("sweep")
    sub.add_parser("tick")
    sub.add_parser("state")
    r = sub.add_parser("reset")
    r.add_argument("--wipe-nessie", action="store_true")
    t = sub.add_parser("text")
    t.add_argument("message")
    t.add_argument("--handle", default="+15555550123")
    args = p.parse_args(argv)

    headers = {"x-demo-token": os.environ["DEMO_TOKEN"]} if os.environ.get("DEMO_TOKEN") else {}
    with httpx.Client(base_url=args.url, timeout=30, headers=headers) as c:
        if args.cmd == "buy":
            resp = c.post("/demo/buy", params={"basket": args.basket})
        elif args.cmd == "advance":
            resp = c.post("/demo/advance", params={"days": args.days, "hours": args.hours})
        elif args.cmd == "sweep":
            resp = c.post("/demo/sweep")
        elif args.cmd == "tick":
            resp = c.post("/demo/tick")
        elif args.cmd == "reset":
            resp = c.post("/demo/reset", params={"wipe_nessie": args.wipe_nessie})
        elif args.cmd == "text":
            resp = c.post("/demo/mock/text", json={"handle": args.handle, "text": args.message})
        else:
            resp = c.get("/demo/state")
    if resp.status_code >= 400:
        print(f"Error {resp.status_code}: {resp.text}", file=sys.stderr)
        return 1
    data = resp.json()
    if args.cmd == "text":
        for row in data["conversation"][-4:]:
            who = "you  " if row["from"] == "user" else "fridge"
            print(f"[{who}] {row['text']}\n")
    else:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
