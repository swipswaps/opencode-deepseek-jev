#!/usr/bin/env bash
# restart-opencode-stack.sh
# Restarts the opencode stack with the override file merged.
# Run as normal user; sudo is invoked only for docker.

set -u

COMPOSE_DIR=/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/docker
cd "$COMPOSE_DIR" || exit 3

echo "== validating merged compose =="
sudo docker compose config >/dev/null || {
  echo "compose config failed"; exit 2;
}
echo "compose ok"

echo
echo "== recreating opencode-web and caddy =="
sudo docker compose up -d --force-recreate opencode-web caddy

sleep 10

echo
echo "== mounts =="
sudo docker inspect opencode-deepseek-web --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

echo
echo "== path visibility =="
for p in \
  /home/owner \
  /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes \
  /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo \
  /home/owner/Documents/6ac64c8c-d70c-83ea-8512-7b449377d861/notes
do
  if sudo docker exec opencode-deepseek-web test -d "$p"; then
    echo "  OK   $p"
  else
    echo "  MISS $p"
  fi
done

echo
echo "done."
