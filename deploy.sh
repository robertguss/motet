#!/usr/bin/env bash
# Builds the React Dashboard SPA, syncs MoDB + Motet to motet.exe.xyz, runs Mo tests remotely,
# installs static public/ assets + CLI, restarts motet-server & motet-watch, and verifies MoDB.
set -euo pipefail

HOST="${MOTET_DEPLOY_HOST:-motet.exe.xyz}"
SSH_KEY="${MOTET_SSH_KEY:-$HOME/.ssh/yoyo_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o BatchMode=yes)
if [ -f "$SSH_KEY" ]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MODB_DIR="${MODB_DIR:-$(cd "$REPO_DIR/../modb" && pwd)}"

if [ -d "$REPO_DIR/frontend" ]; then
  echo "Building Motet Dashboard SPA -> public/ ..."
  (cd "$REPO_DIR/frontend" && npm run build)
fi

echo "Syncing $MODB_DIR -> $HOST:~/modb ..."
tar -C "$MODB_DIR" --exclude='.git' --exclude='*.modb*' --exclude='*.bc' -cf - mo.toml src | \
  ssh "${SSH_OPTS[@]}" "$HOST" 'mkdir -p ~/modb && tar -C ~/modb -xf -'

echo "Syncing $REPO_DIR -> $HOST:~/motet ..."
tar -C "$REPO_DIR" \
  --exclude='.git' \
  --exclude='.motet/*.modb*' \
  --exclude='*.modb*' \
  --exclude='.motet/*.sqlite*' \
  --exclude='*.sqlite*' \
  --exclude='*.bc' \
  --exclude='frontend/node_modules' \
  -cf - . | \
  ssh "${SSH_OPTS[@]}" "$HOST" 'mkdir -p ~/motet ~/.local/share/motet/skills ~/.local/share/motet/public && tar -C ~/motet -xf -'

ssh "${SSH_OPTS[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/motet"
mo test store.mo
mo test tools.mo
mo test brain.mo
mo test telegram.mo
mo test migrate-sqlite.mo
mo test main.mo
mo test server.mo
cp -r --update=none "$HOME/motet/skills/." "$HOME/.local/share/motet/skills/"
if [ -d "$HOME/motet/public" ]; then
  rm -rf "$HOME/.local/share/motet/public"
  cp -r "$HOME/motet/public" "$HOME/.local/share/motet/public"
fi
mo install "$HOME/motet/main.mo" \
  --name motet \
  --bin-dir "$HOME/.local/bin" \
  --root "$HOME/.local/share/motet"
sudo systemctl restart motet-server.service motet-watch.service

healthy=0
for _ in $(seq 1 15); do
  if curl -sf http://127.0.0.1:8000/v1/health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done
systemctl is-active motet-server.service motet-watch.service
if [ "$healthy" -ne 1 ]; then
  echo "error: motet-server /v1/health did not become ready within 15s" >&2
  exit 1
fi
curl -sf http://127.0.0.1:8000/v1/health && echo ""
motet verify
REMOTE
