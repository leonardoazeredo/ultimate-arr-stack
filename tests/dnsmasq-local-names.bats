#!/usr/bin/env bats
# scripts/dnsmasq-local-names.sh — Phase 4.1: teach the router's dnsmasq the
# `.lan` names, so `.lan` resolves against the router's :53.
#
# The ssh layer is stubbed, and the stub EMULATES THE ROUTER rather than
# recording argv: the script arrives on stdin and runs for real against a fake
# UCI, a fake /var/etc and a fake dnsmasq init. That is what makes the second-run
# test mean anything — the same script, run again against the state the first run
# left behind, has to change nothing.
#
# Three properties are the reason this file exists, and each is a way of
# reporting success while the router serves nothing:
#
#   * IDEMPOTENT. `uci add_list` appends duplicates happily, so a second run that
#     blindly re-adds leaves 19 duplicate records in flash while the script
#     prints "applied" a second time.
#   * RELOADED AFTER THE COMMIT. `uci commit dhcp` emits no config.change
#     event — nothing calls /sbin/reload_config except /etc/init.d/boot — so the
#     commit alone writes flash while dnsmasq keeps serving the config it
#     rendered at boot. A test asserts the reload, and asserts it comes after the
#     commit.
#   * VERIFIED AGAINST THE RUNNING CONFIG. dnsmasq is started as
#     `dnsmasq -C /var/etc/dnsmasq.conf.<hash>`; `grep '^address='` on that file
#     is what the daemon actually loaded. A self-check that reads back UCI passes
#     while dnsmasq serves nothing, and that is the failure this migration keeps
#     re-learning.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/dnsmasq-local-names.sh"
    RECORD="$REPO_ROOT/pihole/dnsmasq.d/02-local-dns.conf.example"

    # A fake router filesystem. The script builds its remote commands from these
    # paths, so overriding them is what lets the stub run the real thing.
    FAKE_ROOT="$BATS_TEST_TMPDIR/router"
    mkdir -p "$FAKE_ROOT/var/etc"
    export FAKE_ROOT
    export DNSMASQ_RENDERED_CONF="$FAKE_ROOT/var/etc/dnsmasq.conf.cfg01411c"

    # The one identity option the script requires of a dnsmasq section before
    # writing to it. A fake router without it is a router the script should
    # refuse, so every case seeds it — which means this has to be set BEFORE the
    # seed, not after it, or the seeded value is the empty string and every case
    # is refused.
    export DNS_DNSMASQ_LEASEFILE=/tmp/dhcp.leases
    : > "$STUB_DIR/uci.state"
    printf 'dhcp.cfg01411c.leasefile=%s\n' "$DNS_DNSMASQ_LEASEFILE" >> "$STUB_DIR/uci.state"
    : > "$STUB_DIR/remote.log"

    stub_tool ssh "$(_fake_ssh_body)"
    stub_tool uci "$(_fake_uci_body)"
    stub_tool dnsmasq-init "$(_fake_dnsmasq_init_body)"
    stub_tool dig "$(_fake_dig_body)"

    export DNS_DNSMASQ_SSH=ssh
    export DNS_DNSMASQ_JUMP=pi@pi1.local
    export DNS_DNSMASQ_ROUTER=arr-stack-router
    export DNS_DNSMASQ_CONF="$RECORD"
    export DNS_DNSMASQ_TRAEFIK_IP=192.168.110.250
    export DNS_DNSMASQ_SECTION=dhcp.cfg01411c
    # Where the script looks for the config dnsmasq is actually running. In the
    # fake filesystem that is one file under the fake /var/etc.
    export DNS_DNSMASQ_RENDERED_GLOB="$FAKE_ROOT/var/etc/dnsmasq.conf.*"
    # The init path the script calls. It reaches the stub through the PATH the
    # fake router hands it, so the test records the reload rather than looking
    # for /etc/init.d/dnsmasq inside $BATS_TEST_TMPDIR.
    export DNS_DNSMASQ_INIT="$STUB_DIR/dnsmasq-init"
    # The script polls in the real world; no sleep here so a case costs nothing.
    export DNS_DNSMASQ_TRIES=3 DNS_DNSMASQ_SLEEP=0
}

