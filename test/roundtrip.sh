#!/usr/bin/env bash
# Backup/restore round trip on a throwaway data dir, using a small image (alpine).
# Needs Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ENV_FILE="$TMP/env" YES=1
cat >"$ENV_FILE" <<EOF
HERMES_IMAGE=${TEST_IMAGE:-alpine:3.20}
HERMES_DATA_DIR=$TMP/data
BACKUP_DIR=$TMP/backups
EOF
M="$ROOT/manage.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

newest() { # newest FILE... -> path of the most recently modified existing file
  local f best=""
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if [[ -z "$best" || "$f" -nt "$best" ]]; then best="$f"; fi
  done
  echo "$best"
}

seed() {
  rm -rf "$TMP/data"
  mkdir -p "$TMP/data/memories"
  echo "KEY=secret" >"$TMP/data/.env"
  echo "model: x" >"$TMP/data/config.yaml"
  echo "remember" >"$TMP/data/memories/a.md"
}

check() {
  [[ "$(cat "$TMP/data/memories/a.md")" == "remember" ]] || fail "$1: memory file differs"
  [[ "$(cat "$TMP/data/.env")" == "KEY=secret" ]] || fail "$1: .env differs"
  [[ -f "$TMP/data/config.yaml" ]] || fail "$1: config.yaml missing"
}

echo "== plain backup, restore into empty dir"
seed
"$M" backup
archive="$(newest "$TMP"/backups/hermes-*.tar.gz)"
[[ -f "$archive.sha256" ]] || fail "checksum file not written"
rm -rf "$TMP/data"
"$M" restore "$archive" --yes --no-start
check "plain restore"

echo "== restore over existing data moves it aside"
echo "CHANGED" >"$TMP/data/.env"
"$M" restore "$archive" --yes --no-start
check "restore over existing"
ls -d "$TMP"/data.pre-restore-* >/dev/null 2>&1 || fail "previous data was not preserved"

echo "== tampered archive is refused"
bad="$TMP/backups/bad.tar.gz"
cp "$archive" "$bad"
sed 's/  .*/  bad.tar.gz/' "$archive.sha256" >"$bad.sha256"
echo "x" >>"$bad"
if "$M" restore "$bad" --yes --no-start 2>/dev/null; then fail "tampered archive was accepted"; fi
check "after refused restore"

if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  echo "== age-encrypted backup and restore"
  age-keygen -o "$TMP/key.txt" 2>/dev/null
  {
    echo "BACKUP_AGE_RECIPIENT=$(age-keygen -y "$TMP/key.txt")"
    echo "BACKUP_AGE_IDENTITY=$TMP/key.txt"
  } >>"$ENV_FILE"
  sleep 1 # archive names have one-second resolution
  "$M" backup
  enc="$(newest "$TMP"/backups/hermes-*.tar.gz.age)"
  if tar -tzf "$enc" >/dev/null 2>&1; then fail "encrypted archive is readable as plain tar"; fi
  rm -rf "$TMP/data"
  "$M" restore "$enc" --yes --no-start
  check "encrypted restore"
else
  echo "== skipping encrypted test (age not installed)"
fi

echo "OK"
