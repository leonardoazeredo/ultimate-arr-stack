# TODO: When Home

## 1. ~~Fix stuck For All Mankind S05E01 download~~ DONE

Fixed remotely via Seerr — deleted request, re-requested, new download kicked off.

**Follow-up:** Check qBit for orphaned stuck torrent from the old STC release. May need manual cleanup.

## 2. ~~Set up Tailscale for remote admin access~~ DONE

Shipped. Tailscale runs on the NAS as a subnet router advertising the LAN, so every `.lan`
admin UI is reachable remotely with no port forwarding. See `docs/TAILSCALE.md` (setup,
split-DNS, and the failure modes hit along the way) and `docs/REMOTE-ACCESS.md`.

The follow-on exit-node work (ProtonVPN egress via `gluetun-exit` / `tailscale-exit`) is
tracked separately in `docs/EXIT-NODE-PROJECT-LOG.md`.
