require "test_helper"

module Maker
  module Previews
    # THE ABSOLUTE PIN FOR THE `thumbnail` KIND — and it exists because reverting a
    # `THUMBNAIL_REVISION` used to turn NOTHING red.
    #
    # Measured 2026-09-03 (tinkerex#220), by mutation rather than by reading: with
    # `Dxf::THUMBNAIL_REVISION` reverted 2 -> 1 and every other change of that branch in place, the
    # whole suite reported `2915 runs, 11503 assertions, 0 failures`. A renderer whose thumbnail
    # output has genuinely changed could ship with its revision unbumped, entirely green.
    #
    # WHY THE GUARDS THAT EXIST DO NOT COVER IT. Every other thumbnail-revision assertion in this
    # repo is a RELATIONSHIP pin — `Stl::THUMBNAIL_REVISION == Enqueue.revision_for_name("a.stl",
    # "thumbnail")`, ThreeMf-tracks-Stl, the same shape for Lbrn2 — and a relationship is satisfied
    # by ANY value, so shifting both sides together is invisible to all of them. It is the same
    # argument `GeometryTest::GEOMETRY_REVISIONS` already makes for the `geometry` kind, which is
    # why reverting `DxfGeometry::FORMAT_REVISION` in that same session DID go red with a named
    # message while its thumbnail twin did not. This file is that guard for the other kind.
    #
    # AND THE BYTE-DIGEST GUARDS POINT THE OTHER WAY. `dxf_geometry_test.rb` catches "the SVG moved
    # and the digest was not updated". It cannot catch "the digest WAS updated and the revision was
    # not" — which is the real failure mode, because the person updating a digest is the same person
    # who should be bumping the revision, in the same edit, having just watched the bytes move.
    #
    # WHAT A MISS COSTS. §14h: a stored artifact goes stale on the CODE axis as well as the CONTENT
    # one, and a finished design's content never changes. An unbumped thumbnail revision means every
    # already-rendered file of that format serves the OLD picture forever, with nothing anywhere to
    # report it — which is not hypothetical: 172 of 174 LightBurn thumbnails sat at revision 1
    # through two deploys that had bumped it.
    class ThumbnailRevisionTest < ActiveSupport::TestCase
      # ONE FILENAME PER DISTINCT RENDERER, plus `.lbrn2` beside `.lbrn`.
      #
      # THE DUPLICATE IS DELIBERATE, for `GEOMETRY_REVISIONS`' own stated reason: both extensions
      # route to `Lbrn2`, so a one-name check cannot see a DELEGATION regression — an extension
      # quietly falling out of the Registry resolves to no renderer and answers `BASE_REVISION`,
      # which looks like a perfectly ordinary 1.
      #
      # A VALUE OF 1 IS NOT NECESSARILY A DECLARATION. `TextThumb`, `Mesh`, `ImageThumb` and `Pdf`
      # declare no `THUMBNAIL_REVISION` at all and reach 1 through `Enqueue::BASE_REVISION`. Pinning
      # them anyway is the point: the day one of them starts declaring — or the day a rename makes
      # an extension resolve to nothing — this table is what notices, and the two cases are
      # indistinguishable from the outside, which is exactly why the pin is on the RESOLVED value
      # rather than on the constant.
      THUMBNAIL_REVISIONS = {
        "a.asm"   => 1, # TextThumb  — 62 extensions route here
        "a.bmp"   => 1, # ImageThumb — 6
        "a.iges"  => 1, # Mesh       — 5 (obj/step/stp/iges/igs)
        "a.pdf"   => 1, # Pdf
        "a.svg"   => 1, # Svg
        "a.mage"  => 1, # Mage       — its own renderer for thumbnails, unlike its geometry leg
        "a.stl"   => 2, # Stl
        "a.dxf"   => 2, # Dxf
        "a.3mf"   => 2, # ThreeMf
        "a.lbrn"  => 4, # Lbrn2
        "a.lbrn2" => 4  # Lbrn2 again — see the delegation note above
      }.freeze

      test "a renderer's thumbnail revision moves only when this pin moves with it" do
        THUMBNAIL_REVISIONS.each do |filename, expected|
          assert_equal expected, Enqueue.revision_for_name(filename, "thumbnail"),
                       "#{filename} changed thumbnail revision — every stored thumbnail of that " \
                       "format re-renders. Confirm that is intended before updating this number."
        end
      end

      # ENUMERATED FROM THE REGISTRY, NOT COMPARED AGAINST ITSELF. Listing the renderers this table
      # happens to name and checking they are registered would assert nothing; discovering which
      # renderers the Registry can actually reach is what makes a NEW format inherit this guard on
      # the day it is added rather than the day someone remembers to extend the list. Same
      # construction as `Geometry::REVISIONED_BY`'s enumeration in `geometry_test.rb`.
      test "every renderer the Registry can reach is pinned above" do
        pinned = THUMBNAIL_REVISIONS.keys.filter_map { |name| Registry.for_filename(name) }.uniq
        registered = Registry::RENDERERS.values.uniq

        assert_equal registered.map(&:name).sort, pinned.map(&:name).sort,
                     "a renderer is reachable through the Registry with no row in " \
                     "THUMBNAIL_REVISIONS (or vice versa). A new format must be pinned here, or " \
                     "forgetting to bump its thumbnail revision is green."
      end

      # THE SET IS NON-EMPTY, because both assertions above are satisfied by nothing at all.
      # §14e: a guard that scans a collection dies silently when the collection goes away — two
      # architecture guards in this repo went on "passing over nothing" for exactly that reason.
      test "the pinned set is not empty" do
        assert_operator THUMBNAIL_REVISIONS.size, :>, 5, "the table emptied out"
        assert_operator Registry::RENDERERS.values.uniq.size, :>, 5, "the Registry emptied out"
      end
    end
  end
end
