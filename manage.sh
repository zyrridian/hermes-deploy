#!/usr/bin/env bash
# manage.sh - install, back up, restore and update a self-hosted Hermes Agent.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$PWD"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
CONTAINER="hermes"
YES="${YES:-0}"
export ENV_FILE YES # inherited by the pre-update backup subprocess

say() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

confirm() {
  [[ "$YES" == 1 ]] && return 0
  local a
  read -r -p "$1 [Y/n] " a
  [[ -z "$a" || "$a" =~ ^[Yy] ]]
}

# environment

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  TRACK="${HERMES_TRACK:-nousresearch/hermes-agent:stable}"
  IMAGE="${HERMES_IMAGE:-$TRACK}"
  DATA_DIR="$(realpath -m "${HERMES_DATA_DIR:-$ROOT/data}")"
  BACKUP_DIR="$(realpath -m "${BACKUP_DIR:-$ROOT/backups}")"
  KEEP="${BACKUP_KEEP:-14}"
  # compose reads these too
  export HERMES_IMAGE="$IMAGE" HERMES_DATA_DIR="$DATA_DIR"
}

set_env() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$ENV_FILE" ]] && grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$ENV_FILE" >"$tmp"
  else
    {
      [[ -f "$ENV_FILE" ]] && cat "$ENV_FILE"
      printf '%s=%s\n' "$key" "$val"
    } >"$tmp"
  fi
  cat "$tmp" >"$ENV_FILE"
  rm -f "$tmp"
}

dc() {
  local -a envf=()
  [[ -f "$ENV_FILE" ]] && envf=(--env-file "$ENV_FILE")
  docker compose ${envf[@]+"${envf[@]}"} "$@"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run: ./manage.sh install"
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing."
  docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon (is it running? is your user in the 'docker' group?)"
}

container_exists() { docker inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" == true ]]; }
restart_count() { docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null || echo -1; }

# Run a one-shot command as root in the Hermes image with the data dir at
# /opt/data (the image entrypoint is bypassed on purpose).
#   DATA_MODE=ro|rw (default rw)   IN_DATA_STDIN=1 keeps stdin open
in_data() {
  local cmd="$1"
  shift
  local -a extra=()
  [[ "${IN_DATA_STDIN:-0}" == 1 ]] && extra=(-i)
  docker run --rm --user 0 ${extra[@]+"${extra[@]}"} --entrypoint "$cmd" \
    -v "$DATA_DIR:/opt/data:${DATA_MODE:-rw}" "$IMAGE" "$@"
}

has_config() { DATA_MODE=ro in_data test -f /opt/data/.env; }

wait_healthy() {
  local before after
  before="$(restart_count)"
  say "Waiting 20s to confirm the container stays up..."
  sleep 20
  after="$(restart_count)"
  if container_running && [[ "$before" == "$after" ]]; then
    say "Hermes is running."
    return 0
  fi
  warn "Hermes is not healthy. Recent logs:"
  docker logs --tail 40 "$CONTAINER" >&2 || true
  return 1
}

image_digest() { docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || true; }

pin_image() {
  local d
  d="$(image_digest "$IMAGE")"
  if [[ -n "$d" && "$d" != "$IMAGE" ]]; then
    set_env HERMES_IMAGE "$d"
    load_env
    say "Pinned image: $d"
  fi
}

# install

ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  say "Docker is not installed."
  confirm "Install Docker Engine with Docker's official script (get.docker.com)?" || die "Docker is required."
  command -v curl >/dev/null 2>&1 || die "curl is required to install Docker."
  local -a sudo=()
  [[ $EUID -ne 0 ]] && sudo=(sudo)
  curl -fsSL https://get.docker.com | ${sudo[@]+"${sudo[@]}"} sh
  if ! docker info >/dev/null 2>&1; then
    if [[ $EUID -ne 0 ]]; then
      ${sudo[@]+"${sudo[@]}"} usermod -aG docker "$USER"
      say "Docker is installed and '$USER' was added to the docker group."
      say "Log out and back in, then run ./manage.sh install again."
      exit 0
    fi
    die "Docker was installed but the daemon is not reachable."
  fi
}

