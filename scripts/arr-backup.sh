#!/bin/bash
set -euo pipefail
#
# Backup essential Docker named volumes for arr-stack
#
# Usage:
#   ./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]
#
# Options:
#   --tar           Create a .tar.gz archive (recommended for off-NAS transfer)
#   --encrypt       Encrypt tarball with GPG symmetric encryption (requires --tar)
#   --prefix NAME   Pin every volume to the single prefix NAME instead of resolving
#                   each one across the compose projects present. Escape hatch only:
#                   the stack spans four projects, so one prefix cannot address it.
#   --usb DIR_NAME  Dynamically find USB device under /mnt/@usb/sd*/ containing DIR_NAME
#                   (device letters change on reboot, so never hardcode e.g. /mnt/@usb/sdd1)
#   --rotate-days N Delete tarballs older than N days AT THE DESTINATION. Opt-in and
#                   loud: every deletion is printed. Leave it off for any directory
#                   managed by scripts/backup-prune.sh - two retention policies on one
#                   directory is how the 2026-08-30 history loss happened (see below).
#
# Examples:
#   ./scripts/arr-backup.sh --tar                     # Backup to /tmp, create tarball
#   ./scripts/arr-backup.sh --tar --encrypt           # Backup + GPG encrypt
#   ./scripts/arr-backup.sh --tar ~/backups           # Backup to custom dir with tarball
#   ./scripts/arr-backup.sh --tar --usb arr-backups   # Auto-find USB, save to arr-backups/
#   ./scripts/arr-backup.sh --prefix media-stack      # Pin all volumes to one prefix
#   ./scripts/arr-backup.sh --tar /mnt/x --rotate-days 7   # Flat 7-day rotation at /mnt/x
#
# Tarballs are named arr-stack-backup-YYYYMMDD-HHMMSS.tar.gz. The seconds matter:
# scripts/backup-prune.sh keys its GFS tiers off that stamp, and a date-only name
# means two runs on the same day silently clobber each other.
#
# HISTORY: until 2026-08-30 this script named tarballs by DAY only and, whenever a
# destination directory was given, silently ran `find <dest> -mtime +7 -delete` with
# stderr suppressed. Pointing it at /volume1/docker/arr-stack-backups - a directory
# already under backup-prune.sh's GFS retention - therefore destroyed every backup
# older than a week without printing a word. It took out the entire 2026-08-16 set.
# Rotation is now opt-in (--rotate-days) and always prints what it removes.
#
# Pulling backup to another machine:
#   # Ugreen NAS (scp doesn't work with /tmp, use cat pipe):
#   ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
#
#   # Other systems (scp works normally):
#   scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
#
# Restoring a volume:
#   docker run --rm -v ./backup/gluetun-config:/source:ro \
#     -v PREFIX_gluetun-config:/dest alpine cp -a /source/. /dest/
#

# --- Failure notifications via Home Assistant webhook ---
notify_failure() {
  local msg="${1:-Backup failed}"
  echo "ERROR: ${msg}"
  if [ -n "${HA_WEBHOOK_URL:-}" ]; then
    curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Arr Stack: Backup Failed\",\"message\":\"${msg}\"}" || true
  fi
}
STEP="initialising"
trap 'notify_failure "Failed during: ${STEP}. Check /var/log/arr-backup.log"' ERR

# Derive stack directory from script location (scripts/ is one level below stack root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure critical services are running on ANY exit (normal, error, or interrupt)
ensure_services_running() {
  COMPOSE_FILE="$NAS_STACK_DIR/docker-compose.arr-stack.yml"
  [ -f "$COMPOSE_FILE" ] || return 0

  CRITICAL="gluetun pihole sonarr radarr prowlarr qbittorrent jellyfin sabnzbd"
  STOPPED=""

  for svc in $CRITICAL; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$"; then
      STOPPED="$STOPPED $svc"
    fi
  done

  if [ -n "$STOPPED" ]; then
    echo ""
    echo "SAFETY: Ensuring services are running:$STOPPED"
    docker compose -f "$COMPOSE_FILE" up -d $STOPPED 2>/dev/null
  fi
}
trap 'ensure_services_running' EXIT