# --- the fake router --------------------------------------------------------

# ssh <jump> '<router> sh -s' — the script is on stdin and runs for real in a
# shell whose PATH reaches the stub bin dir, with the fake filesystem in place.
_fake_ssh_body() {
    cat <<'BODY'
script=$(cat)
printf 'ssh\t%s\n' "$*" >> "$STUB_DIR/remote.log"
printf '%s\n' "$script" | PATH="$STUB_DIR:$PATH" sh -s
BODY
}

# A stand-in for this build's uci, with the verbs the script uses, backed by a
# file of `key=value` records — one line per list entry, which is how UCI stores
# an option list.
#
# The COMMAND SHAPES here are copied from the router's own usage text, and one
# of them was wrong in the first version of this stub in a way that mattered:
#
#   add_list   <config>.<section>.<option>=<string>
#   del_list   <config>.<section>.<option>=<string>
#   get        <config>.<section>[.<option>]
#
# `del_list` takes ONE word, `key=value` — not `key value`. Reading `$2` as the
# value made every delete a no-op, the rebuild then appended a second copy of
# every record, and the rendered config grew `:: ::`. The script was generating
# the correct call; the fixture was judging it with the wrong signature. Both
# list verbs now go through _uci_strip, so they cannot drift apart again.
_fake_uci_body() {
    cat <<'BODY'
state="$STUB_DIR/uci.state"
[ -f "$state" ] || : > "$state"

# _uci_strip <key> <value> — drop every entry `key=<value>`.
_uci_strip() {
    awk -v k="$1" -v v="$2" '!($0 == k "=" v)' "$state" > "$state.new"
    mv "$state.new" "$state"
}

if [ "${1:-}" = "-c" ]; then shift 2; fi
quiet=0
[ "${1:-}" = "-q" ] && { quiet=1; shift; }
cmd="${1:-}"; shift || true
case "$cmd" in
    get)
        key="$1"
        if grep -q "^${key}=" "$state"; then
            sed -n "s/^${key}=//p" "$state" | tr '\n' ' ' | sed 's/ $//'
            printf '\n'
        else
            [ "$quiet" = "1" ] || echo "uci: Entry not found" >&2
            exit 1
        fi
        ;;
    del_list)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        [ "$kv" = "$key" ] && { echo "uci: del_list needs <key>=<value>" >&2; exit 1; }
        _uci_strip "$key" "$val"
        ;;
    add_list)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        [ "$kv" = "$key" ] && { echo "uci: add_list needs <key>=<value>" >&2; exit 1; }
        if [ -n "${UCI_STUB_DROP_KEY:-}" ] && [ "$key" = "$UCI_STUB_DROP_KEY" ]; then
            exit 0
        fi
        printf '%s=%s\n' "$key" "$val" >> "$state"
        ;;
    delete)
        key="$1"
        grep -v "^${key}=" "$state" > "$state.new" || true
        mv "$state.new" "$state"
        ;;
    set)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        grep -v "^${key}=" "$state" > "$state.new" || true
        mv "$state.new" "$state"
        printf '%s=%s\n' "$key" "$val" >> "$state"
        ;;
    commit)
        ;;
    show)
        # `<section>=<type>`, one per line, as `uci show dhcp` prints them. The
        # fallback derives the section names from the state file's own keys;
        # a test that wants a specific set of sections writes show.state.
        if [ -f "$STUB_DIR/show.state" ]; then
            cat "$STUB_DIR/show.state"
        else
            sed -n 's/^\(dhcp\.[^.]*\)\..*/\1=dnsmasq/p' "$state" | sort -u
        fi
        ;;
    *)
        echo "uci: unknown command: $cmd" >&2
        exit 1
        ;;
esac
BODY
}

# The router's dnsmasq: a reload re-renders /var/etc/dnsmasq.conf.<section> from
# the UCI state, the way the init script does. RENDER_SKIP breaks that on
# purpose, which is how "UCI says yes, dnsmasq serves nothing" is reproduced
# without touching anything the test cannot see.
_fake_dnsmasq_init_body() {
    cat <<'BODY'
printf 'dnsmasq-init\t%s\n' "$*" >> "$STUB_LOG"
case "${1:-}" in
    reload|restart|start) ;;
    *) exit 0 ;;