schedule_backup() {
  command -v crontab >/dev/null 2>&1 || {
    warn "cron not found; schedule './manage.sh backup' yourself."
    return 0
  }
  local entry="17 3 * * * cd '$ROOT' && ./manage.sh backup >> '$ROOT/backup.log' 2>&1"
  if crontab -l 2>/dev/null | grep -qF "cd '$ROOT' && ./manage.sh backup"; then
    return 0
  fi
  confirm "Schedule a daily backup at 03:17 (stops the agent for a few seconds)?" || return 0
  {
    crontab -l 2>/dev/null || true
    echo "$entry"
  } | crontab -
  say "Daily backup scheduled."
}

cmd_install() {
  local restore_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y)
        YES=1
        shift
        ;;
      --restore)
        restore_file="${2:?--restore needs an archive path}"
        shift 2
        ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  ensure_docker
  require_docker
  [[ -f "$ENV_FILE" ]] || {
    cp .env.example "$ENV_FILE"
    say "Created $ENV_FILE"
  }
  chmod 600 "$ENV_FILE"
  load_env
  mkdir -p "$DATA_DIR"

  say "Pulling $IMAGE"
  docker pull "$IMAGE" >&2
  pin_image

  if [[ -n "$restore_file" ]]; then
    restore_archive "$restore_file" 0
  else
    if ! has_config; then
      say "First-time setup: the wizard asks for your model API key and chat platform."
      dc run --rm hermes setup
    fi
    dc up -d
    wait_healthy || die "Hermes did not start cleanly. See: ./manage.sh logs"
  fi

  schedule_backup
  cat >&2 <<'EOF'

Done. Next:
  ./manage.sh status      check health
  ./manage.sh logs        follow logs
  ./manage.sh backup      back up now (set BACKUP_AGE_RECIPIENT in .env first to encrypt)
EOF
}

# backup / restore

make_archive() {
  local out="$1"
  if [[ "$out" == *.age ]]; then
    DATA_MODE=ro in_data tar -czf - -C /opt/data . | age -r "$BACKUP_AGE_RECIPIENT" >"$out"
  else
    DATA_MODE=ro in_data tar -czf - -C /opt/data . >"$out"
  fi
}

STOPPED=0
resume() {
  if [[ "$STOPPED" == 1 ]]; then
    STOPPED=0
    say "Restarting Hermes..."
    dc start hermes || warn "Could not restart Hermes; run ./manage.sh start"
  fi
}

