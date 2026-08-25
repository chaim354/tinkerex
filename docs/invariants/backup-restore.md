# Invariants — backup and restore (CLAUDE.md §14i)

> **This is CLAUDE.md's §14i, moved out of the always-loaded file on 2026-08-25.** It binds when you
> touch `ops/backup-db.sh`, `bin/backup-db`, `bin/restore-db`, `bin/backup-status`, or
> `bin/backup-cron-install` — and not at all otherwise. **The rules did not change and nothing was
> dropped.**
>
> **The `§14i` anchor still exists in CLAUDE.md** and anything citing it resolves to the stub there,
> which points here. `docs/DEPLOY.md` §6 restates these for operators.

> **NOTHING IN `bin/ci` CAN GO RED FOR ANY LINE BELOW** — this is shell, cron and docs, and the five
> scripts have no gate at all. Their shared failure mode is *you find out when you need a restore*.
> **Only CROSS-FILE rules are here.** The single-site ones (`tar --anchored`, `docker ps -a`,
> `--keep` ≥ 1 and its deliberate divergence from §14a, `ping.env` parsed-never-sourced, the Active
> Storage blobs in the archive) carry their whole argument *inside `ops/backup-db.sh` itself* — beside
> the line you must edit to break them, or in that file's header — so loading them every session buys
> nothing that opening the file does not. They are not weaker for it; `docs/DEPLOY.md` §6 restates
> them for operators. Below spans two files or more, where no one comment can be the guard.
> `docs/STATUS.md` has the arc and the stubbed-box harness. Prove a change against stubs, never the
> live NAS or a real volume.

- **`ops/backup-db.sh` IS THE ONLY IMPLEMENTATION, AND `bin/backup-cron-install` IS THE ONLY THING
  THAT WRITES THE INSTALLED COPY.** `bin/backup-db` pushes to a per-run temp path; it used to `scp`
  straight onto `~/tinkerex-ops/backup-db.sh`, so every ad-hoc run — including the pre-restore one
  inside `bin/restore-db`, fired mid-incident — silently replaced what cron would execute that night
  with whatever was in that person's checkout. Two unsynchronised writers to one remote file is not
  "one implementation, two callers"; it is a way for an unrelated command to change the nightly.
- **A `--to-stdout` RUN NEVER PINGS, IN EITHER DIRECTION — and the vanished-container arm sits ABOVE
  the `$TO_STDOUT` branch, so it must opt out ITSELF.** An ad-hoc `up` papers over a nightly dead for
  a week; an ad-hoc `down` marks the nightly failing over a backup to someone's laptop. Both corrupt
  the same signal, and the second shipped. The failure is still reported, by exit status, to whoever
  is standing there.
- **`--to-volume` REFUSES A VOLUME WITH NO DEVICE OPTION, because a missing volume IS NOT AN ERROR TO
  DOCKER** — `docker run -v name:/dst` **creates** it, plain-local, on the VM's own disk. The job then
  writes ~44 MB a night into the disk the array exists to avoid, verifies its own archives there, and
  pings green, while `bin/backup-status` reads the same recreated name and calls it healthy. The
  installer compares the EXACT device (it knows `BACKUP_NAS`); the nightly is handed only a name and
  asks the weaker sufficient question — do **not** thread the path through the crontab line, where a
  bare `%` is a newline and this box has a share whose name contains a space.
- **THE ARGUMENT GUARDS EXIT BEFORE ANY PING; THE VOLUME GUARD PINGS `down`. Do not harmonise them.**
  A bad `--keep` is a typo from someone still at the keyboard, and a monitor event for a run that
  never started is noise. A volume that has stopped pointing at the array is box state that will fail
  unattended at 03:30 with nobody watching — knowable now, like the vanished container, so it is said
  now.
- **THE REHEARSAL VERIFY RUNS AS THE CONTAINER'S OWN `Config.User`, NEVER `--user 0`.** Root reads a
  file whatever its mode, so the root version could not fail for the one reason `--into` exists — it
  shipped advertising "file ownership" it structurally could not test. It does **not** boot the app
  and must not claim to: a bare `docker run` has no `RAILS_MASTER_KEY` and no `LIBRARY_*`, so
  `LibraryBackendCheck` (§14a) refuses and the failure says nothing about the archive.
- **`--no-pre-backup` EXISTS, AND THE DEFAULT STAYS FATAL.** The reasons `bin/backup-db` fails — a
  corrupt database, a container that will not start — are the reasons you are restoring, so the
  safety net could block the emergency it exists for; but making a failed pre-backup non-fatal
  restores over a state nobody preserved. The refusal names the flag instead.
- **THE SCHEDULE'S TIMEZONE IS ASSERTED, NOT PINNED WITH `CRON_TZ`.** A crontab time is a LOCAL time
  and a stock Ubuntu VM is `Etc/UTC`, which fires the documented 03:30 at 23:30 Eastern with nothing
  looking wrong. `CRON_TZ` looks like the stronger move and is worse: a cron that does not implement
  it (busybox; it is not POSIX) parses the line as an ordinary environment assignment and ignores it
  — a guard that silently does nothing. The installer reads the zone back and refuses *before*
  touching anything; `bin/backup-status` re-reads the BOX's zone, but the LINE records none — so it
  compares against its own `BACKUP_TZ` default, and a zone ACCEPTED at install reads as a mismatch.
- **The archives are UNENCRYPTED on a guest-writable CIFS share, and that is a recorded decision, not
  an oversight** — readable *and deletable* by anyone on the LAN. Accepted for a home LAN; the
  catalog and every preview blob are in the clear (the digests are the least of it). Revisit before
  this box is reachable from anywhere else, and alongside `docs/plan-encryption.md` (§12.2), which is
  the same question one layer down. `docs/DEPLOY.md` §6 states what each alternative costs.
