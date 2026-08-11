require "test_helper"

module Library
  # The DOOR-side half of the reserved-name rule, pinned on its own because it is the half with no
  # adapter behind it. FileLayer::Share#observable! and FileLayer::S3#observable! answer the same
  # question about a REL PATH inside a store they own; this answers it about a LEAF NAME a web door
  # is about to mint, before any backend is asked — which is the only place chunk can be asked at
  # all, since chunk has no port write path and therefore no `observable!`.
  class ReservedNamesTest < ActiveSupport::TestCase
    test "OS clutter is reserved, via the same predicate the observers skip on" do
      %w[.DS_Store ._bracket.stl __MACOSX .Spotlight-V100 .Trashes .fseventsd
         .TemporaryItems .DocumentRevisions-V100 .apdisk].each do |name|
        assert ReservedNames.reserved?(name), "#{name.inspect} should be reserved"
      end
    end

    # DELEGATION, NOT A SECOND LIST — asserted by mutating the source of truth rather than by
    # reading the implementation. A copy of the names here would keep passing after OsClutter grew
    # an entry, which is the exact drift Library::OsClutter's header exists to prevent.
    #
    # Hand-rolled rather than Object#stub: minitest 6 dropped minitest/mock, so `stub` does not
    # exist in this suite (see test_helper.rb:147). The ensure-restore is load-bearing — a leak
    # would turn every later OS-clutter assertion in this worker green for the wrong reason.
    test "the OS-clutter arm delegates to OsClutter rather than holding its own copy" do
      original = OsClutter.method(:clutter_segment?)
      OsClutter.define_singleton_method(:clutter_segment?) { |_segment| false }
      assert_not ReservedNames.reserved?(".DS_Store"),
                 "reserved? must ask OsClutter, not a private copy of its list"
    ensure
      OsClutter.define_singleton_method(:clutter_segment?, original)
    end

    test "the trash root is reserved" do
      assert ReservedNames.reserved?(Library::Scanner::TRASH_PREFIX)
      assert ReservedNames.reserved?(".trash")
    end

    # EXACT MATCH, NOT A PREFIX — the Scanner skips `.trash` as a whole segment, so a file whose
    # name merely starts with those characters is an ordinary file and must stay writable.
    test "a name that merely starts with the trash prefix is not reserved" do
      assert_not ReservedNames.reserved?(".trashcan.svg")
      assert_not ReservedNames.reserved?(".trash-plan.svg")
    end

    # THE ARM THAT IS STRICTER THAN ONE ADAPTER, ON PURPOSE. FileLayer::S3#observable! omits
    # TEMP_PREFIX because that adapter writes no temp keys, so a `.maker-tmp-x` OBJECT is genuinely
    # observable there. This predicate still refuses it, because a door cannot know which backend
    # is deployed: accepting a name the deployed adapter would refuse is the same divergence with
    # the sign flipped (share 422, s3 302). See the module header for the full argument.
    test "the temp prefix is reserved, at the door, on every backend" do
      assert ReservedNames.reserved?("#{Library::Scanner::TEMP_PREFIX}abc123")
      assert ReservedNames.reserved?(".maker-tmp-abc123")
    end

    test "ordinary names are not reserved" do
      %w[grid.svg .gitignore trash.txt DS_Store MACOSX
         maker-tmp-x .hidden Thumbs.db desktop.ini].each do |name|
        assert_not ReservedNames.reserved?(name), "#{name.inspect} should be writable"
      end
    end

    # Callers hand this a LEAF (they run Maker::MoveNode.valid_leaf_name? first, which is what makes
    # "no separator" true). It is still asked about non-strings because a door's input is JSON a
    # bundle sent, and a nil there must be a plain false rather than a NoMethodError 500.
    test "a non-string is not reserved rather than an exception" do
      assert_not ReservedNames.reserved?(nil)
      assert_not ReservedNames.reserved?([ ".DS_Store" ])
      assert_not ReservedNames.reserved?(42)
    end
  end
end
