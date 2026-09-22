#!/bin/bash
# Guards added with scripts/usenet-drain-walk.sh, 2026-09-22.
#
# The walk is the only thing in this stack that runs usenet passes without a
# person watching each one, and the properties below are what make that
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

# --- a refusal counted against the drain again ------------------------------

mutation usenet-drain-walk-refusal-counted-as-barren \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: a pass the pressure gate refused is not a barren pass" \
  --why "the increment lands on BARREN instead of REFUSED, which is the defect this branch removed: a pass the gate refused never started, so it says nothing about whether the drain is moving. With --max-barren 1 the walk then stops after a single attempt, and on the real 2026-09-22 run it printed '4 passes in a row made no progress' for four passes that never ran -- the sentence an operator reads first, and the one that sends them to look at the queue instead of the host" \
  --apply 'sed -i.bak "s@REFUSED=\$((REFUSED + 1))@BARREN=\$((BARREN + 1))@" "$F" && rm -f "$F.bak"'

# --- a refusal no longer recognised as one ----------------------------------

mutation usenet-drain-walk-refusal-phrase-not-matched \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: only the real gate's refusal counts as one" \
  --why "the phrase match is the whole separation between a pass the gate refused and a pass that ran: scripts/usenet-blackhole.sh prints four lines carrying the pressure-gate prefix and only the one that says the pass is skipped means nothing ran. Drop the phrase and a pass the gate admitted goes on the refusal counter, so the walk stands a busy host down under a reason the host did not give, and blames the host for passes that actually ran. The oracle drives the real pass script because the phrase is that script's own output, and a stub that hardcodes it cannot keep it honest" \
  --apply 'sed -i.bak "s@skipping this pass@skipping nothing@" "$F" && rm -f "$F.bak"'

# --- a refusal bound that lets one more pass through ------------------------

mutation usenet-drain-walk-refusal-bound-off-by-one \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: a host too busy to start a pass stands the walk down on its own reason" \
  --why "'-gt' in place of '-ge' lets the walk attempt one more pass than --max-skipped allows, and each one it will not start is a 300s skip-cooldown: --max-skipped stops being the bound the flag and the --help text say it is, so a saturated host is hammered once more per walk than the operator asked for. The test counts invocations, so a third attempt against a bound of two is what goes red" \
  --apply 'sed -i.bak "s@-ge \"\$MAX_SKIPPED\"@-gt \"\$MAX_SKIPPED\"@" "$F" && rm -f "$F.bak"'

# --- the cumulative count aliased to the streak -----------------------------

mutation usenet-drain-walk-refused-total-aliased-to-streak \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: the refusal count is cumulative, not the current streak" \
  --why "REFUSED_TOTAL aliased to REFUSED prints the streak the run happened to end on instead of how much of the run the gate refused, so a run with three separate refusal streaks is reported as the last of them and the summary understates exactly the number that says whether the host is the problem. Every other test builds a single streak, which is why the refused-admitted-refused case is the one that has to catch it" \
  --apply 'sed -i.bak "s@REFUSED_TOTAL=\$((REFUSED_TOTAL + 1))@REFUSED_TOTAL=\$REFUSED@" "$F" && rm -f "$F.bak"'

# --- a bound that accepts zero ----------------------------------------------

mutation usenet-drain-walk-max-skipped-zero-accepted \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: --max-skipped must be a positive whole number" \
  --why "relaxing the minimum to '-lt 0' accepts --max-skipped 0, a bound reached before the first pass starts: on a host the gate refuses, the walk ends with no pass attempted and only the refusal line to explain it, and the flag the operator set to mean 'never give up quickly' means the opposite. The whole-number and missing-value checks still fire, so the no-argument case is not what catches this" \
  --apply 'sed -i.bak "s@\"\$MAX_SKIPPED\" -lt 1@\"\$MAX_SKIPPED\" -lt 0@" "$F" && rm -f "$F.bak"'

# --- a wait that buys nothing after the walk has decided to stop ------------

mutation usenet-drain-walk-terminal-refusal-still-waits \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: a host too busy to start a pass stands the walk down on its own reason" \
  --why "dropping the wait guard means the refusal that takes REFUSED to --max-skipped still logs and sleeps the skip-cooldown, although the loop top stops the walk before another pass could run: at the shipped 300s that is five minutes of silence at the end of the one run an operator is watching, and a walk that has already decided to stop reads as a hang. The test counts the wait lines for exactly two refusals, so the second one is what goes red" \
  --apply 'sed -i.bak "s@if \[\[ \"\$REFUSED\" -lt \"\$MAX_SKIPPED\" \]\]; then@if true; then@" "$F" && rm -f "$F.bak"'
