# Usenet recovery: follow-ups not load-bearing for the retry-storm fix

Split out of `PLAN-USENET-RECOVERY.md` per adversarial review, 2026-09-15:
none of this is required to fix the retry-storm that plan exists for, and
bundling it there made "the plan" hard to call done.

## The live download view

The work agreed before that plan, and still worth doing, though its shape
changes once that plan's Phase 1 lands: the arrs will show failures, but they
still cannot show what is in flight through a blackhole.

- `scripts/usenet-blackhole-status.sh` reading the state file and log into JSON
  or HTML.
- A small dedicated service to serve it. No existing container can: `homepage`
  publishes no port and its config directory is not writable by `leoleg`, and
  `duc` runs a fixed-file `log.cgi`.
- A Homepage tile pointing at it.
- Adds a container, so it needs the usual config-volume backup before its
  first deploy and a compose-aware recreate afterwards.

Shipped: `scripts/usenet-blackhole-status.sh` renders the state file,
`scripts/usenet-status-render.timer` keeps the page current every two minutes,
and `docker-compose.utilities.yml`'s `usenet-status` service serves it at
`https://usenet.lan` behind Traefik's admin auth, with no host port published
(PR #88 and the commits behind it). Done.

One piece of the list above was not built: `homepage/config/services.yaml` has
no tile for the page.

## Housekeeping, independent of everything else

Re-checked 2026-09-17.

- `scripts/lib/backlog_search.py` is missing from `TARGETS` in
  `tests/mutation/run-generated.sh`, so it has an oracle and no sweep. Fixed and
  merged in PR #87; the sweep lists it now. Done.
- `docs/APP-CONFIG.md` still describes Usenet-Crawler as free with a 50-hit
  limit. The account is paid, and the free-tier reasoning behind that passage
  was wrong. Fixed and merged in PR #87, which corrected the same claim in
  `docs/SETUP.md`. Done.
- 1337x was disabled in Prowlarr until `2026-09-14T19:58:20Z`. That has passed.
  Re-test it and either re-enable it or record why it stays off. Checked in
  Prowlarr on 2026-09-17: enabled (`enable=true`, indexer id 3). The disable
  window expired as expected and nothing needs doing. Done.
- Radarr's three Star Wars films sit at `importBlocked`. Read the status
  messages and either fix the match or clear them. Radarr's queue holds zero
  items as of 2026-09-17, so nothing is actively wedged at `importBlocked` right
  now. An empty queue is not the same as the films being in the library:
  `GET /api/v3/movie` on 2026-09-17 shows three still `hasFile: false` and still
  monitored, "Star Wars: The Force Awakens" (2015), "Star Wars: Squadrons -
  Hunted" (2020) and "Star Wars Rebels: Spark of Rebellion" (2014). Still open.
- The four Friends episodes that failed a RAR checksum, S02E11/12/14/15, look
  like the same corrupt-at-source pattern as Sopranos. Confirm and blocklist
  rather than re-grabbing. Measured 2026-09-17: S02E12, S02E14 and S02E15 now
  have files, and only S02E11 is still missing and still monitored. The
  corrupt-at-source reading held for at most one of the four, and three
  recovered on a later grab, so a checksum failure on this stack is not by
  itself evidence that a release is corrupt at source. S02E11 is the only open
  part.

## Open questions for the owner

1. Sopranos S01E09: the only release without the corrupt header has Polish
   audio. Take it, or leave the hole?

2. Star Wars: three films still lack a file despite an empty Radarr queue, and
   all three are still monitored. Worth a targeted fix, or clear them from
   monitoring and move on? `/api/v3/movie` on 2026-09-17 shows "Star Wars: The
   Force Awakens" (2015), "Star Wars: Squadrons - Hunted" (2020) and "Star Wars
   Rebels: Spark of Rebellion" (2014) all `hasFile: false`.

3. Is Decypharr meant to stay? It imported nothing overnight while usenet
   carried everything, and nobody has established whether that is by design.
