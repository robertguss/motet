#!/usr/bin/env bash
# Builds the React Dashboard SPA, syncs Motet to motet.exe.xyz, runs Mo tests remotely,
# installs static public/ assets + CLI, and restarts motet-server & motet-watch.
set -euo pipefail

HOST="${MOTET_DEPLOY_HOST:-motet.exe.xyz}"
SSH_KEY="${MOTET_SSH_KEY:-$HOME/.ssh/yoyo_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o BatchMode=yes)
if [ -f "$SSH_KEY" ]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$REPO_DIR/frontend" ]; then
  echo "Building Motet Dashboard SPA -> public/ ..."
  (cd "$REPO_DIR/frontend" && npm run build)
fi

echo "Syncing $REPO_DIR -> $HOST:~/motet ..."
tar -C "$REPO_DIR" --exclude='.git' --exclude='.motet/*.sqlite*' --exclude='*.sqlite*' --exclude='*.bc' --exclude='frontend/node_modules' -cf - . | \
  ssh "${SSH_OPTS[@]}" "$HOST" 'mkdir -p ~/motet ~/.local/share/motet/skills ~/.local/share/motet/public && tar -C ~/motet -xf -'

ssh "${SSH_OPTS[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/motet"
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
  --root "$HOME/.local/share/motet" \
  --state-dir "$HOME/.local/share/motet"
sudo systemctl restart motet-server.service motet-watch.service
sleep 1
systemctl is-active motet-server.service motet-watch.service
curl -sf http://127.0.0.1:8000/v1/health && echo ""
REMOTE
