# TODO: When Home

## 1. ~~Fix stuck For All Mankind S05E01 download~~ DONE

Fixed remotely via Seerr — deleted request, re-requested, new download kicked off.

**Follow-up:** ~~Check qBit for orphaned stuck torrent from the old STC release.~~ DONE
(2026-09-04) — checked `qbit.lan` directly, no STC-release entry present. The only
S05E01 item left is the new ELiTE-release download from the re-request, complete at
100%. The old STC torrent is already gone, most likely swept by `queue-cleanup.sh`'s
weekly stuck-item removal before this was checked manually. No action needed.

## 2. ~~Set up Tailscale for remote admin access~~ DONE

Shipped. Tailscale runs on the NAS as a subnet router advertising the LAN, so every `.lan`
admin UI is reachable remotely with no port forwarding. See `docs/TAILSCALE.md` (setup,
split-DNS, and the failure modes hit along the way) and `docs/REMOTE-ACCESS.md`.

The follow-on exit-node work (ProtonVPN egress, now via `arr-stack-router` natively rather
than the decommissioned NAS-based `gluetun-exit`/`tailscale-exit` pair) is tracked separately
in `docs/EXIT-NODE-PROJECT-LOG.md`.