esac
[ "${RENDER_SKIP:-0}" = "1" ] && exit 0
rendered="$DNSMASQ_RENDERED_CONF"
{
    printf 'local=/lan/\n'
    # Every address line, joined. `head -1` would render only the first, which
    # is a mangled config rather than the one the real init produces.
    addresses=$(sed -n 's/^dhcp\.cfg01411c\.address=//p' "$STUB_DIR/uci.state" | tr '\n' ' ')
    for a in $addresses; do printf 'address=%s\n' "$a"; done
} > "$rendered.new"
mv "$rendered.new" "$rendered"
BODY
}

# dig +short <name> [<qtype>] @127.0.0.1 — answered from the RENDERED file, so a
# check that only reads UCI cannot be satisfied by it. Two switches break it a
# layer at a time: DIG_ANSWER=0 answers nothing at all, and DIG_AAAA_NONE=1
# answers the A query and returns nothing for the AAAA — musl's failure mode,
# with everything else about the router correct.
_fake_dig_body() {
    cat <<'BODY'
[ "${DIG_ANSWER:-1}" = "0" ] && exit 0
qtype="A"; name=""
for a in "$@"; do
    case "$a" in
        @*|+*|-*) continue ;;
    esac
    if [ -z "$name" ]; then name="$a"; else qtype="$a"; fi
done
if [ "$qtype" = "AAAA" ] && [ "${DIG_AAAA_NONE:-0}" = "1" ]; then
    exit 0
fi
answers=$(grep '^address=' "$DNSMASQ_RENDERED_CONF" 2>/dev/null || true)
case "$qtype" in
    AAAA)
        # Only the zone-wide record answers an AAAA. The A records are IPv4-only
        # and never answer a v6 query. Matched with a trailing separator, so
        # `address=/lan/` does not also select `/lan/something`.
        printf '%s\n' "$answers" | sed -n 's|^address=/lan/\(.*\)$|\1|p' || true
        ;;
    *)
        printf '%s\n' "$answers" | sed -n "s|^address=/${name}/\\(.*\\)\$|\\1|p" || true
        ;;
esac
BODY
}

# --- helpers ----------------------------------------------------------------

state_get() {
    sed -n "s/^$1=//p" "$STUB_DIR/uci.state" | head -1
}

# The address records the fake UCI holds, one per line. `uci get` joins them with
# spaces, which is the shape the script reads back, so both forms are here.
state_addresses() {
    sed -n 's/^dhcp\.cfg01411c\.address=//p' "$STUB_DIR/uci.state" | grep . || true
}

# The address lines dnsmasq actually loaded.
rendered_addresses() {
    grep '^address=' "$DNSMASQ_RENDERED_CONF" 2>/dev/null || true
}

# The 19 records the script should write: the record file with the placeholder
# resolved, plus the apex.
#
# SORTED WITH THE APEX IN, deliberately. `/lan/::` sorts before every
# `<name>.lan` record, so the last line here is always a hostname. Adding the
# apex on its own line after the sort would put it last — and every caller
# captures this function with `$(wanted_records)`, where a command substitution
# strips the trailing newline and silently drops the last record. That is the
# one record the whole AAAA requirement rests on.
wanted_records() {
    {
        sed -n 's|^address=/\([^/]*\)/TRAEFIK_LAN_IP$|\1|p' "$RECORD" \
            | grep . | sed 's|^|/|; s|$|/192.168.110.250|'
        printf '/lan/::\n'
    } | sort
}

# Write the record set — 18 hostnames at Traefik's macvlan, plus the apex — to a
# file, one record per line. Every seeding path reads this file rather than a
# shell variable: `$(wanted_records)` and every `grep` capture in a command
# substitution strip the trailing newline or rejoin the lines, and a fixture
# where the last record quietly disappears is a fixture that tests nothing about
# the record that disappeared.
wanted_file() {
    wanted_records > "$BATS_TEST_TMPDIR/wanted"
    printf '%s\n' "$BATS_TEST_TMPDIR/wanted"
}

