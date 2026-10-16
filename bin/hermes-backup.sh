#!/usr/bin/env bash
# hermes-backup.sh: mirror Hermes agent state into a git repo, encrypt secrets,
# scan for leaks, then commit and push only when something changed.
# Usage: hermes-backup.sh ["optional commit message"]
set -Eeuo pipefail
umask 077
shopt -s dotglob nullglob
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# ---- Settings (override in ~/.config/hermes-backup.env) ----
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
REPO="${REPO:-$HOME/agent-backup}"
EXTRA_DIRS="${EXTRA_DIRS:-$HOME/workspace/brain}"   # space-separated extra folders
STATE_DAY="${STATE_DAY:-7}"            # 1=Mon..7=Sun: day the encrypted history snapshot runs; "daily" or "never"
MAX_STATE_MB="${MAX_STATE_MB:-20}"     # skip the history snapshot if larger
HC_URL="${HC_URL:-}"                   # healthchecks.io ping URL (optional but recommended)
CACHE_DIR="$HOME/.local/state/hermes-backup"
RECIPIENTS="$REPO/.age-recipient"

log()  { logger -t hermes-backup -- "$*" 2>/dev/null || true; echo "$(date -Is) $*"; }
ping_hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL$1" || true; }
fail() { log "FAILED: $*"; ping_hc /fail; exit 1; }
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$CACHE_DIR"
exec 9>"$CACHE_DIR/lock"
flock -n 9 || { log "another backup is running; skipping"; exit 0; }

for bin in git rsync age sqlite3 gitleaks sha256sum; do
  command -v "$bin" >/dev/null || fail "missing tool: $bin"
done
[ -s "$RECIPIENTS" ] || fail "no age public key in $RECIPIENTS"
grep -q 'AGE-SECRET-KEY' "$RECIPIENTS" && fail "$RECIPIENTS holds a PRIVATE key; replace it with the age1... public key"
[ -d "$HERMES_HOME" ] || fail "HERMES_HOME not found: $HERMES_HOME"

cd "$REPO"
mkdir -p hermes extra secrets state meta/systemd-user meta/systemd-system
ping_hc /start

# ---- 1. Mirror plain files ----
rsync -a --delete --delete-excluded --exclude-from="$REPO/backup.exclude" "$HERMES_HOME/" "$REPO/hermes/"
for d in $EXTRA_DIRS; do
  [ -d "$d" ] || { log "extra dir missing, skipped: $d"; continue; }
  name=$(basename "$d")
  mkdir -p "$REPO/extra/$name"
  rsync -a --delete --delete-excluded --exclude-from="$REPO/backup.exclude" "$d/" "$REPO/extra/$name/"
done

# ---- 2. Encrypt secrets (re-encrypt only when the plaintext changed) ----
declare -A seen=()
encrypt_if_changed() {   # $1 = source path, $2 = flat name
  local new old
  new=$(sha256sum "$1" | cut -d' ' -f1)
  old=$(cat "$CACHE_DIR/$2.sha256" 2>/dev/null || true)
  if [ ! -f "secrets/$2.age" ] || [ "$new" != "$old" ]; then
    age -R "$RECIPIENTS" -o "secrets/$2.age.tmp" "$1"
    mv "secrets/$2.age.tmp" "secrets/$2.age"
    echo "$new" > "$CACHE_DIR/$2.sha256"
  fi
  seen["$2"]=1
}
while IFS= read -r -d '' f; do
  rel="${f#./}"
  encrypt_if_changed "$HERMES_HOME/$rel" "${rel//\//__}"
done < <(cd "$HERMES_HOME" && find . \( -path ./hermes-agent -o -path ./state-snapshots -o -path ./backups \) -prune -o -type f \
          \( -name .env -o -name 'auth.json' -o -name 'honcho.json' \) -print0)
