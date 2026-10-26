# Security

Tinkerex is self-hosted software that holds a maker's files, so a vulnerability in it is a
vulnerability in someone's home server. Please report one privately, not in a public issue or
pull request.

## Reporting a vulnerability

Open a private report on GitHub: this repository's **Security** tab, then **Report a
vulnerability**. It reaches the maintainer and nobody else. The same door exists on the sibling
repositories, `chaim354/tinkerex-sync`, `chaim354/tinkerex-client` and `chaim354/tinkerex-addons`,
so report against the repository that holds the code, and use this one when unsure.

Include what you can: the affected version or image digest, the `LIBRARY_BACKEND` in use, the steps
to reproduce, and what an attacker gains. A proof of concept against your own installation is
welcome. Please do not test against `tinkerex.com`: its demo account is shared by everyone who
clicks **Try the demo**, and anything beyond what that account is allowed to do affects other
visitors.

Expect an acknowledgement within a week. This is a one-person project with no bug bounty: a fix
lands as an ordinary pull request, the report is credited in it unless you ask otherwise, and the
advisory is published once the fix is out.

## Scope

In scope: the Rails app in this repository and the images built from it
(`ghcr.io/chaim354/tinkerex`, `boxes-sidecar`, `openscad-sidecar`), the addon bundles
(`tinkerex-addons`), the sync server (`tinkerex-sync`) and the desktop client (`tinkerex-client`).

Two things are documented behaviour rather than flaws, and belong in an ordinary issue if you think
they should change: on the `share` and `s3` backends every account on one server indexes the same
library (`docs/INSTALL.md`), and the public demo's library is wiped and re-seeded nightly.

## Supported versions

Only the current `main` branch and the `:latest` images are supported. There are no release
branches yet.
