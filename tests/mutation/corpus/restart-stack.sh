# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/restart-stack.sh.
#
# Safe to run: the oracle evaluates the extracted `case` block with
# restart_compose replaced by a logger, and keeps the fatal docker stub on PATH
# underneath. A mutant that escaped the extraction would hit the stub and fail
# loudly rather than restarting anything.

mutation restart-stack-consumer-before-network-owner \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: the 'all' order matches the compose files' own dependencies" \
  --why "restarts traefik before the file that creates the network traefik declares external. This is the order the script actually shipped with until 2026-09-01, and it survived because the network already existed on the one machine it was ever run on. On a machine where arr-core is absent - a fresh deploy, or after a network prune - traefik fails, set -e aborts the run, and the command someone reaches for when the house has no DNS never gets as far as starting DNS" \
  --apply 'sed -i "/^    all)/,/^        ;;/{ /traefik.yml .traefik./d; s@^    all)\$@    all)\n        restart_compose docker-compose.traefik.yml \"traefik\"@ }" "$F"'

mutation restart-stack-magnetio-after-arr-stack \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: magnetio comes up before arr-stack" \
  --why "moves magnetio to the end of the all arm, which is where it was first added. docker-compose.arr-stack.yml declares magnetio-net external and gluetun joins it, so recreating gluetun before that network exists fails with \"network not found\" - and under set -e the run stops there, taking DNS with it. Ordering that costs nothing to get right and everything to get wrong" \
  --apply 'sed -i "/^    all)/,/^        ;;/{ /magnetio.yml .magnetio./d; s@^        restart_compose docker-compose.utilities.yml \"utilities\"\$@        restart_compose docker-compose.utilities.yml \"utilities\"\n        restart_compose docker-compose.magnetio.yml \"magnetio\"@ }" "$F"'

mutation restart-stack-magnetio-dropped-from-all \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: 'all' covers every compose file except the ones it names" \
  --why "drops a compose file from the all arm, which is the state this script was actually in: it claimed to restart all compose files while covering four of six. The oracle derives the expected set from the filesystem, so this is the entry that proves the derivation is doing work rather than restating a list" \
  --apply 'sed -i "/^    all)/,/^        ;;/{/magnetio/d}" "$F"'

mutation restart-stack-tailscale-in-all \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: 'all' does not restart tailscale" \
  --why "adds tailscale to the all arm. Recreating Tailscale node 1 severs SSH and the UGOS admin UI at the same instant, because both ride its own subnet route - the command that would undo it arrives over the link it just cut. The excluded list is only meaningful if something asserts the positive direction too" \
  --apply 'sed -i "/^    all)/,/^        ;;/s@restart_compose docker-compose.magnetio.yml \"magnetio\"@restart_compose docker-compose.magnetio.yml \"magnetio\"\n        restart_compose docker-compose.tailscale.yml \"tailscale\"@" "$F"'

mutation restart-stack-alias-maps-to-wrong-file \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: each alias maps to the compose file that defines it" \
  --why "points the traefik target at another compose file. CLAUDE.md's rule is that a service is only ever recreated through the file that defines it: traefik brought up any other way loses its traefik-lan macvlan and every .lan URL in the house dies. The command succeeds, which is the problem" \
  --apply 'sed -i "/^    traefik)/,/^        ;;/s@docker-compose.traefik.yml@docker-compose.arr-stack.yml@" "$F"'

mutation restart-stack-remove-orphans \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: --remove-orphans is never in the argv, --force-recreate always is" \
  --why "adds --remove-orphans. The stack's services are split across compose files sharing one project name, so compose treats every container from the other files as an orphan and deletes them. It took out 11 containers on 2026-08-01" \
  --apply 'sed -i "s@up -d --force-recreate@up -d --force-recreate --remove-orphans@" "$F"'

mutation restart-stack-down-then-up \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: 'down' is never in the argv on any path" \
  --why "restarts by bringing the stack down first. The file's header states avoiding this as its entire reason to exist: down takes Pi-hole with it, and Pi-hole is the house's DNS, so the window is not a restart - it is an outage that also breaks the tools used to diagnose it" \
  --apply 'sed -i "s@docker compose -f \"\$file\" up -d --force-recreate@docker compose -f \"\$file\" down\n    docker compose -f \"\$file\" up -d@" "$F"'

mutation restart-stack-unknown-target-succeeds \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: an unknown target prints usage and restarts nothing" \
  --why "exits 0 on an unrecognised target. A typo then restarts nothing and reports success, which is the worst of the three possible answers: the operator believes the stack was recreated and moves on" \
  --apply 'sed -i "s@^        exit 1\$@        exit 0@" "$F"'

mutation restart-stack-default-target-narrowed \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: no argument is the same as 'all'" \
  --why "changes the no-argument default. A bare invocation is the documented way to restart everything, and this makes it silently restart one file instead - the operator sees the same success output either way" \
  --apply 'sed -i "s@\${1:-all}@\${1:-arr}@" "$F"'

mutation restart-stack-usage-omits-a-target \
  --file scripts/restart-stack.sh \
  --bats tests/restart-stack.bats \
  --test "restart-stack: the usage line names every target the dispatcher accepts" \
  --why "drops a target from the usage line. A usage string is documentation that lives inside the code it documents, and this is exactly how it goes stale: magnetio was added to the dispatcher in one edit and the usage line was not" \
  --apply 'sed -i "s@|magnetio|all]@|all]@" "$F"'