# seed_router [--rendered] — put the UCI list (and, with --rendered, the config
# dnsmasq would be serving) into the state the wanted records describe.
seed_router() {
    local want="$1" rendered="${2:-}"
    grep -v '^dhcp\.cfg01411c\.address=' "$STUB_DIR/uci.state" > "$STUB_DIR/uci.state.new" || true
    mv "$STUB_DIR/uci.state.new" "$STUB_DIR/uci.state"
    sed 's/^/dhcp.cfg01411c.address=/' "$want" >> "$STUB_DIR/uci.state"
    [[ "$rendered" == "--rendered" ]] || return 0
    {
        printf 'local=/lan/\n'
        sed 's/^/address=/' "$want"
    } > "$DNSMASQ_RENDERED_CONF"
}

# The one UCI option that marks the DHCP-serving dnsmasq section, and the only
# thing the script requires of a section before it will write to it. Written
# exactly once per state: a second copy leaves an empty first value for
# `uci get` to find, and the section then reads as one the script must refuse.
seed_identity() {
    printf 'dhcp.cfg01411c.leasefile=%s\n' "$DNS_DNSMASQ_LEASEFILE"
}

# A fresh UCI state: the identity option, plus `local=/lan/` when asked.
seed_state() {
    if [[ "${1:-}" == "--local" ]]; then
        printf 'dhcp.cfg01411c.local=/lan/\n' > "$STUB_DIR/uci.state"
    else
        : > "$STUB_DIR/uci.state"
    fi
    seed_identity >> "$STUB_DIR/uci.state"
}

# The state a first successful run leaves behind. Seeded, so a case about the
# second run does not have to perform the first.
seed_applied() {
    seed_state --local
    seed_router "$(wanted_file)" --rendered
}

# --- RED first: the two properties the brief names --------------------------

@test "dnsmasq-local-names: a second run changes nothing" {
    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "first run exited $status:"; echo "$output"; return 1; }

    local count_first
    count_first=$(state_addresses | wc -l | tr -d ' ')
    [ "$count_first" -eq 19 ] || {
        echo "first run wrote $count_first address records, expected 19:"
        state_addresses
        return 1
    }

    cp "$STUB_DIR/uci.state" "$BATS_TEST_TMPDIR/after-first"

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "second run exited $status:"; echo "$output"; return 1; }

    local count_second
    count_second=$(state_addresses | wc -l | tr -d ' ')
    [ "$count_second" -eq 19 ] || {
        echo "a second run left $count_second address records, not 19 —"
        echo "uci add_list appends duplicates happily:"
        state_addresses
        return 1
    }
    diff -u "$BATS_TEST_TMPDIR/after-first" "$STUB_DIR/uci.state" || {
        echo "a second run rewrote the records"
        return 1
    }
}

@test "dnsmasq-local-names: dnsmasq is reloaded after the commit" {
    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "exited $status:"; echo "$output"; return 1; }

    # Without this the records are in flash and dnsmasq keeps serving the config
    # it rendered at boot, while the script reports success.
    assert_stub_called dnsmasq-init "reload"

    local commit_line reload_line
    commit_line=$(grep -n "^uci"$'\t'"commit dhcp" "$STUB_LOG" | head -1 | cut -d: -f1)
    reload_line=$(grep -n "^dnsmasq-init" "$STUB_LOG" | head -1 | cut -d: -f1)
    [ -n "$commit_line" ] && [ -n "$reload_line" ] || {
        echo "commit at '$commit_line', reload at '$reload_line'"; cat "$STUB_LOG"
        return 1
    }
    [ "$reload_line" -gt "$commit_line" ] || {
        echo "dnsmasq reload at line $reload_line, commit dhcp at $commit_line"
        return 1
    }
}

# --- the rest of the contract ----------------------------------------------

