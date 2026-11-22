#!/usr/bin/env bash
# Syncs local Motet code to motet.exe.xyz, runs tests remotely, reinstalls CLI, and restarts services.
set -euo pipefail

HOST="${MOTET_DEPLOY_HOST:-motet.exe.xyz}"
SSH_KEY="${MOTET_SSH_KEY:-$HOME/.ssh/yoyo_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o BatchMode=yes)
if [ -f "$SSH_KEY" ]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Syncing $REPO_DIR -> $HOST:~/motet ..."
tar -C "$REPO_DIR" --exclude='.motet/*.sqlite*' --exclude='*.sqlite*' --exclude='*.bc' -cf - . | \
  ssh "${SSH_OPTS[@]}" "$HOST" 'mkdir -p ~/motet ~/.local/share/motet/skills && tar -C ~/motet -xf -'

ssh "${SSH_OPTS[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME/motet"
mo test main.mo
mo test server.mo
cp -r --update=none "$HOME/motet/skills/." "$HOME/.local/share/motet/skills/"
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
