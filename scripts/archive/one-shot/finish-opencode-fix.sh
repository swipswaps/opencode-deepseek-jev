#!/usr/bin/env bash
# finish-opencode-fix.sh — run as a normal user, not with sudo.
# The script will call sudo only for docker.

set -u

SRC=/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/data/opencode.bak-20261007-151724/snapshot
DST=/home/owner/.local/share/opencode/snapshot
COMPOSE_DIR=/home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/repo/docker

echo "== 1/4 show current override =="
cat "$COMPOSE_DIR/docker-compose.override.yml"

echo
echo "== 2/4 merge snapshots (no sudo needed) =="
if [ -d "$SRC" ]; then
  mkdir -p "$DST"
  cp -rn "$SRC/." "$DST/"
  echo "snapshot entries in host store now:"
  find "$DST" -maxdepth 2 -mindepth 1 -type d | sort
else
  echo "source snapshot missing: $SRC"
fi

echo
echo "== 3/4 validate compose (needs sudo for docker) =="
cd "$COMPOSE_DIR" || exit 3
sudo docker compose -f docker-compose.yml config >/dev/null
if [ $? -ne 0 ]; then
  echo "compose config FAILED"
  exit 2
fi
echo "compose ok"

echo
echo "== 4/4 recreate opencode-web and caddy =="
sudo docker compose -f docker-compose.yml up -d --force-recreate opencode-web caddy

echo
echo "waiting 10 s for startup..."
sleep 10

echo
echo "== verify mounts =="
sudo docker inspect opencode-deepseek-web --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

echo
echo "== verify paths visible inside container =="
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
