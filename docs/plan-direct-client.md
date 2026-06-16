# Implementation Plan — Direct-Client JuiceFS (no gateway) — ABANDONED

**Status:** ABANDONED (superseded by the local-first sync engine). Kept as a one-line
pointer only — the full blow-by-blow plan (Neon pooler-vs-direct, four-layer
volume-per-tenant isolation, the Phase-0 JuiceFS-over-WAN runbook) lived here and is now in
**git history** (see this file before the consolidation commit on branch `docs-consolidation`).

## Why it was abandoned

A remote-mounted filesystem over the WAN is **~1 s/file** (synchronous metadata
round-trips), and JuiceFS additionally has no internal ACL (multi-tenancy would need
volume-per-tenant + per-tenant DB roles + a gateway) and FUSE-driver licensing friction. See
**`docs/roads-not-taken.md` §1–§2** for the condensed decision + rationale, and
`CLAUDE.md` §14.

## Current approach

The **local-first sync engine** — local SQLite metadata + async sync + on-demand byte
hydration over FastCDC content-addressed chunks. See `docs/architecture-sync-engine.md`,
`docs/sync-protocol.md`, `CLAUDE.md` §2.

> Leftover code from this path: `client/juicefs-backend` + `client/maker-app-core`
> (reference only).
