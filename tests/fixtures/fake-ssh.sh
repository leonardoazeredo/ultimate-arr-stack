#!/bin/bash
# A fake ssh for tests/lib-dns-parity.bats — put this file on $PATH as `ssh`.
#
# The only job here is to make the jump path observable without a network. A
# target whose host part is `local:` is run here: the remote command arrives
# over stdin (`sh -s`), which is the contract the real remote path has, so the
# fake dig behind it is reached exactly as a real one would be. Any other
# target is refused at once, which is how a test simulates an unreachable jump
# host without waiting on a connection attempt.
#
# Every accepted target is appended to $DNS_PARITY_SSH_LOG so a test can assert
# that the query really went through the jump rather than out of the local dig.

target=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Options that take their value as the NEXT word: skipping only the
        # option itself would leave `ConnectTimeout=8` looking like the target,
        # and the stub would then refuse a connection nobody asked it to refuse.
        -o|-i|-p|-l|-b|-c|-E|-F|-I|-J|-L|-R|-W|-m|-Q|-S) shift 2 ;;
        # An attached form like -oConnectTimeout=8 carries its own value.
        -*) shift ;;
        *) target="$1"; break ;;
    esac
done
[[ $# -gt 0 ]] && target="$1"
[[ $# -gt 0 ]] && shift

if [[ "$target" != local:* ]]; then
    printf 'ssh: connect to host %s: Connection refused\n' "$target" >&2
    exit 255
fi

# Everything after the target is the remote command. ssh runs it with the rest
# of the argv as that command's arguments, which is how the library hands the
# remote shell an absolute path to dig; dropping them here would leave the
# remote script with an empty "$1" and a `command not found` instead of an
# answer, and the failure would look like an unreachable resolver.
printf '%s\n' "$target" >> "${DNS_PARITY_SSH_LOG:-/dev/null}"

# Real ssh joins the command and its arguments with spaces and hands the remote
# LOGIN SHELL that one string, so the arguments are words inside the command
# rather than positional parameters of it. This has to do the same, and not
# because of authenticity: on this host `sh -c "sh -s" sh foo bar` gives the
# `-s` script `$#` = 0 - sh drops those trailing arguments instead of passing
# them through - so a `sh -c ... "$@"` shape silently reaches the fake dig with
# an empty argv. The result is an answer-less query that reads as an unreachable
# resolver rather than as a bug in this stub. Joining them into the command
# string is also exactly what the remote side sees in production, so the shape
# under test is the shape that runs.
remote="$1"; shift
if [[ $# -gt 0 ]]; then
    remote="$remote $*"
fi
exec sh -c "$remote"
