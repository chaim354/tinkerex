"""Catalog integrity. Two of these encode audit findings that a grep or an exit code would miss."""
import json
import os

import pytest

import render
import schema
from app import CATALOG_DIR, _catalog, _source_path

NEEDS_BIN = pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                               reason="needs the real OpenSCAD binary (run inside the image)")

BANNED = ("-nc", "noncommercial", "-sa", "sharealike", "gpl", "agpl", "lgpl")


def _is_forbidden(license_str):
    """Does this licence string name a term spec §2 forbids?

    THE NEEDLES ARE LOWERCASE BECAUSE THE HAYSTACK IS LOWERCASED, and that is a bug fix rather
    than a style choice. This list was originally spelled ("-NC", ..., "-SA", ...) and compared
    against `.lower()`ed text, so `"-NC" in "cc-by-nc-sa-4.0"` was False and THE TWO TERMS THIS
    CATALOG EXISTS TO EXCLUDE COULD NEVER MATCH. `CC-BY-NC-SA-4.0` — the licence the dropped
    universal_stand declares in its own header — passed the guard cleanly. Only the four
    already-lowercase needles could ever fire.

    Found by mutation-testing the guard (feed it a known-bad entry, watch it stay green), not by
    reading it. A guard nobody has watched go red is not known to work; hence the test below.
    """
    low = (license_str or "").lower()
    return any(b in low for b in BANNED)


def test_every_entry_resolves_to_a_real_file():
    for e in _catalog():
        assert _source_path(e["key"]) is not None, f"{e['key']} -> missing {e['file']}"


def test_every_entry_records_a_permissive_licence_and_attribution():
    # Spec §2 made mechanical: a contributor adding an NC/SA/copyleft generator is stopped by a red
    # test rather than by review catching it.
    for e in _catalog():
        assert e["license"], f"{e['key']} has no licence"
        assert e["attribution"], f"{e['key']} has no attribution"
        assert e["source_ref"], f"{e['key']} has no pinned upstream commit"
        assert not _is_forbidden(e["license"]), f"{e['key']}: forbidden licence {e['license']}"


def test_the_licence_guard_actually_rejects_what_it_names():
    # The guard above is only worth having if it can go red. It could not: see _is_forbidden.
    # These are real spellings, not invented ones — CC-BY-NC-SA-4.0 is what the dropped
    # universal_stand declares in its own header while its repo LICENSE file says MIT, and it is
    # the single string this whole catalog most needs to reject.
    for bad in ("CC-BY-NC-SA-4.0", "CC-BY-NC-4.0", "CC-BY-SA-4.0", "GPL-2.0", "GPL-3.0",
                "AGPL-3.0", "LGPL-2.1", "NonCommercial", "ShareAlike"):
        assert _is_forbidden(bad), f"guard failed to reject {bad}"
    # ...and the permissive set spec §2 allows must survive it, or the guard just blocks everything.
    for ok in ("MIT", "Apache-2.0", "BSD-3-Clause", "CC0-1.0", "CC-BY-4.0", "Unlicense"):
        assert not _is_forbidden(ok), f"guard wrongly rejected {ok}"


def test_every_bundled_file_is_listed_in_notice():
    notice = open(os.path.join(CATALOG_DIR, "NOTICE")).read()
    for e in _catalog():
        assert e["file"] in notice, f"{e['file']} is bundled but not credited in NOTICE"
        assert e["source_ref"] in notice, f"{e['file']}'s pinned commit is not recorded in NOTICE"


def test_no_scad_in_the_catalog_dir_is_unlisted():
    # A file that got vendored but never added to catalog.json would be redistributed with no
    # licence record at all — the worst case, and invisible from the other direction.
    listed = {e["file"] for e in _catalog()}
    on_disk = {f for f in os.listdir(CATALOG_DIR) if f.endswith(".scad")}
    assert on_disk == listed, f"unlisted .scad files: {on_disk - listed}"


def test_no_entry_pulls_in_an_external_file():
    # A grep for include/use is NOT enough — import() and surface() also pull external files, and
    # OpenSCAD treats a MISSING import as a warning, exiting 0 with a silently wrong model. One
    # audited candidate passed the include-grep and still depended on three external STLs.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        for bad in ("include <", "use <", "import(", "surface("):
            assert bad not in src, f"{e['key']} references an external file: {bad}"


@NEEDS_BIN
def test_every_entry_exposes_parameters():
    # A module-shaped .scad yields an empty form — a catalog tile that does nothing. OpenSCAD stops
    # collecting at the first `{` and only accepts literal values, so this cannot be eyeballed.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        params = schema.normalize(render.params_for(src))["params"]
        assert len(params) >= 5, f"{e['key']} exposes only {len(params)} params"


@NEEDS_BIN
def test_every_entry_renders_a_substantial_model_at_its_defaults():
    # THE AUDIT'S SHARPEST FINDING, made mechanical: a missing import() is a WARNING, so OpenSCAD
    # exits 0 and writes a stub. Asserting "it rendered" would pass on a model with the geometry
    # missing. Assert the OUTPUT IS BIG ENOUGH to be a real model instead.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        result = render.render(src, {}, "3mf", cache_dir="/tmp/catalog-cache")
        assert result.bytes[:2] == b"PK"
        assert len(result.bytes) > 2000, \
            f"{e['key']} rendered only {len(result.bytes)} bytes — likely a stub from a missing import"