@test "dnsmasq-local-names: every hostname in the record gets a record, plus the apex" {
    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local rec
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        state_addresses | grep -qxF "$rec" || {
            echo "no record for $rec:"; state_addresses; return 1
        }
    done < <(wanted_records)

    # The apex is not a hostname and does not come back from the shared parser,
    # so it is added explicitly. It is what gives a musl client an AAAA answer.
    state_addresses | grep -qxF '/lan/::' || {
        echo "no /lan/:: record:"; state_addresses; return 1
    }
    [ "$(state_addresses | wc -l | tr -d ' ')" -eq 19 ] || {
        echo "wrong record count:"; state_addresses; return 1
    }
}

@test "dnsmasq-local-names: nothing is written into the tmpfs confdir" {
    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # /tmp/dnsmasq.d is the configured confdir and it is tmpfs: records placed
    # there work until the next reboot and then vanish, with nothing on the box
    # to show they were ever there.
    ! grep -q 'tmp/dnsmasq.d' "$STUB_DIR/remote.log" || {
        echo "the tmpfs confdir was written to:"; cat "$STUB_DIR/remote.log"
        return 1
    }
    ! grep -q 'tmp/dnsmasq.d' "$STUB_LOG" || {
        echo "the tmpfs confdir was written to:"; cat "$STUB_LOG"
        return 1
    }
}

@test "dnsmasq-local-names: the local=/lan/ zone is left alone" {
    # Set to the value the router actually carries. It is complementary to the
    # address records: it stops `.lan` being forwarded upstream, and they supply
    # the answers. Writing or dropping it would be a second, silent change.
    printf 'dhcp.cfg01411c.local=/lan/\n' >> "$STUB_DIR/uci.state"

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ "$(state_get 'dhcp.cfg01411c.local')" = "/lan/" ]
}

@test "dnsmasq-local-names: a config dnsmasq did not load fails the run" {
    # The exact state a check that only reads back UCI calls a success: UCI
    # carries 18 of the 19 records and the config dnsmasq actually loaded
    # carries all 19. RENDER_SKIP holds the rendered file across the reload. The
    # rendered-config check has to report that the file is fine, and then name
    # the record whose write did not land.
    # UCI gets 18 owned records; the rendered config gets those 18 plus the
    # apex. Both reads have to work for this to mean anything: the rendered one
    # sees 19 records, and the record whose write did not land is still named.
    wanted_records | grep -v '^/sonarr.lan/\|^/lan/::' > "$BATS_TEST_TMPDIR/want17"
    seed_router "$BATS_TEST_TMPDIR/want17"
    {
        printf 'local=/lan/\n'
        sed 's/^/address=/' "$BATS_TEST_TMPDIR/want17"
        printf 'address=/lan/::\n'
    } > "$DNSMASQ_RENDERED_CONF"
    RENDER_SKIP=1
    export RENDER_SKIP

    run env bash "$SCRIPT"
    [ "$status" -eq 1 ] || {
        echo "exited $status, expected 1 — a check that only reads UCI passes"
        echo "while UCI is short a record:"; echo "$output"; return 1
    }
    [[ "$output" == *"does not carry address=/sonarr.lan/192.168.110.250"* ]] || {
        echo "the failure did not name the missing record:"; echo "$output"; return 1
    }
}

@test "dnsmasq-local-names: a rendered config carrying every record passes" {
    # The positive control for the check above, and the one the mutation corpus
    # forced out: with a rendered-config read that returns NOTHING, the case
    # above still passes — every record reads as missing, so "the missing record
    # is named" is satisfied by a check that cannot see any record at all. Here
    # the config genuinely carries all 19 and the run must say so.
    #
    # UCI is short the apex so the script reaches the reload and the checks;
    # the rendered file carries every record and RENDER_SKIP holds it that way.
    wanted_records | grep -v '^/lan/::' > "$BATS_TEST_TMPDIR/want18"
    seed_router "$BATS_TEST_TMPDIR/want18" --rendered
    printf 'address=/lan/::\n' >> "$DNSMASQ_RENDERED_CONF"
    RENDER_SKIP=1
    export RENDER_SKIP

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || {
        echo "exited $status — a rendered config carrying every record failed:"
        echo "$output"; return 1
    }
    [[ "$output" == *"all 19 records are in the running config"* ]] || {
        echo "the rendered config was not read back:"; echo "$output"; return 1
    }
}