# Find USB backup directory dynamically (device letters change on reboot)
# Searches /mnt/@usb/sd*/ for a subdirectory matching the given name,
# falling back to the first non-empty mounted device.
find_usb_dir() {
  local dir_name="$1"
  local usb_base="/mnt/@usb"

  # First: look for an existing backup directory by name
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    if [ -d "$dev$dir_name" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  # Fallback: first non-empty mounted USB device
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    # Check it's actually mounted (not just an empty mount point)
    if [ "$(ls -A "$dev" 2>/dev/null)" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  echo "ERROR: No USB device found under $usb_base" >&2
  return 1
}

# Parse arguments
CREATE_TAR=false
ENCRYPT=false
BACKUP_DIR=""
VOLUME_PREFIX=""
USB_DIR_NAME=""
TARBALL=""
ROTATE_DAYS=""
# One stamp for the whole run, captured once. Calling `date` twice can straddle a
# second boundary and produce a tarball whose name disagrees with its staging dir.
RUN_TS="$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --tar)
      CREATE_TAR=true
      shift
      ;;
    --encrypt)
      ENCRYPT=true
      shift
      ;;
    --prefix)
      VOLUME_PREFIX="$2"
      shift 2
      ;;
    --usb)
      USB_DIR_NAME="$2"
      shift 2
      ;;
    --rotate-days)
      ROTATE_DAYS="$2"
      shift 2
      ;;
    *)
      BACKUP_DIR="$1"
      shift
      ;;
  esac
done

if $ENCRYPT && ! $CREATE_TAR; then
  echo "ERROR: --encrypt requires --tar"
  exit 1
fi

