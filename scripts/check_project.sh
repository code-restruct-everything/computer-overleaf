#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

is_ignored() {
  local path="$1"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git check-ignore --no-index -q "$path"
    return
  fi
  [ -f .gitignore ] || return 1
  while IFS= read -r pattern; do
    case "$pattern" in
      ""|\#*) continue ;;
      */)
        case "$path" in
          "$pattern"*|${pattern%/}) return 0 ;;
        esac
        ;;
      "$path") return 0 ;;
    esac
  done < .gitignore
  return 1
}

echo "== JSON syntax =="
python3 -m json.tool ops/service.manifest.json >/dev/null

echo "== required files =="
[ -f README.md ]
[ -f variables.env.example ]
[ -f quadlet/overleaf-net.network ]
[ -f quadlet/mongo.container ]
[ -f quadlet/redis.container ]
[ -f quadlet/overleaf.container ]
[ -f scripts/check_project.sh ]
[ -f scripts/init_mongo_replica_set.sh ]

echo "== gitignore coverage =="
if [ -f variables.env ]; then
  is_ignored variables.env || { echo "variables.env is not ignored"; exit 1; }
fi
if [ -d data ]; then
  is_ignored data/ || { echo "data/ is not ignored"; exit 1; }
fi

echo "== sensitive manifest scan =="
if rg -n -i "(password|passwd|private_key|apikey|api_key|access_key|refresh_token|client_secret|invite_token_secret=.+)" ops/service.manifest.json; then
  echo "sensitive-looking field found"
  exit 1
fi

echo "== quadlet sanity =="
for f in quadlet/*.container quadlet/*.network; do
  grep -q "^\[Unit\]" "$f" || { echo "$f missing [Unit] section"; exit 1; }
done
grep -q '^PublishPort=192\.168\.3\.11:18437:80$' quadlet/overleaf.container || {
  echo "overleaf host port must be 192.168.3.11:18437"
  exit 1
}

echo "OK"