@test "dnsmasq-local-names: a resolver answering nothing fails the run" {
    # The rendered file is complete — every record is in the config dnsmasq
    # loaded — and the resolver still answers nothing. This is the half a
    # rendered-file check alone cannot see, and the reason the script asks the
    # daemon as well as reading its config.
    DIG_ANSWER=0
    export DIG_ANSWER

    run env bash "$SCRIPT"
    [ "$status" -eq 1 ] || {
        echo "exited $status, expected 1 — a resolver answering nothing passed:"
        echo "$output"; return 1
    }
    [[ "$output" == *"would not reach Traefik"* ]] || {
        echo "the failure did not name the query:"; echo "$output"; return 1
    }
}

@test "dnsmasq-local-names: an AAAA that NXDOMAINs fails the run" {
    # Every record is in the config dnsmasq loaded, so the rendered-file check
    # passes, and the resolver answers the A query and returns nothing for the
    # AAAA. That is musl's failure mode and the reason the apex is carried at
    # all: everything else about this router is correct.
    # One owned record is missing, so the script reaches the reload and the
    # checks instead of stopping at "no change"; the record it rebuilds is the
    # one the A query asks for.
    wanted_records | grep -v '^/sonarr.lan/' > "$BATS_TEST_TMPDIR/want18"
    seed_router "$BATS_TEST_TMPDIR/want18"
    DIG_AAAA_NONE=1
    export DIG_AAAA_NONE

    run env bash "$SCRIPT"
    [ "$status" -eq 1 ] || {
        echo "exited $status, expected 1 — a missing AAAA record passed:"
        echo "$output"; return 1
    }
    [[ "$output" == *"AAAA"* ]] || {
        echo "the failure did not name the AAAA query:"; echo "$output"; return 1
    }
}

@test "dnsmasq-local-names: a no-op run does not commit or reload" {
    seed_applied
    cp "$STUB_DIR/uci.state" "$BATS_TEST_TMPDIR/before"

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    diff -u "$BATS_TEST_TMPDIR/before" "$STUB_DIR/uci.state" || {
        echo "a no-op run rewrote UCI"; return 1
    }
    assert_stub_not_called uci "commit"
    assert_stub_not_called dnsmasq-init "reload"
    [[ "$output" == *"no change"* ]]
}

@test "dnsmasq-local-names: a record this script does not own is not deleted" {
    # A hand-added record must survive: only the names this script owns are
    # replaced. Enforced over a change, because a no-op run has nothing to be
    # careful about — and the change is asserted to be a REBUILD, not an append,
    # because a run that only ever adds leaves the owned set duplicated and
    # satisfies the two "the record is there" checks below while doing it.
    wanted_records | grep -v '^/sonarr.lan/' > "$BATS_TEST_TMPDIR/want18"
    printf '/admin-one-off.lan/10.0.0.9\n' >> "$BATS_TEST_TMPDIR/want18"
    seed_router "$BATS_TEST_TMPDIR/want18"
    : > "$STUB_LOG"

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # The owned record that was missing is restored, the foreign one is still
    # there, and the record that was already present was removed before it was
    # re-added rather than left to be added twice.
    state_addresses | grep -qxF '/sonarr.lan/192.168.110.250' || {
        echo "the missing record was not restored:"; state_addresses; return 1
    }
    state_addresses | grep -qxF '/admin-one-off.lan/10.0.0.9' || {
        echo "a record this script does not own was deleted:"; state_addresses; return 1
    }
    [ "$(state_addresses | wc -l | tr -d ' ')" -eq 20 ] || {
        echo "the rebuild duplicated records instead of replacing them:"
        state_addresses; return 1
    }
    assert_stub_called uci "del_list dhcp.cfg01411c.address=/jellyfin.lan/192.168.110.250"
    assert_stub_called uci "add_list dhcp.cfg01411c.address=/jellyfin.lan/192.168.110.250"
}