if [ -n "$ROTATE_DAYS" ] && ! [[ "$ROTATE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --rotate-days requires a non-negative integer, got '$ROTATE_DAYS'"
  exit 1
fi

if $ENCRYPT && ! command -v gpg &>/dev/null; then
  echo "ERROR: gpg not found. Install gnupg to use --encrypt."
  exit 1
fi

# Resolve USB backup directory if --usb was specified
STEP="finding USB device"
if [ -n "$USB_DIR_NAME" ]; then
  BACKUP_DIR=$(find_usb_dir "$USB_DIR_NAME") || { notify_failure "Failed during: ${STEP}. No USB device found under /mnt/@usb/"; exit 1; }
  echo "USB device found: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
fi

STEP="inventorying docker volumes"
# There is no single volume prefix. The stack spans FOUR compose projects --
# arr-stack, arr-utilities, tailscale and magnetio -- and Docker names a volume
# `<project>_<name>`, so the prefix differs per volume.
#
# This script used to auto-detect ONE prefix (from gluetun, always `arr-stack`)
# and paste it in front of every name in the curated list below. When uptime-kuma
# moved into the arr-utilities project its volume became
# `arr-utilities_uptime-kuma-data`; the lookup for `arr-stack_uptime-kuma-data`
# found nothing, and the run printed "Skipping (volume not found)" and counted it
# as a benign skip. The summary line read "11 backed up, 1 skipped, 0 failed" --
# a clean-looking run in which a listed volume was silently unprotected. A project
# rename is invisible to a single-prefix assumption, and the failure mode was a
# success message with a skip in it.
ALL_VOLUMES=$(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
if [ -z "$ALL_VOLUMES" ]; then
  echo "ERROR: 'docker volume ls' returned nothing. Refusing to run: every volume" >&2
  echo "       would resolve to 'not found' and the backup would be empty." >&2
  notify_failure "Failed during: ${STEP}. docker volume ls returned no volumes."
  exit 1
fi

# Build the set of volumes referenced by some set of containers. Extra `docker ps`
# args come in as "$@" (none = running only; -a = running or stopped).
# Sets INVENTORY_VOLUMES; returns 1 with INVENTORY_ERROR set if the daemon could
# not be asked.
#
# The point of this function is to tell "no container references anything" apart
# from "I could not find out". Until 2026-08-31 both pipelines ended in
# `2>/dev/null || true`, so a docker failure and a genuinely empty result produced
# the same empty string. That is not a cosmetic difference: resolve_volume() reads
# an empty ATTACHED_VOLUMES as proof that every candidate is an orphan, and the
# volumes with more than one candidate then fail with "no container references any
# of them, running or stopped" -- a confident, specific, wrong reason that sends
# whoever reads it looking for a project rename that never happened.
#
# stderr is deliberately NOT silenced. When this fails the operator needs docker's
# own message ("permission denied", "Cannot connect to the Docker daemon"), and
# under cron that is the only place it can come from.
docker_volume_inventory() {
  local ids out
  INVENTORY_VOLUMES=""
  INVENTORY_ERROR=""

  if ! ids=$(docker ps "$@" -q); then
    INVENTORY_ERROR="'docker ps $* -q' failed -- cannot enumerate containers"
    return 1
  fi

  # No containers at all is a legal state, not a failure. Distinct from the branch
  # above precisely because this one asked successfully and the answer was "none".
  [ -n "$ids" ] || return 0

  if ! out=$(xargs docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' <<<"$ids"); then
    # A container can legitimately disappear between `ps` and `inspect` -- docker
    # then exits non-zero having still reported on all the others. That is a race,
    # not a broken daemon, so tolerate it as long as SOMETHING came back. Nothing
    # at all means the question itself failed.
    if [ -z "$out" ]; then
      INVENTORY_ERROR="'docker inspect' failed for all $(wc -l <<<"$ids") container(s)"
      return 1
    fi
  fi

  # grep drops the blank lines the template emits for volume-less containers; an
  # empty result here is legal, hence `|| true`.
  INVENTORY_VOLUMES=$(grep . <<<"$out" || true)
  return 0
}

# Volumes referenced by a container that EXISTS -- running OR stopped. This is the
# PRIMARY tie-break (see resolve_volume()), and it deliberately does not ask what is
# running. A backup whose answer changes because a container happened to be down at
# 04:00 is a backup whose correctness depends on uptime, which is the opposite of
# what a backup is for. A volume orphaned by a project rename is referenced by
# nothing in ANY state -- that is what makes it an orphan, and it is precisely the
# distinction `docker ps -a` draws and `docker ps` cannot.
if ! docker_volume_inventory -a; then
  echo "ERROR: $INVENTORY_ERROR" >&2
  echo "       Refusing to run: with no container inventory every volume that exists" >&2
  echo "       under two project prefixes would be reported as an orphan and FAIL," >&2
  echo "       naming a cause that is not the real one." >&2
  notify_failure "Failed during: ${STEP}. ${INVENTORY_ERROR}"
  exit 1
fi
ATTACHED_VOLUMES="$INVENTORY_VOLUMES"

# Volumes a RUNNING container mounts. A strict subset of ATTACHED_VOLUMES, used
# only as a SECOND tie-break for the case where two candidates are both attached
# to containers that exist. Guarded the same way and for the same reason: this one
# is only a tie-break, but a docker failure here means the failure above was a
# fluke of timing, and guessing after that is not better than stopping.
if ! docker_volume_inventory; then
  echo "ERROR: $INVENTORY_ERROR" >&2
  notify_failure "Failed during: ${STEP}. ${INVENTORY_ERROR}"
  exit 1
fi
MOUNTED_VOLUMES="$INVENTORY_VOLUMES"

# Keep only the lines of $1 that also appear in $2; both newline-separated.
# The empty-$2 early return is a fast path, NOT a correctness fix: the per-line
# `grep -Fxq` below already returns nothing against an empty set, verified rather
# than assumed. It is spelled out because an empty tie-break set is a normal state
# (nothing running) and a reader should not have to derive that it is safe.
intersect_lines() {
  local list="$1" want="$2" line out=""
  [ -n "$want" ] || { printf ''; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -Fxq "$line" <<<"$want"; then
      out+="$line"$'\n'
    fi
  done <<<"$list"
  printf '%s' "${out%$'\n'}"
}

# Newline-separated list -> single space-separated line, for error messages.
join_inline() {
  local s
  s=$(tr '\n' ' ' <<<"$1")
  printf '%s' "${s% }"
}

# Resolve one curated volume name to a real Docker volume.
#
# Sets RESOLVED_VOLUME / RESOLVE_ERROR as GLOBALS and returns 0/1 rather than
# printing the answer. That is deliberate: `v=$(resolve_volume x)` would run the
# function in a subshell, so RESOLVE_ERROR would be discarded and every failure
# would report an empty reason.
#
# Some names exist under TWO prefixes, one live and one orphaned by a project
# rename -- `arr-stack_beszel-data` is used by beszel, `arr-utilities_beszel-data`
# is a leftover of the split. Backing up the orphan would produce a successful-looking
# archive of an abandoned volume: the same lie as the skip above, one layer deeper.
# A tie is broken by which candidate a container REFERENCES (running or stopped),
# falling back to which one is currently mounted only if that leaves more than one.
# A tie that cannot be broken either way is an ERROR, never a guess.
resolve_volume() {
  local suffix="$1" cands attached live n_cands
  RESOLVED_VOLUME=""
  RESOLVE_ERROR=""

  # An explicit --prefix keeps its original exact-match meaning, so an operator
  # can always override the search.
  if [ -n "$VOLUME_PREFIX" ]; then
    if grep -Fxq "${VOLUME_PREFIX}_${suffix}" <<<"$ALL_VOLUMES"; then
      RESOLVED_VOLUME="${VOLUME_PREFIX}_${suffix}"
      return 0
    fi
    RESOLVE_ERROR="no volume named '${VOLUME_PREFIX}_${suffix}' (--prefix given, so no search was attempted)"
    return 1
  fi

  # Endswith rather than a regex: volume names contain '-' and '.', and building
  # a safe pattern from an arbitrary name is easier to get wrong than to compare
  # the tail directly. `length > length(s)` requires at least one character of
  # project name, so a bare unprefixed volume never matches -- there is an
  # orphaned bare `tailscale-state` on this NAS that must not shadow
  # `tailscale_tailscale-state`.
  cands=$(awk -v s="_${suffix}" \
    'length($0) > length(s) && substr($0, length($0) - length(s) + 1) == s' \
    <<<"$ALL_VOLUMES")

  if [ -z "$cands" ]; then
    RESOLVE_ERROR="no docker volume matches *_${suffix}"
    return 1
  fi

  n_cands=$(wc -l <<<"$cands")
  if [ "$n_cands" -eq 1 ]; then
    RESOLVED_VOLUME="$cands"
    return 0
  fi

  # Tier 1: which candidates does a container reference at all? Not "is running":
  # see ATTACHED_VOLUMES above. An orphan is referenced by nothing in any state.
  attached=$(intersect_lines "$cands" "$ATTACHED_VOLUMES")

  if [ -z "$attached" ]; then
    RESOLVE_ERROR="ambiguous: $(join_inline "$cands") -- no container references any of them, running or stopped. Re-run with --prefix to choose."
    return 1
  fi

  if [ "$(wc -l <<<"$attached")" -eq 1 ]; then
    RESOLVED_VOLUME="$attached"
    return 0
  fi

  # Tier 2: two or more are genuinely in use by containers that exist. Only now
  # does it matter which is running -- and if that still does not separate them,
  # refuse rather than guess.
  live=$(intersect_lines "$attached" "$MOUNTED_VOLUMES")
  if [ -n "$live" ] && [ "$(wc -l <<<"$live")" -eq 1 ]; then
    RESOLVED_VOLUME="$live"
    return 0
  fi

  RESOLVE_ERROR="ambiguous: $(join_inline "$attached") -- each is referenced by an existing container. Re-run with --prefix to choose."
  return 1
}

# Backup location handling:
# - Always create backup in /tmp first (reliable space)
# - If destination specified and different from /tmp, move tarball there after checking space
FINAL_DEST="${BACKUP_DIR:-}"
BACKUP_DIR="/tmp/arr-stack-backup-${RUN_TS}"
# Plain mkdir, not -p: it fails if the directory exists, which is the cheapest
# guard against two runs landing in the same second and interleaving their
# staging files into one tarball.
mkdir "$BACKUP_DIR" || {
  echo "ERROR: $BACKUP_DIR already exists - another backup may be running" >&2
  exit 1
}

# Flat rotation at the final destination. OPT-IN ONLY (--rotate-days) and always
# loud, because this directory may already be owned by backup-prune.sh's GFS
# scheme and nothing else in the system would report a silent mass deletion.
if [ -n "$ROTATE_DAYS" ] && [ -n "$FINAL_DEST" ] && [ -d "$FINAL_DEST" ]; then
  echo "Rotating $FINAL_DEST (--rotate-days $ROTATE_DAYS)..."
  ROTATED=0
  while IFS= read -r stale; do
    [ -n "$stale" ] || continue
    if rm -rf "$stale"; then
      echo "  removed: $(basename "$stale")"
      ROTATED=$((ROTATED + 1))
    else
      echo "  WARNING: could not remove $(basename "$stale")" >&2
    fi
  done < <(find "$FINAL_DEST" -maxdepth 1 -mindepth 1 \
             -name 'arr-stack-backup-*' -mtime "+$ROTATE_DAYS" | sort)
  echo "Rotation removed $ROTATED item(s)."
  echo ""
fi

# Get current user for ownership fix (avoids needing sudo for tar)
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# Volumes holding state that would require manual reconfiguration if lost.
VOLUME_SUFFIXES=(
  gluetun-config          # servers.json only - the VPN CREDENTIALS are in .env,
                          # which is backed up separately below
  qbittorrent-config      # Client settings, categories, watched folders
  sabnzbd-config          # Usenet provider credentials and settings
  prowlarr-config         # Indexer configs and API keys
  bazarr-config           # Subtitle provider credentials
  uptime-kuma-data        # Monitor configurations
  sonarr-config           # Series DB, quality profiles, custom formats, API key
  radarr-config           # Movie DB, quality profiles, custom formats, API key
  jellyfin-config         # Users, watch history, plugin config
  pihole-etc-pihole       # pihole.toml, gravity DB, custom allow/deny lists
  decypharr-config        # auth.json + config.json - debrid credentials
  dnscrypt-config         # dnscrypt-proxy.toml - resolver and forwarding rules
  beszel-data             # data.db + id_ed25519, the agent's own private key
  tailscale-state         # node identity: see below, this one is load-bearing
  tailscale-exit-state    # exit-node identity, same argument
  gluetun-exit-config     # same, for the Tailscale exit-node tunnel
)

# tailscale-state is the most important entry in this list and was missing from it
# entirely until 2026-08-31. docs/EXIT-NODE-PROJECT-LOG.md records that recreating
# Tailscale node 1 severs EVERY path to the NAS at once -- SSH and the UGOS admin UI
# both ride its own subnet route -- and instructs that it only be done with a
# state-volume backup and an auto-rollback. That backup did not exist. Losing this
# 28KB volume means the node re-registers with a new identity, the subnet routes
# stop being advertised, and the recovery path is a physical visit.

# Per-volume exclusions, relative to the volume root.
#
# The four *arr/jellyfin/pihole volumes above were previously excluded wholesale as
# "large - re-scan to rebuild". That reasoning only ever held for the caches inside
# them, not for the volumes themselves: quality profiles, custom formats, release
# profiles, indexer assignments, Jellyfin users and watch history are NOT rebuilt by
# a re-scan. Measured 2026-08-30, the split is lopsided enough that excluding the
# caches gets full protection for roughly 35MB:
#
#   sonarr-config     1015M total -> ~13M kept  (logs.db alone is 862M)
#   radarr-config      190M total ->  ~7M kept  (MediaCover 123M, logs 57M)
#   jellyfin-config    506M total ->  ~9M kept  (metadata 497M, re-downloadable art)
#   pihole-etc-pihole   50M total ->  ~5M kept  (pihole-FTL.db 34M is query logs)
#
# Anything listed here must be genuinely regenerable by the service itself.
declare -A VOLUME_EXCLUDES=(
  [sonarr-config]="logs.db logs.db-wal logs.db-shm logs MediaCover Sentry"
  [radarr-config]="logs.db logs.db-wal logs.db-shm logs MediaCover Sentry"
  [jellyfin-config]="metadata cache log transcodes"
  [pihole-etc-pihole]="pihole-FTL.db pihole-FTL.db-wal pihole-FTL.db-shm gravity_old.db listsCache"
  [decypharr-config]="cache logs"
)

# Both gluetun-*-config volumes are deliberately NOT given a servers.json exclusion
# even though that file is 7MB of their 7.1MB and gluetun re-fetches it. Measured
# 2026-08-31: servers.json is the ONLY file in them, so the exclusion would reduce
# an existing backup to an empty directory reported as "OK (empty)". Shrinking
# coverage inside the fix for silently-lost coverage is not a trade worth 14MB of
# a 136MB archive.

# Request manager - only one of the two is ever deployed, so the one that is
# absent is genuinely optional and must not be appended (everything that IS in
# VOLUME_SUFFIXES is required to resolve, and fails the run if it does not).
if resolve_volume seerr-config; then
  VOLUME_SUFFIXES+=(seerr-config)
else
  seerr_err="$RESOLVE_ERROR"
  if resolve_volume overseerr-config; then
    VOLUME_SUFFIXES+=(overseerr-config)
  else
    # Print BOTH reasons rather than a canned "not found". Exactly one of these
    # two is ever deployed, so one being absent is expected -- but an AMBIGUOUS
    # resolution is not absence, and flattening the two into one message would
    # hide a real fault behind an expected one. That is the same substitution of
    # a benign report for a real failure that this whole change exists to remove;
    # it would have hidden the uptime-kuma-data regression had that volume been
    # optional rather than required.
    echo "Warning: no request manager volume resolved - none backed up"
    echo "         seerr-config:     $seerr_err"
    echo "         overseerr-config: $RESOLVE_ERROR"
    echo ""
  fi
fi

# Volumes still excluded entirely, because they hold nothing a service cannot
# rebuild unaided:
#   jellyfin-cache          - transcoding cache, fully regenerates
#   duc-index               - disk usage index, regenerates on restart
#   configarr-repos         - git clones of upstream config repos, re-cloned on run
#   magnetio-redis-data     - ephemeral cache (8KB)
#   diun-data               - a single diun.db recording which image digests have
#                             already been notified about. Losing it re-notifies
#                             once and then self-heals; there is no configuration
#                             in it (diun is configured entirely by environment).
#
# The three previously listed here as "candidates, not yet assessed" were assessed
# on 2026-08-31 and all three are now backed up: decypharr-config holds auth.json,
# beszel-data holds an id_ed25519 private key, and dnscrypt-config holds a hand-
# edited dnscrypt-proxy.toml. None is regenerable. Together they are under 4MB.
#
# Orphaned volumes deliberately NOT cleaned up here (backup is not the place to
# delete things): arr-utilities_beszel-data, magnetio_magnetio-redis-data, the
# unprefixed tailscale-state, and both copies of configarr-repos are leftovers of
# past project renames. resolve_volume() ignores them because no running container
# mounts them.

STEP="backing up .env"
echo "=== Arr-Stack Backup ==="
if [ -n "$VOLUME_PREFIX" ]; then
  echo "Volume prefix: ${VOLUME_PREFIX}_* (pinned via --prefix)"
else
  echo "Volumes:       resolved per-name across all compose projects"
fi
echo "Backup dir:    $BACKUP_DIR"
echo ""

BACKED_UP=0
SKIPPED=0
FAILED=0

# Back up .env (contains secrets: VPN credentials, API keys, passwords)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  echo -n "Backing up .env... "
  if cp "$ENV_FILE" "$BACKUP_DIR/dot-env" 2>/dev/null; then
    chmod 600 "$BACKUP_DIR/dot-env"
    echo "OK"
    BACKED_UP=$((BACKED_UP + 1))
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "Skipping .env (not found at $ENV_FILE)"
  SKIPPED=$((SKIPPED + 1))
fi

STEP="backing up volumes"

# suffix -> resolved volume name, written into the archive. Without it a restore
# has to guess which project each directory came from, and the guess is wrong for
# exactly the volumes this fix is about (uptime-kuma-data is NOT arr-stack_*).
MANIFEST="$BACKUP_DIR/volume-manifest.tsv"
printf 'directory\tsource_volume\n' > "$MANIFEST"

for suffix in "${VOLUME_SUFFIXES[@]}"; do
  # Not `vol=$(resolve_volume ...)`: that subshell would discard RESOLVE_ERROR.
  if ! resolve_volume "$suffix"; then
    # A volume named in VOLUME_SUFFIXES that resolves to nothing is a FAILURE, not
    # a skip. It used to be a skip, and that is precisely how uptime-kuma-data went
    # unbacked-up behind a summary reading "11 backed up, 1 skipped, 0 failed".
    # Everything in that list is there because losing it costs manual
    # reconfiguration, so "I could not find it" is never benign. Optional volumes
    # are handled by not appending them (see the request-manager block above).
    echo "FAILED $suffix - $RESOLVE_ERROR"
    FAILED=$((FAILED + 1))
    continue
  fi
  vol="$RESOLVED_VOLUME"

  if docker volume inspect "$vol" &>/dev/null; then
    echo -n "Backing up $suffix ($vol)... "

    # Copy files and fix ownership in one container run.
    # The chown ensures we can tar without sudo later.
    #
    # Volumes with exclusions go through a tar pipe rather than `cp -a` so the
    # excluded paths are never read at all - copying sonarr's 862MB logs.db just to
    # delete it afterwards would dominate the runtime of every backup.
    if [ -n "${VOLUME_EXCLUDES[$suffix]:-}" ]; then
      TAR_EXCLUDES=""
      for ex in ${VOLUME_EXCLUDES[$suffix]}; do
        TAR_EXCLUDES="$TAR_EXCLUDES --exclude=./$ex"
      done
      # pipefail matters here: without it the pipe reports the RECEIVING tar's
      # status, so a source tar that dies on an I/O or permission error yields a
      # truncated backup reported as "OK". Verified on the NAS: busybox ash
      # supports `set -o pipefail`, and without it `false | true` exits 0.
      COPY_CMD="set -o pipefail; mkdir -p /backup/$suffix && tar -C /source -cf - $TAR_EXCLUDES . | tar -C /backup/$suffix -xf -"
    else
      COPY_CMD="mkdir -p /backup/$suffix && cp -a /source/. /backup/$suffix/"
    fi

    if docker run --rm --name arr-backup-worker \
      -v "$vol":/source:ro \
      -v "$BACKUP_DIR":/backup \
      alpine sh -c "$COPY_CMD && chown -R $CURRENT_UID:$CURRENT_GID /backup/$suffix" 2>/dev/null; then

      # Check if anything was actually copied
      if [ -d "$BACKUP_DIR/$suffix" ] && [ "$(ls -A "$BACKUP_DIR/$suffix" 2>/dev/null)" ]; then
        SIZE=$(du -sh "$BACKUP_DIR/$suffix" 2>/dev/null | cut -f1)
        echo "OK ($SIZE)"
        BACKED_UP=$((BACKED_UP + 1))
      else
        echo "OK (empty)"
        BACKED_UP=$((BACKED_UP + 1))
      fi
      # Manifest entry only on a successful copy. Written unconditionally it
      # would advertise a restore path for a directory that failed to copy --
      # a record saying the backup worked when it did not, which is precisely
      # the failure shape this change exists to remove.
      printf '%s\t%s\n' "$suffix" "$vol" >> "$MANIFEST"
    else
      echo "FAILED (permission denied or volume error)"
      FAILED=$((FAILED + 1))
    fi
  else
    # resolve_volume() found this name in `docker volume ls` moments ago, so a
    # failure here means it was removed mid-run -- a real fault, not an absence.
    echo "FAILED $suffix - '$vol' disappeared between listing and inspection"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Summary: $BACKED_UP backed up, $SKIPPED skipped, $FAILED failed"
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
echo "Total size: $TOTAL_SIZE"

# Warn about failures
if [ $FAILED -gt 0 ]; then
  echo ""
  echo "WARNING: Some volumes failed to backup. Check permissions."
  notify_failure "${FAILED} volume(s) failed to backup. ${BACKED_UP} succeeded, ${SKIPPED} skipped."
fi

STEP="creating tarball"
# Create tarball if requested
if [ "$CREATE_TAR" = true ]; then
  TARBALL="${BACKUP_DIR}.tar.gz"
  echo ""
  echo "Creating tarball..."

  # Remove stale tarball from previous run (sticky-bit on /tmp blocks overwrites by different users)
  rm -f "$TARBALL"

  # Exclude socket files (qbittorrent ipc-socket) - they can't be archived
  tar -czf "$TARBALL" \
    --exclude='*/ipc-socket' \
    -C "$(dirname "$BACKUP_DIR")" \
    "$(basename "$BACKUP_DIR")" 2>/dev/null

  TARBALL_SIZE_BYTES=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null)
  TARBALL_SIZE_MB=$(( TARBALL_SIZE_BYTES / 1024 / 1024 ))
  TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
  echo "Created: $TARBALL ($TARBALL_SIZE)"

  # GPG symmetric encryption (opt-in)
  if $ENCRYPT; then
    STEP="encrypting tarball"
    echo ""
    echo "Encrypting tarball with GPG..."
    gpg --batch --yes --symmetric --cipher-algo AES256 "$TARBALL"
    rm -f "$TARBALL"
    TARBALL="${TARBALL}.gpg"
    TARBALL_SIZE_BYTES=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null)
    TARBALL_SIZE_MB=$(( TARBALL_SIZE_BYTES / 1024 / 1024 ))
    TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
    echo "Encrypted: $TARBALL ($TARBALL_SIZE)"
    echo ""
    echo "To decrypt: gpg --decrypt $TARBALL > backup.tar.gz"
  fi

  STEP="moving tarball to USB"
  # Move to final destination if specified and different from /tmp
  if [ -n "$FINAL_DEST" ] && [ "$FINAL_DEST" != "/tmp" ]; then
    AVAILABLE_MB=$(df -m "$FINAL_DEST" 2>/dev/null | awk 'NR==2 {print $4}')
    REQUIRED_MB=$(( TARBALL_SIZE_MB + 10 ))  # Actual size + 10MB buffer

    if [ -n "$AVAILABLE_MB" ] && [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
      echo ""
      echo "WARNING: Not enough space at $FINAL_DEST (${AVAILABLE_MB}MB free, need ${REQUIRED_MB}MB)"
      echo "         Tarball remains in /tmp - copy manually when space available"
    else
      # Keep the real extension: an encrypted tarball moved to a plain .tar.gz
      # name is a file that cannot be untarred and does not say so.
      FINAL_TARBALL="$FINAL_DEST/arr-stack-backup-${RUN_TS}.tar.gz"
      if $ENCRYPT; then
        FINAL_TARBALL="${FINAL_TARBALL}.gpg"
      fi
      if mv "$TARBALL" "$FINAL_TARBALL" 2>/dev/null; then
        TARBALL="$FINAL_TARBALL"
        echo "Moved to: $TARBALL"
      else
        notify_failure "Could not move tarball to ${FINAL_DEST}. Backup remains in /tmp."
      fi
    fi
  fi

  # Drop the staging copy once the tarball exists. /tmp on this NAS is tmpfs -
  # a RAM-backed filesystem - and each run stages ~200MB into it. This used to
  # leak one directory per DAY (the staging name was date-only); with a
  # per-second name it would leak one per RUN, so cleanup is no longer optional.
  # Only safe when --tar was used: without it, the staging directory IS the
  # backup.
  if [ -n "$TARBALL" ] && [ -f "$TARBALL" ] && [ -d "$BACKUP_DIR" ]; then
    STEP="cleaning up staging directory"
    if rm -rf "$BACKUP_DIR"; then
      echo "Cleaned up staging dir $BACKUP_DIR"
    else
      echo "WARNING: could not remove staging dir $BACKUP_DIR" >&2
    fi
  fi

  echo ""
  echo "To copy off-NAS:"
  echo "  # Ugreen NAS (scp doesn't work with /tmp):"
  echo "  ssh user@nas 'cat $TARBALL' > ./backup.tar.gz"
  echo ""
  echo "  # Other systems:"
  echo "  scp user@nas:$TARBALL ./backup.tar.gz"
fi

# Safety check runs via EXIT trap (ensure_services_running)

echo ""
if [[ "${TARBALL}" == /tmp/* ]] || [[ -z "${TARBALL}" ]]; then
  echo "NOTE: Backup is in /tmp which is cleared on reboot."
  echo "      Copy the tarball off-NAS before rebooting!"
fi
echo ""
# The destination volume name is NOT derivable from the directory name -- the
# stack spans four compose projects. volume-manifest.tsv inside the archive maps
# each directory to the volume it came from; read it rather than assuming a prefix.
echo "To restore: read volume-manifest.tsv for the source volume of each directory, then"
echo "            docker run --rm -v ./backup/DIR:/src:ro -v SOURCE_VOLUME:/dst alpine cp -a /src/. /dst/"

# A volume that could not be resolved or copied is a FAILURE, and the exit status
# has to say so. Until 2026-08-31 this script exited 0 whatever FAILED was: the loop
# counted it, printed a warning, and then the last statement was an echo -- so $? was
# 0. That is the same lie the single-prefix bug told, moved one layer out, and it is
# the layer that machines read. A cron `&&` chain, a CI step and `notify_failure`'s
# unconfigured webhook all saw a clean run.
#
# This is deliberately the LAST statement, after the tarball is built and moved:
# everything that DID resolve is still archived. A partial backup that reports
# itself as partial is useful; withholding the archive because one volume failed
# would trade a reporting bug for a data-loss one.
#
# CALLERS MUST BE CHECKED when this changes: a `backup && prune` chain will now stop
# pruning on a partial failure. See docs/BACKUP.md.
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