cmd_backup() {
  local hot=0 ext="tar.gz" out stamp
  [[ "${1:-}" == "--hot" ]] && hot=1
  require_docker
  load_env
  umask 077
  [[ -d "$DATA_DIR" ]] || die "Data directory $DATA_DIR does not exist; nothing to back up."

  if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
    command -v age >/dev/null 2>&1 || die "BACKUP_AGE_RECIPIENT is set but 'age' is not installed (apt install age)."
    ext="tar.gz.age"
  else
    warn "Backup will NOT be encrypted. It contains API keys and tokens; set BACKUP_AGE_RECIPIENT before copying it off this machine."
  fi

  mkdir -p "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$BACKUP_DIR/hermes-$stamp.$ext"

  trap resume EXIT
  if container_running; then
    if [[ "$hot" == 1 ]]; then
      warn "Hot backup: the SQLite state database may be captured mid-write."
    else
      say "Stopping Hermes briefly for a consistent snapshot..."
      dc stop hermes
      STOPPED=1
    fi
  fi

  say "Writing $out"
  make_archive "$out" || {
    rm -f "$out"
    die "Backup failed."
  }
  [[ "$ext" == "tar.gz" ]] && { tar -tzf "$out" >/dev/null || die "Archive failed verification."; }
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$out")" >"$(basename "$out").sha256")
  say "Backup written ($(du -h "$out" | cut -f1))"
  resume

  if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
    command -v rclone >/dev/null 2>&1 || die "BACKUP_RCLONE_REMOTE is set but rclone is not installed."
    say "Uploading to $BACKUP_RCLONE_REMOTE"
    rclone copyto "$out" "${BACKUP_RCLONE_REMOTE%/}/$(basename "$out")"
    rclone copyto "$out.sha256" "${BACKUP_RCLONE_REMOTE%/}/$(basename "$out").sha256"
  else
    warn "No BACKUP_RCLONE_REMOTE set: this backup only exists on this machine."
  fi

  local -a archives
  mapfile -t archives < <(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz "$BACKUP_DIR"/hermes-*.tar.gz.age 2>/dev/null || true)
  if ((${#archives[@]} > KEEP)); then
    local old
    for old in "${archives[@]:KEEP}"; do
      rm -f "$old" "$old.sha256"
    done
  fi
}

restore_archive() {
  local file="$1" start="$2"
  [[ -f "$file" ]] || die "Archive not found: $file"

  if [[ -f "$file.sha256" ]]; then
    (cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256" >&2) || die "Checksum mismatch; refusing to restore."
  else
    warn "No .sha256 next to the archive; skipping checksum verification."
  fi

  if [[ "$file" == *.age ]]; then
    command -v age >/dev/null 2>&1 || die "'age' is required to restore this archive."
    [[ -n "${BACKUP_AGE_IDENTITY:-}" && -r "${BACKUP_AGE_IDENTITY}" ]] || die "Set BACKUP_AGE_IDENTITY to your age key file."
  fi

  if [[ "$YES" != 1 ]]; then
    printf 'This replaces the agent state in %s with:\n  %s\n(existing data is moved aside, not deleted)\n' "$DATA_DIR" "$file" >&2
    local a
    read -r -p "Type 'restore' to continue: " a
    [[ "$a" == restore ]] || die "Aborted."
  fi

  if container_exists; then
    say "Stopping Hermes..."
    dc down
  fi

  # The data dir is owned by the container user and may be unreadable to the
  # host user, so look for content from inside a container, not with ls.
  if [[ -e "$DATA_DIR" ]] && [[ -n "$(DATA_MODE=ro in_data ls -A /opt/data 2>/dev/null || true)" ]]; then
    local aside
    aside="${DATA_DIR%/}.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    say "Moving existing data to $aside"
    mv "$DATA_DIR" "$aside"
  fi
  mkdir -p "$DATA_DIR"

  say "Extracting archive..."
  if [[ "$file" == *.age ]]; then
    age -d -i "$BACKUP_AGE_IDENTITY" <"$file" | IN_DATA_STDIN=1 in_data tar -xzpf - -C /opt/data
  else
    IN_DATA_STDIN=1 in_data tar -xzpf - -C /opt/data <"$file"
  fi || die "Extraction failed. Any previous data is preserved next to $DATA_DIR."

  say "State restored to $DATA_DIR"
  if [[ "$start" == 1 ]]; then
    dc up -d
    wait_healthy || die "Hermes did not start cleanly. See: ./manage.sh logs"
    warn "Never run two Hermes gateways on the same data or bot token. Stop the old host's agent."
  fi
}

cmd_restore() {
  local file="" start=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y)
        YES=1
        shift
        ;;
      --no-start)
        start=0
        shift
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        file="$1"
        shift
        ;;
    esac
  done
  [[ -n "$file" ]] || die "Usage: ./manage.sh restore <archive> [--yes] [--no-start]"
  require_docker
  load_env
  umask 077
  restore_archive "$file" "$start"
}

# update

cmd_update() {
  require_docker
  load_env
  local prev="$IMAGE" new

  if [[ "${1:-}" == "--rollback" ]]; then
    new="${HERMES_PREVIOUS_IMAGE:-}"
    [[ -n "$new" ]] || die "No previous image recorded; nothing to roll back to."
    warn "If the newer version already migrated config.yaml, restore the pre-update backup instead."
  else
    say "Backing up before updating..."
    "$ROOT/manage.sh" backup || die "Backup failed; not updating."
    say "Pulling $TRACK"
    docker pull "$TRACK" >&2
    new="$(image_digest "$TRACK")"
    [[ -n "$new" ]] || die "Could not resolve a digest for $TRACK."
    if [[ "$new" == "$prev" ]]; then
      say "Already up to date ($prev)."
      return 0
    fi
  fi

  set_env HERMES_PREVIOUS_IMAGE "$prev"
  set_env HERMES_IMAGE "$new"
  load_env
  say "Switching to $new"
  dc up -d
  if wait_healthy; then
    say "Update complete. Previous image kept for: ./manage.sh update --rollback"
    return 0
  fi
  warn "New version is unhealthy; going back to $prev"
  set_env HERMES_IMAGE "$prev"
  load_env
  dc up -d
  die "Rolled back to $prev. If config was migrated, restore the pre-update backup in $BACKUP_DIR."
}

# status

cmd_status() {
  require_docker
  load_env
  local rc=0 last="" f
  if container_running; then
    printf 'container : running (restarts: %s)\n' "$(restart_count)"
  else
    printf 'container : NOT running\n'
    rc=1
  fi
  printf 'image     : %s\n' "$IMAGE"
  [[ "$IMAGE" == *@sha256:* ]] || warn "Image is not pinned by digest; run ./manage.sh install or update."
  if container_running && docker port "$CONTAINER" 2>/dev/null | grep -qE '0\.0\.0\.0:|\[::\]:'; then
    warn "A container port is published on all interfaces; keep it on 127.0.0.1 unless it is behind authentication."
  fi
  printf 'data dir  : %s (%s free)\n' "$DATA_DIR" "$(df -Ph "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  for f in "$BACKUP_DIR"/hermes-*.tar.gz "$BACKUP_DIR"/hermes-*.tar.gz.age; do
    [[ -f "$f" ]] || continue
    if [[ -z "$last" || "$f" -nt "$last" ]]; then last="$f"; fi
  done
  if [[ -n "$last" ]]; then
    printf 'last backup: %s (%sh ago)\n' "$(basename "$last")" "$((($(date +%s) - $(stat -c %Y "$last")) / 3600))"
  else
    printf 'last backup: none\n'
    warn "No backups yet. Run ./manage.sh backup"
  fi
  return "$rc"
}

# dispatch

usage() {
  cat <<'EOF'
Usage: ./manage.sh <command>

  install [--yes] [--restore FILE]
                     Install Docker if needed, pin the image, run first-time setup
                     (or restore a backup), start Hermes, offer a daily backup
  status             Container state, image pin, exposure, disk, last backup
  logs               Follow logs
  start | stop | restart
  backup [--hot]     Back up all agent state (brief stop for a consistent snapshot)
  restore FILE [--yes] [--no-start]
                     Restore a backup (.tar.gz or .tar.gz.age)
  update [--rollback]
                     Back up, pull the tracked tag, re-pin, verify; --rollback reverts
  setup              Re-run the interactive setup wizard
  hermes <args>      Run the hermes CLI inside the container (e.g. hermes profile create x)
EOF
}

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    install) cmd_install "$@" ;;
    status) cmd_status ;;
    logs)
      require_docker
      load_env
      dc logs -f --tail 100 hermes
      ;;
    start | stop | restart)
      require_docker
      load_env
      dc "$cmd" hermes
      ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    update) cmd_update "$@" ;;
    setup)
      require_docker
      load_env
      dc run --rm hermes setup
      ;;
    hermes)
      require_docker
      load_env
      dc exec hermes hermes "$@"
      ;;
    help | -h | --help) usage ;;
    *)
      usage >&2
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
