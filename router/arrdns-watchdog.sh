#!/bin/sh
# Keep the house resolving when AdGuard Home stops answering.
#
# AdGuard Home on 3053 serves every client on this router, because
# /etc/firewall.user redirects all DNS on br-lan.1, br-lan.10, br-lan.20,
# br-lan.30 and br-guest to it. Nothing sits behind that redirect, so if
# AdGuard Home dies the whole house loses DNS and therefore the internet.
# The router's own dnsmasq is still listening on :53 on every one of those
# interfaces. This script moves the house back to it, and moves it forward
# again once AdGuard Home can answer for itself.
#
# Run from cron every minute. Safe to run by hand; `--status` only reports.

PORT_FILE=/etc/arrdns-port
STATE_FILE=/etc/arrdns-watchdog.state
# /etc is the overlay filesystem and survives a reboot; /var/log is tmpfs and
# does not. The one transition most worth having afterwards is the boot-time
# fallback, which is exactly the one a tmpfs log loses. A few lines per
# transition, so flash wear is not a concern.
LOG_FILE=/etc/arrdns-watchdog.log
LOCK_DIR=/var/run/arrdns-watchdog.lock

ADG_PORT=3053
FALLBACK_PORT=53
FAIL_THRESHOLD=3
RECOVER_THRESHOLD=3
PROBE_NAME=github.com
DIG=/usr/bin/dig

# ---------------------------------------------------------------- utilities

log() {
  msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null
  logger -t arrdns-watchdog "$1"
}

read_state() {
  MODE=adguard; REASON=-; COUNT=0
  if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ -n "$MODE" ] || MODE=adguard
    [ -n "$REASON" ] || REASON=-
    [ -n "$COUNT" ] || COUNT=0
  fi
}

write_state() {
  MODE="$1"; REASON="$2"; COUNT="$3"
  cat > "$STATE_FILE" <<EOF
MODE=$MODE
REASON=$REASON
COUNT=$COUNT
EOF
}

current_port() { cat "$PORT_FILE" 2>/dev/null; }

dns_enabled() { uci -q get adguardhome.config.dns_enabled 2>/dev/null; }

# Ask AdGuard Home a real question on its real port. A TCP connect would only
# prove the process is listening; a resolver that is up but cannot resolve is
# exactly as useless to the house, so probe for an answer.
#
# `+short` is not enough on its own. BIND's dig writes resolver errors --
# ";; communications error to 127.0.0.1#3053: connection refused" -- to STDOUT,
# and exits 0, so a non-empty capture is not evidence of an answer. That is how
# the first version of this script came to report `probe=up` against a stopped
# AdGuard Home and would never have fired. Require a dotted quad: an A record is
# something only a working resolver produces.
probe_ok() {
  answer="$("$DIG" +short +time=2 +tries=1 "$PROBE_NAME" A @127.0.0.1 -p "$ADG_PORT" 2>/dev/null)"
  printf '%s\n' "$answer" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# Push the whole house onto $1. Writing the port file is what makes the change
# survive a later firewall reload; re-running the include applies it live.
#
# fw3 reload, NOT a bare re-run of /etc/firewall.user. Two things have to move
# together:
#
#   * the redirect rules in /etc/firewall.user, which read the port file; and
#   * the vendor's adg_redirect chain, which /etc/firewall.dns_order rebuilds
#     from adguardhome.config.dns_enabled on every full firewall reload.
#
# Re-running only the include moves the first and not the second, so after a
# fallback and a recovery the flag says AdGuard is serving while adg_redirect
# holds nothing -- the flag and the chain disagree, and br-lan.1/br-guest would
# fall through to dnsmasq silently if the include's own rules were ever absent.
# tests/router-dns.bats caught exactly this state after the first full
# fallback-and-recover cycle. It is the plan's own wording: reload the firewall.
apply_port() {
  port="$1"
  printf '%s\n' "$port" > "$PORT_FILE"
  if [ "$port" = "$FALLBACK_PORT" ]; then
    uci set adguardhome.config.dns_enabled='0'
  else
    uci set adguardhome.config.dns_enabled='1'
  fi
  uci commit adguardhome 2>/dev/null
  fw3 reload >/dev/null 2>&1
}

# ------------------------------------------------------------------- status

read_state
probe_ok && PROBE=up || PROBE=down
if [ "$1" = "--status" ]; then
  echo "mode=$MODE reason=$REASON count=$COUNT probe=$PROBE port=$(current_port) dns_enabled=$(dns_enabled)"
  exit 0
fi

# ------------------------------------------------------------------- locking
# A slow firewall reload must not overlap the next cron tick.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# -------------------------------------------------------------------- states

# Operator intent comes first, and before the probe. `dns_enabled` is the switch
# GL.iNet's own UI writes; falling back sets it to 0, so seeing 0 while AdGuard
# is still the target means a person turned it off on purpose. Honour that.
#
# Immediately is the point. This check used to sit inside the `probe_ok` branch,
# so an operator who disabled AdGuard *and stopped it* fell through to the
# probe-failure path and waited three cycles — and for all three, every client
# was still redirected at a dead resolver. The operator's own action would have
# caused the outage this script exists to prevent. Reading intent before health
# closes that window: one cron tick, whatever AdGuard is doing.
#
# MODE=adguard is required so the watchdog never mistakes its own fallback for an
# operator's decision. After it falls back it records mode=fallback, and
# dns_enabled=0 alongside that is its own doing, not something to undo.
if [ "$MODE" = adguard ] && [ "$(dns_enabled)" != "1" ]; then
  log "dns_enabled=0 while AdGuard Home is the target: treating as deliberate, holding DNS on dnsmasq"
  [ "$(current_port)" = "$FALLBACK_PORT" ] || apply_port "$FALLBACK_PORT"
  write_state fallback operator 0
  exit 0
fi

if probe_ok; then
  case "$MODE" in
    adguard)
      [ "$(current_port)" = "$ADG_PORT" ] || {
        log "restoring DNS to AdGuard Home on $ADG_PORT"
        apply_port "$ADG_PORT"
      }
      write_state adguard - 0
      ;;
    fallback)
      if [ "$REASON" = operator ]; then
        # Only a person re-enabling it moves the house forward again.
        if [ "$(dns_enabled)" = "1" ]; then
          log "operator re-enabled AdGuard Home: moving DNS back to $ADG_PORT"
          apply_port "$ADG_PORT"
          write_state adguard - 0
        fi
      else
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -ge "$RECOVER_THRESHOLD" ]; then
          log "AdGuard Home has answered $COUNT times in a row: moving DNS back to $ADG_PORT"
          apply_port "$ADG_PORT"
          write_state adguard - 0
        else
          write_state fallback crash "$COUNT"
        fi
      fi
      ;;
  esac
else
  case "$MODE" in
    adguard)
      # A single blip must not move the house; three in a row must.
      COUNT=$((COUNT + 1))
      if [ "$COUNT" -ge "$FAIL_THRESHOLD" ]; then
        log "AdGuard Home failed $COUNT probes in a row: falling back to dnsmasq on $FALLBACK_PORT"
        apply_port "$FALLBACK_PORT"
        write_state fallback crash 0
      else
        write_state adguard - "$COUNT"
      fi
      ;;
    fallback)
      write_state fallback "$REASON" 0
      ;;
  esac
fi
