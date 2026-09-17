# shellcheck shell=bash
# Corpus: scripts/indexer-guard.sh and the demand gate it now carries.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# Two halves. The wrapper's own validation and rotation order are covered
# through tests/indexer-guard.bats below. The demand gate -- the join that
# decides whether a banned indexer is one Sonarr actually needs -- lives in
# scripts/lib/indexer_guard.py, which is on the generated sweep's no-sweep list
# for the wrapper but IS a generated target itself; its hand-written entries
# below run through tests/python-suite.bats, the same oracle every other
# scripts/lib/*.py corpus entry uses.
#
# `perl -0777 -pi`, not `sed -i`: an entry should replay on the Mac as well as
# on Linux, and BSD sed reads -i's next argument as a backup suffix. See
# tests/mutation/README.md.

# --- only the literal 0 is refused as an interval ---------------------------

mutation indexer-guard-only-literal-zero-refused \
  --file scripts/indexer-guard.sh \
  --bats tests/indexer-guard.bats \
  --test "^indexer-guard: every all-zero interval spelling" \
  --why "the all-zero arm is the only thing between a .env of 00 and argparse, which refuses it: positive_seconds reads 00 as zero, exits 2, and the guard stops with an error instead of falling back to the module's six-hour default, so one bad spelling in .env disables the ban guard entirely. gluetun-rotator refuses every spelling of zero for the same reason, and the all-zero test is the only thing here that says the guard does too" \
  --apply 'perl -0777 -pi -e "s/^  \\*\\[!0\\]\\*\\) ;;\\n  \\*\\)\$/  0)/m" "$F"'

# --- Sonarr's " (Prowlarr)" suffix is not stripped --------------------------
#
# Note the contrast with the entry below: this one is a hold that should not
# have happened, and it is the quieter of the two failures. Nothing errors,
# nothing logs, and the guard simply stops rotating -- because the name Sonarr
# stores ("EZTV (Prowlarr)") no longer equals the name Prowlarr stores
# ("EZTV"), so no banned indexer ever has demand.

mutation indexer-guard-demand-name-suffix-not-stripped \
  --file scripts/lib/indexer_guard.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "demand is a join on the indexer's NAME, and the two services spell it differently: Sonarr stores Prowlarr's indexer as 'EZTV (Prowlarr)' where Prowlarr's own document says 'EZTV'. Without the suffix coming off, every banned indexer normalises to a name that can never be in the demand set, so the gate holds every rotation and the guard silently stops doing its job while its log says 'no Sonarr demand'" \
  --apply 'perl -pi -e "s/\Q        text = text[: -len(PROWLARR_SUFFIX)].strip()\E/        text = text/" "$F"'

# --- unknown demand holds instead of failing open ---------------------------
#
# The fail-open rule, inverted. Absent demand data is not "no demand": Sonarr
# being unreachable for one pass must not ground a banned IP for every indexer
# the stack does use, which is the outage the whole guard exists to end.

mutation indexer-guard-demand-unknown-holds \
  --file scripts/lib/indexer_guard.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "a Sonarr that could not be reached (no API key, a timeout, a document that is not JSON) is read as 'nothing here has demand', so the gate holds every rotation for as long as Sonarr is unhappy -- and a banned exit IP stays in place with every public indexer failing behind it. Fail-open is the documented direction: unreadable demand skips the gate and the rotation happens on Prowlarr's evidence, with a note saying it was skipped" \
  --apply 'perl -pi -e "s/\Q        return rotate, demand_note(reason, note), hold\E/        return False, demand_note(reason, note), hold/" "$F"'

# --- the wrapper never hands Sonarr's documents to the module ---------------
#
# The gate is only real if the second decision gets the pages: the wrapper
# fetches them, and this assignment is the one place they reach the module. Drop
# it and the pass still fetches Sonarr, still decides twice, and decides the
# same thing both times -- a hold that should have happened becomes a rotation,
# with the outage that costs.

mutation indexer-guard-demand-flags-never-passed \
  --file scripts/indexer-guard.sh \
  --bats tests/indexer-guard.bats \
  --test "^indexer-guard: a banned indexer Sonarr has no demand for holds" \
  --why "the pages the wrapper fetched stop at the wrapper, so the module decides on Prowlarr's evidence alone -- and the gate is silently gone. The pass still writes ten Sonarr page files and still runs the module twice, which is exactly what makes it invisible: the log reads as an ordinary decision, and the guard rotates the VPN for an indexer Sonarr has never downloaded anything from" \
  --apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"  DEMAND_ARGS=(\\\"\${missing[@]}\\\" \\\"\${history[@]}\\\")\";new=\"  DEMAND_ARGS=()\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'

# --- a document read short is judged as complete ----------------------------
#
# The walk is bounded twice over -- by DEMAND_MAX_PAGES and by the pass's time
# budget -- so the pages in hand are not always the whole document, and the
# envelope's totalRecords is the only thing that says so. Removing the
# comparison makes a truncated read look like a complete one, and that failure
# is a false HOLD, the dangerous direction: an indexer whose grabs are all on
# the pages nobody fetched looks exactly like an indexer with no demand, so the
# banned IP stays in place while every indexer behind it fails. Live history is
# already past five thousand records, and the fixed five-page walk is what this
# cost.

mutation indexer-guard-demand-truncation-not-noticed \
  --file scripts/lib/indexer_guard.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "a history, a missing list or both that the walk did not cover is read as the whole document, and the join is made on the slice that arrived. That is the pre-fix behaviour exactly: an indexer with real demand whose recent grabs are on the pages that were never fetched has no demand as far as the gate can tell, so the rotation is held and the banned exit IP stays in place. The note ('Sonarr history truncated: 5000 of 7120 records') is what says so, and this deletes the judgement behind it" \
  --apply 'perl -pi -e "s/\Q    if total is None or collected >= total:\E/    if True:/" "$F"'

# --- the early stop ignores totalRecords ------------------------------------
#
# totalRecords is what makes the walk as long as the document needs and no
# longer: page one's envelope carries it, --page-total reads it, and the number
# of pages fetched is the ceil of it. Ignoring it and fetching the cap every
# time is not merely the wasted requests the fixed walk used to make -- with the
# cap at 20 it is forty requests on a pass whose documents fit in three, and the
# count the module needs to notice a short read arrives unused. The page count
# is the assertion, because a document that fits inside the cap decides the same
# way either way.

mutation indexer-guard-demand-pages-ignore-total \
  --file scripts/indexer-guard.sh \
  --bats tests/indexer-guard.bats \
  --test "^indexer-guard: a 1500-record document is fetched in exactly two pages" \
  --why "the walk fetches DEMAND_MAX_PAGES pages of every document whatever its envelope says, so a stack whose missing list is three pages and whose history is eight pays forty Sonarr requests per pass instead of eleven -- inside a systemd timer, on the service that serves every search. The count is still read for the truncation note, which is what makes this quiet: the decision is right, and only the request count shows the walk is no longer sized by the document" \
  --apply 'perl -pi -e "s/        pages=\".*needed.*\"/        pages=\"\\\$DEMAND_MAX_PAGES\"/" "$F"'
