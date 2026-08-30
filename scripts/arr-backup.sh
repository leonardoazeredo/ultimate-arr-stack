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
#   --prefix NAME   Volume prefix (default: auto-detect from running containers)
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
#   ./scripts/arr-backup.sh --prefix media-stack      # Use custom volume prefix
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

STEP="detecting volume prefix"
# Auto-detect volume prefix from running containers if not specified
if [ -z "$VOLUME_PREFIX" ]; then
  # Try to find prefix from gluetun container's volumes
  VOLUME_PREFIX=$(docker inspect gluetun 2>/dev/null | grep -o '"[^"]*_gluetun-config"' | head -1 | tr -d '"' | sed 's/_gluetun-config$//' || true)

  # Fallback: check for any arr-stack-like volumes
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX=$(docker volume ls --format '{{.Name}}' | grep -o '^[^_]*' | grep -E 'arr-stack|media' | head -1 || true)
  fi

  # Final fallback
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX="arr-stack"
    echo "Warning: Could not auto-detect volume prefix, using '$VOLUME_PREFIX'"
    echo "         Use --prefix to specify if your volumes have a different prefix"
    echo ""
  fi
fi

# Backup location handling:
# - Always create backup in /tmp first (reliable space)
# - If destination specified and different from /tmp, move tarball there after checking space
FINAL_DEST="${BACKUP_DIR:-}"
BACKUP_DIR="/tmp/arr-stack-backup-${RUN_TS}"
mkdir -p "$BACKUP_DIR"

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
             -name 'arr-stack-backup-*' -mtime "+$ROTATE_DAYS" 2>/dev/null | sort)
  echo "Rotation removed $ROTATED item(s)."
  echo ""
fi

# Get current user for ownership fix (avoids needing sudo for tar)
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# Volumes holding state that would require manual reconfiguration if lost.
VOLUME_SUFFIXES=(
  gluetun-config          # VPN provider credentials and settings
  qbittorrent-config      # Client settings, categories, watched folders
  sabnzbd-config          # Usenet provider credentials and settings
  prowlarr-config         # Indexer configs and API keys
  bazarr-config           # Subtitle provider credentials
  uptime-kuma-data        # Monitor configurations
  sonarr-config           # Series DB, quality profiles, custom formats, API key
  radarr-config           # Movie DB, quality profiles, custom formats, API key
  jellyfin-config         # Users, watch history, plugin config
  pihole-etc-pihole       # pihole.toml, gravity DB, custom allow/deny lists
)

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
)

# Request manager - detect which volume exists
if docker volume inspect "${VOLUME_PREFIX}_seerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(seerr-config)
elif docker volume inspect "${VOLUME_PREFIX}_overseerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(overseerr-config)
fi

# Volumes still excluded entirely, because they hold nothing a service cannot
# rebuild unaided:
#   jellyfin-cache          - transcoding cache, fully regenerates
#   duc-index               - disk usage index, regenerates on restart
#   configarr-repos         - git clones of upstream config repos, re-cloned on run
#   magnetio-redis-data     - ephemeral cache (8KB)
#   decypharr-config, beszel-data, dnscrypt-config - candidates, not yet assessed

STEP="backing up .env"
echo "=== Arr-Stack Backup ==="
echo "Volume prefix: ${VOLUME_PREFIX}_*"
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

for suffix in "${VOLUME_SUFFIXES[@]}"; do
  vol="${VOLUME_PREFIX}_${suffix}"

  if docker volume inspect "$vol" &>/dev/null; then
    echo -n "Backing up $suffix... "

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
      COPY_CMD="mkdir -p /backup/$suffix && tar -C /source -cf - $TAR_EXCLUDES . | tar -C /backup/$suffix -xf -"
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
    else
      echo "FAILED (permission denied or volume error)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "Skipping $suffix (volume not found)"
    SKIPPED=$((SKIPPED + 1))
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
echo "To restore: docker run --rm -v ./backup/VOLUME:/src:ro -v ${VOLUME_PREFIX}_VOLUME:/dst alpine cp -a /src/. /dst/"
