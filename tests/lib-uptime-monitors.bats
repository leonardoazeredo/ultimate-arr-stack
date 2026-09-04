#!/usr/bin/env bats
# scripts/lib/check-uptime-monitors.sh
#
# Compares the monitors configured in Uptime Kuma against the services this
# stack expects, in BOTH directions: a service with no monitor, and a monitor
# with no service. Warnings only -- it always returns 0 and never blocks.
#
# scripts/pre-commit calls it BARE (check 7) under `set -e`, which makes every
# command in it a potential exit for the whole hook. The file half-knows this:
# :43 carries the comment "|| true prevents set -e from exiting on SSH failure",
# so the SSH call is guarded -- and the two `warnings` counters underneath it
# were not. Post-increment on a counter starting at 0 returns 1, so the FIRST
# warning killed the hook, taking checks 8-11 and the summary with it. A check
# documented as "warnings only" was the most abrupt failure in the file.
#
# Every test names which direction it exercises, and the last two pin the
# errexit contract that the call site, not this file, used to decide.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-uptime-monitors.sh"

    # common.sh short-circuits on cached _LOADED flags; left alone, whichever
    # test ran first would decide the answer for all the rest.
    _NAS_CONFIG_LOADED=true
    _DOMAIN_LOADED=true

    # The four seams this check reaches the NAS through. Reachable by default;
    # individual tests re-override to exercise the skip arms.
    has_nas_config()   { return 0; }
    is_nas_reachable() { return 0; }
    is_ssh_available() { return 0; }
    monitors() { MONITORS="$1"; ssh_to_nas() { printf '%s\n' "$MONITORS"; }; }
}

# Exactly the set the file expects, so a test can subtract from it by name
# rather than restating eleven lines it does not care about.
ALL='Bazarr
Beszel
duc
FlareSolverr
Jellyfin
Seerr
Pi-hole
Prowlarr
qBittorrent
Radarr
Sonarr
Traefik'

without() { grep -v "^$1\$" <<<"$ALL"; }

# --- The happy path ---------------------------------------------------------

@test "uptime-monitors: says OK when every expected service is monitored" {
    monitors "$ALL"
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: Monitors match expected services"* ]]
    [[ "$output" != *"WARNING"* ]]
}

@test "uptime-monitors: matching is case-insensitive in both directions" {
    # Kuma's names are user-typed, so case is not a reliable key. Lowercasing
    # both sides is deliberate (:56, :59, :76, :78) -- if it regressed, every
    # monitor would be reported missing AND unknown simultaneously.
    monitors "$(tr '[:upper:]' '[:lower:]' <<<"$ALL")"
    run check_uptime_monitors
    [[ "$output" == *"OK: Monitors match expected services"* ]]
    [[ "$output" != *"WARNING"* ]]
}

# --- Direction 1: a service with no monitor ---------------------------------

@test "uptime-monitors: warns about an expected service that has no monitor" {
    monitors "$(without Sonarr)"
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Missing monitor for 'Sonarr'"* ]]
    [[ "$output" != *"OK: Monitors match"* ]]
}

@test "uptime-monitors: reports EVERY missing service, not just the first" {
    # The counter that used to abort here sat in this exact loop, so a version
    # that reports one name and stops is the specific regression to catch.
    monitors "$(without Sonarr | grep -v '^Radarr$')"
    run check_uptime_monitors
    [[ "$output" == *"Missing monitor for 'Sonarr'"* ]]
    [[ "$output" == *"Missing monitor for 'Radarr'"* ]]
}

# --- Direction 2: a monitor with no service ---------------------------------

@test "uptime-monitors: warns about a monitor for a service that is gone" {
    monitors "$ALL
Lidarr"
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Unknown monitor 'Lidarr' (removed service?)"* ]]
}

@test "uptime-monitors: the known extras are not reported as unknown" {
    # Real monitors on this Kuma that are deliberately not stack services; if
    # the allow-list at :72 stopped applying, every commit would warn four
    # times and the warnings would stop being read at all.
    monitors "$ALL
Home Assistant
Reolink NVR
Cloudflared Metrics
Jellyfin (External)"
    run check_uptime_monitors
    [[ "$output" != *"Unknown monitor"* ]]
    [[ "$output" == *"OK: Monitors match expected services"* ]]
}

@test "uptime-monitors: a blank line in the query output is not a monitor" {
    # The blank line has to be EMBEDDED. A first draft put it at the end, on
    # the reasoning that sqlite3 output ends in a newline -- but `actual` is
    # assigned by command substitution, which strips trailing newlines, so that
    # fixture never reached the guard at all and the mutation testing the guard
    # survived against a green test. An empty or NULL monitor name anywhere but
    # last is what :74 is actually for.
    monitors "Sonarr

Radarr"
    run check_uptime_monitors
    [[ "$output" != *"Unknown monitor \'\'"* ]]
    [[ "$output" != *"Unknown monitor '' "* ]]
}

# --- The four skip arms -----------------------------------------------------

@test "uptime-monitors: skips, saying why, when no NAS is configured" {
    has_nas_config() { return 1; }
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No NAS host"* ]]
}

@test "uptime-monitors: skips, saying why, when the NAS is unreachable" {
    is_nas_reachable() { return 1; }
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: NAS not reachable"* ]]
}

@test "uptime-monitors: skips, saying why, when the SSH port is closed" {
    is_ssh_available() { return 1; }
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: SSH port not reachable"* ]]
}

@test "uptime-monitors: an empty query result is a skip, not twelve warnings" {
    # The failure mode this arm exists to prevent: a NAS that answers SSH but
    # cannot reach docker returns nothing, and nothing compares equal to no
    # monitor at all -- so without :47 a broken query looks exactly like a
    # completely unmonitored stack.
    monitors ""
    run check_uptime_monitors
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: Could not query Uptime Kuma"* ]]
    [[ "$output" != *"Missing monitor"* ]]
}

# --- The errexit contract ---------------------------------------------------
#
# Cannot be checked in-process: `run` clears errexit, an `if` condition
# suppresses it inside the callee, and `( set -e; f ) || rc=$?` suppresses it
# too, because a subshell that is the left operand of `||` runs with errexit
# disabled whatever `set -e` appears inside it. Every idiom available to CATCH
# the abort also PREVENTS it, so this spawns a real process the way the hook is
# itself a real process.

bare_call_under_errexit() {
    cat > "$BATS_TEST_TMPDIR/driver.sh" <<DRIVER
set -e
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/check-uptime-monitors.sh"
has_nas_config()   { return 0; }
is_nas_reachable() { return 0; }
is_ssh_available() { return 0; }
ssh_to_nas() { cat "$BATS_TEST_TMPDIR/monitors.txt"; }
check_uptime_monitors
echo "REACHED-END"
DRIVER
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/monitors.txt"
    run bash "$BATS_TEST_TMPDIR/driver.sh"
}

@test "uptime-monitors: a missing-monitor warning does not kill a bare caller" {
    bare_call_under_errexit "$(without Sonarr)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing monitor for 'Sonarr'"* ]]
    [[ "$output" == *"REACHED-END"* ]]
}

@test "uptime-monitors: an unknown-monitor warning does not kill a bare caller" {
    bare_call_under_errexit "$ALL
Lidarr"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown monitor 'Lidarr'"* ]]
    [[ "$output" == *"REACHED-END"* ]]
}