for f in secrets/*.age; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .age)
  [ -n "${seen[$n]:-}" ] || { rm -f "$f" "$CACHE_DIR/$n.sha256"; log "removed stale secret $n"; }
done

# ---- 3. Encrypted history snapshot (state.db + sessions/), size-capped ----
if [ "$STATE_DAY" = daily ] || [ "$STATE_DAY" = "$(date +%u)" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/stage"
  : > "$tmp/fingerprint"
  while IFS= read -r -d '' db; do
    rel="${db#./}"
    mkdir -p "$tmp/stage/$(dirname "$rel")"
    sqlite3 "$HERMES_HOME/$rel" ".backup '$tmp/stage/$rel'"
    { echo "$rel"; sqlite3 "$tmp/stage/$rel" .dump | sha256sum; } >> "$tmp/fingerprint"
  done < <(cd "$HERMES_HOME" && find . \( -path ./hermes-agent -o -path ./node -o -path ./bin \) -prune -o -type f -name "*.db" ! -name verification_evidence.db -print0)
  while IFS= read -r -d '' s; do
    rel="${s#./}"
    mkdir -p "$tmp/stage/$rel"
    rsync -a "$HERMES_HOME/$rel/" "$tmp/stage/$rel/"
    { echo "$rel"; tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
        -cf - -C "$tmp/stage/$rel" . | sha256sum; } >> "$tmp/fingerprint"
  done < <(cd "$HERMES_HOME" && find . -path ./hermes-agent -prune -o -type d -name sessions -print0)
  new=$(sha256sum "$tmp/fingerprint" | cut -d' ' -f1)
  old=$(cat "$CACHE_DIR/state.sha256" 2>/dev/null || true)
  if [ "$new" != "$old" ] || [ ! -f state/history.tar.gz.age ]; then
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -C "$tmp/stage" . \
      | gzip -n -6 > "$tmp/history.tar.gz"
    size_mb=$(( $(stat -c %s "$tmp/history.tar.gz") / 1048576 ))
    if [ "$size_mb" -gt "$MAX_STATE_MB" ]; then
      log "WARNING: history snapshot is ${size_mb} MB (limit ${MAX_STATE_MB} MB); not stored"
    else
      age -R "$RECIPIENTS" -o state/history.tar.gz.age "$tmp/history.tar.gz"
      echo "$new" > "$CACHE_DIR/state.sha256"
    fi
  fi
fi

# ---- 4. Server context ----
{
  echo "hermes_version: $(hermes --version 2>/dev/null | head -n1 || echo unknown)"
  echo "hermes_commit: $(git -C "$HERMES_HOME/hermes-agent" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "os: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
} > meta/versions.txt
crontab -l > meta/crontab.txt 2>/dev/null || : > meta/crontab.txt
rsync -a --delete --include='hermes*' --include='hermes*/**' --exclude='*' "$HOME/.config/systemd/user/" meta/systemd-user/ 2>/dev/null || true
rsync -a --delete --include='hermes*' --include='hermes*/**' --exclude='*' /etc/systemd/system/ meta/systemd-system/ 2>/dev/null || true

# ---- 5. Leak scan on every plain-text folder (blocks the commit on any finding) ----
for d in hermes extra meta; do
  gitleaks dir --redact --no-banner --log-level error "$REPO/$d" \
    || fail "gitleaks found a possible secret in $d/. Nothing was committed. Run: gitleaks dir --redact $REPO/$d"
done

# ---- 6. Commit and push only if something changed ----
git add -A
if git diff --cached --quiet; then
  log "no changes"
  ping_hc ""
  exit 0
fi
count=$(git diff --cached --name-only | wc -l)
areas=$(git diff --cached --name-only | cut -d/ -f1-2 | sort -u | head -n 8 | paste -sd, - | sed 's/,/, /g')
msg="${1:-backup $(date +%F): $count file(s) changed}"
git commit -q -m "$msg" -m "Changed: $areas"
git push -q origin main
log "pushed $(git rev-parse --short HEAD): $count file(s)"
ping_hc ""
