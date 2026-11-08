#!/usr/bin/env bash
# Starts the backend on :8001 and exposes it at https://digifridgy.soumilvoona.me
set -e
cd "$(dirname "$0")"
cloudflared tunnel --config cloudflared.yml run digifridgy &
TUNNEL=$!
trap 'kill $TUNNEL' EXIT
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8001