@test "dnsmasq-local-names: a stale owned record is repaired, not left stale" {
    # The router holds a wrong address for a name this script owns. Rebuilding
    # the owned set has to replace it: a set that "already has the name" and is
    # therefore left alone keeps answering with the address the record file no
    # longer asks for.
    wanted_records | sed 's|^/sonarr\.lan/.*|/sonarr.lan/10.9.9.9|' > "$BATS_TEST_TMPDIR/stale"
    seed_router "$BATS_TEST_TMPDIR/stale"

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    state_addresses | grep -qxF '/sonarr.lan/192.168.110.250' || {
        echo "the stale address was not corrected:"; state_addresses; return 1
    }
    state_addresses | grep -qxF '/sonarr.lan/10.9.9.9' && {
        echo "the stale address survived:"; state_addresses; return 1
    }
    [ "$(state_addresses | wc -l | tr -d ' ')" -eq 19 ] || {
        echo "wrong record count:"; state_addresses; return 1
    }
}

@test "dnsmasq-local-names: DRY_RUN prints the records and changes nothing" {
    run env DRY_RUN=1 bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [[ "$output" == *"/sonarr.lan/192.168.110.250"* ]]
    [[ "$output" == *"/lan/::"* ]]
    assert_stub_not_called uci "commit"
    assert_stub_not_called dnsmasq-init "reload"
    [ -z "$(state_addresses)" ]
}

@test "dnsmasq-local-names: the section is resolved, and the type is not mistaken for it" {
    # The router's `uci -q get dhcp.@dnsmasq[0]` answers `dnsmasq` — the section
    # TYPE. Building `dhcp.$it` from that gives `dhcp.dnsmasq`, a section that
    # does not exist: the records would go somewhere dnsmasq never reads, the
    # script would report them written, and `.lan` would still not resolve.
    # Measured on the router 2026-09-19. That box carries two dnsmasq sections,
    # and the fake `show` below answers with both.
    #
    # WHAT THIS DOES AND DOES NOT COVER, because it matters for reading a green
    # result: the stub answers `show dhcp` with the canned trace, but the
    # whitespace-stripping behind it (`sed` vs busybox `tr`) runs on the ROUTER,
    # not here, and that is where the section name was mangled. The rest of the
    # resolution — which section is picked, and that the records land in it and
    # not in `dhcp.dnsmasq` — is what this asserts.
    DNS_DNSMASQ_SECTION=
    export DNS_DNSMASQ_SECTION
    # The tunnel's section is listed FIRST on purpose. Picking by position then
    # selects `wgclient1` and the records land in a section dnsmasq's DHCP
    # server never reads — which is the defect this case exists to catch, and
    # which the ordering on the live router would have hidden.
    printf '%s\n' 'dhcp.wgclient1=dnsmasq' 'dhcp.cfg01411c=dnsmasq' > "$STUB_DIR/show.state"
    seed_state
    # A rendered config carrying every record, held across the reload: this case
    # is about which section the records are written to, not about the reload.
    wanted_records > "$BATS_TEST_TMPDIR/all"
    {
        printf 'local=/lan/\n'
        sed 's/^/address=/' "$BATS_TEST_TMPDIR/all"
    } > "$DNSMASQ_RENDERED_CONF"
    RENDER_SKIP=1
    export RENDER_SKIP

    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"the dnsmasq section is dhcp.cfg01411c"* ]] || {
        echo "the wrong section was chosen:"; echo "$output"; return 1
    }
    assert_stub_called uci "add_list dhcp.cfg01411c.address=/sonarr.lan/192.168.110.250"
    assert_stub_not_called uci "add_list dhcp.dnsmasq"
    [ "$(state_addresses | wc -l | tr -d ' ')" -eq 19 ]
}

@test "dnsmasq-local-names: the records go over ssh on stdin, through the jump host" {
    run env bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # Direct `ssh arr-stack-router` is refused from a client VLAN; pi1 is the
    # way in. And the script arrives on stdin (`sh -s`), never interpolated into
    # an argv, which is where the quoting bugs live.
    assert_stub_called ssh "pi@pi1.local"
    assert_stub_called ssh "sh -s"
    assert_nothing_forbidden
}
