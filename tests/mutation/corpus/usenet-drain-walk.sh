#!/bin/bash
# Guards added with scripts/usenet-drain-walk.sh, 2026-09-22.
#
# The walk is the only thing in this stack that runs usenet passes without a
# person watching each one, and the two properties below are what make that
# safe: a pass that has stopped moving is stopped, and stopping it stops the
# work underneath it as well. Remove either and the walk is the unattended
# drain the hold in docs/MAINTENANCE.md exists to prevent.

# --- an unchanged outbox counted as a release leaving it --------------------

mutation usenet-drain-walk-outbox-boundary-slack \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: a pass whose fingerprint never changes is killed and the walk attempts another" \
  --why "'<=' rather than '<' makes advanced answer yes on every pass, so the barren streak never increments and the walk runs its whole pass budget against a drain that is moving nothing. That is the grind --max-barren exists to stop: every pass costs a TorBox slot and a full payload re-download, and the outbox is the one number that only falls when a release is delivered or has terminally failed, which is why the comparison has to be exact about it" \
  --apply 'sed -i.bak "s@-lt \"\$b_outbox\"@-le \"\$b_outbox\"@" "$F" && rm -f "$F.bak"'

# --- the kill reaches the shell but not the fetch ---------------------------

mutation usenet-drain-walk-kill-leaves-the-fetch \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: killing a stuck pass takes the work under it too" \
  --why "signalling the shell in front of the pass instead of its process group leaves python3 and its curl writing into staging with nothing watching them, while the walk starts the next pass on the same pool -- two drains, one of them invisible to the state file, which is the shape of the 2026-09-20 incident with the pressure gate's accounting bypassed entirely. The walk would still report the pass as stopped" \
  --apply 'sed -i.bak "s@kill -TERM -\"\$pid\"@kill -TERM \"\$pid\"@" "$F" && rm -f "$F.bak"'
