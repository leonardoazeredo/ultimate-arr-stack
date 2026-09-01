# Corpus: the generative half's own guards.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# run-generated.sh, mutator.sh and lib-mutate.sh are verification tools, so they
# get the treatment they impose. Every guard below was added because something
# went wrong without it; each entry proves the guard is capable of noticing.
#
# These mutate files that run-mutations.sh has already sourced or will only
# invoke as a child process. `sed -i` writes a temp file and renames it, so the
# running bash keeps its original inode, and a sourced file is read once at
# source time -- the already-loaded function bodies are unaffected. The mutation
# is visible only to the child the fixture spawns, which is the thing under test.

mutation gen-subshell-guard-removed \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "refuses to arm the restore path from a subshell" \
  --why "take_backup called in \$(...) sets CURRENT_FILE in a subshell that discards it, so restore_current no-ops and mutated files are left in the tree - this is the bug the lib-mutate.sh extraction actually shipped" \
  --apply 'sed -i "s@^    if \[\[ \"\$BASHPID\" != \"\$\$\" \]\]; then\$@    if false; then@" "$F"'

mutation gen-backup-does-not-arm-restore \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "arms the restore path when called plainly" \
  --why "take_backup copies the file aside but never sets CURRENT_FILE, so every restore is a silent no-op and the tool reports verdicts over a mutated tree" \
  --apply 'sed -i "s@^    CURRENT_FILE=\"\$file\"; CURRENT_BACKUP=\"\$BACKUP_PATH\"\$@    :@" "$F"'

mutation gen-dirty-tree-check-removed \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "refuses to start on a dirty target" \
  --why "the sweep overwrites tracked files in place; started on a dirty tree, a failed restore is indistinguishable from the user's own uncommitted work and the documented recovery destroys it" \
  --apply 'sed -i "s@^if \[\[ -n \"\$DIRTY\" \]\]; then\$@if false; then@" "$F"'

mutation gen-absent-docker-looks-like-success \
  --file tests/mutation/mutator.sh \
  --bats tests/mutation-framework.bats \
  --test "reports an absent docker distinctly" \
  --why "exiting 0 when docker is unavailable makes 'could not generate any mutants' identical to 'the sweep found nothing' - the same silent-success shape sync-nas.sh shipped for an unreachable NAS" \
  --apply 'sed -i "0,/^    exit 77\$/s@^    exit 77\$@    exit 0@" "$F"'
