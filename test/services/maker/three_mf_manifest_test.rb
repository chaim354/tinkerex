require "test_helper"
require "support/mesh_fixture"
require "support/three_mf_fixture"

module Maker
  # WHAT THE SERVER LEARNS FROM A 3MF THAT THE VIEWER'S IMPORTER CANNOT — the slicer's per-object
  # filament colour and the model's declared unit. Tested as a unit for `GerberArchiveTest`'s
  # reason: it is a pure function of the package's bytes plus one port read, and driving a web page
  # to ask it would be slower and no more true. The data attributes are files_flow_test.rb's and
  # models_flow_test.rb's subject; the browser half — three's own 3MFLoader importing these very
  # fixtures and the colours landing on the right meshes — is test/system/o3dv_test.rb's.
  #
  # SHARE IS PINNED BEFORE ANY NODE IS CREATED, exactly as in GerberArchiveTest: `for` really opens
  # the package through the port, so a fixture with no bytes behind it would answer nil on every leg
  # and every assertion here would pass for the wrong reason.
  #
  # THE CACHE IS THE NULL STORE IN TEST (config/environments/test.rb), so every `for` below really
  # reads. The one test that is ABOUT the cache swaps a MemoryStore in and restores it.
  class ThreeMfManifestTest < ActiveSupport::TestCase
    include ThreeMfFixture

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "threemf-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    # Every port read this block performs, by node_id — the singleton-method technique
    # gerber_archive_test.rb uses, because this suite has no Object#stub (Minitest 6). `raising:`
    # makes each of those reads fail with the port's own error instead, as that file's does.
    def counting_reads(raising: nil)
      adapter = FileLayer.current
      original = adapter.method(:read)
      reads = []
      adapter.define_singleton_method(:read) do |user, **kw|
        reads << kw[:node_id]
        raise raising, "the store did not answer" if raising

        original.call(user, **kw)
      end
      begin
        yield reads
      ensure
        adapter.singleton_class.remove_method(:read)
      end
    end

    # --- Bambu Studio ------------------------------------------------------------

    # THE HEADLINE CASE, AND THE ORDER IS THE ASSERTION. The fixture's build items name container 4
    # (extruder 1) then container 2 (extruder 2), while `<resources>` lists 2 before 4 — so a walk
    # that read the resource list would answer the palette REVERSED, which is a wrong colour on the
    # wrong part rather than no colour. Filaments are 1-based.
    test "a Bambu project answers one filament colour per object, in BUILD order" do
      node = write_threemf!(body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                                            filaments: %w[#161616 #F98C36 #FFFFFF]))

      manifest = ThreeMfManifest.for(user: @user, node:)

      assert_equal [ "#161616", "#F98C36" ], manifest.colors
      assert_in_delta 1.0, manifest.unit_factor
    end

    # A PART'S OWN EXTRUDER WINS. This is how a real project prints one object's lettering in a
    # second filament (`Large Wheel-Pair-U1.3mf`: object extruder 2, part "Digits" extruder 1), and
    # it is the reason the leaf carries TWO ids — the container's, which the config keys on, and the
    # mesh object's, which the `<part id>` names.
    test "a part-level extruder overrides the object's" do
      node = write_threemf!(body: bambu_3mf(objects: [ { extruder: 2, part_extruder: 3 } ],
                                            filaments: %w[#161616 #F98C36 #FFFFFF]))

      assert_equal [ "#FFFFFF" ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # AN EXTRUDER WITH NO FILAMENT BEHIND IT IS nil, NOT A GUESS — and `0` is the trap: Bambu writes
    # it on a part that inherits, and `list[0 - 1]` in Ruby is the LAST filament, a plausible and
    # wrong colour. Both directions in one test because both are the same one-line guard.
    test "an extruder past the filament list, or zero, answers no colour" do
      %i[past zero].zip([ 9, 0 ]).each do |why, extruder|
        node = write_threemf!(name: "e#{extruder}.3mf",
                              body: bambu_3mf(objects: [ { extruder: } ], filaments: %w[#161616 #F98C36]))

        assert_equal [ nil ], ThreeMfManifest.for(user: @user, node:).colors, why
      end
    end

    # BAMBU'S OWN PALETTE CARRIES AN ALPHA (`#FFFFFFFF` in `Large Wheel-Pair-U1.3mf`), and an
    # eight-digit hex is not the colour the maker chose — three.js would read it as one it does
    # understand. Normalised to six upper-case digits; anything that is not a hex colour is dropped.
    test "a filament colour is normalised to #RRGGBB, alpha and case included" do
      node = write_threemf!(body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 }, { extruder: 3 } ],
                                            filaments: [ "#ffffffff", "00ff00", "not a colour" ]))

      assert_equal [ "#FFFFFF", "#00FF00", nil ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # NO PALETTE AT ALL IS STILL A WELL-FORMED ANSWER — one nil per mesh, so the count the browser
    # checks still matches and the engine's own materials stand.
    test "a Bambu project with no filament palette answers a nil per mesh" do
      node = write_threemf!(body: bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ], filaments: []))

      assert_equal [ nil, nil ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # --- PrusaSlicer -------------------------------------------------------------

    test "a PrusaSlicer object takes its extruder's colour, 1-based" do
      node = write_threemf!(body: prusa_3mf(objects: [ { extruder: 2 } ],
                                            extruder_colours: %w[#FF0000 #00FF00]))

      assert_equal [ "#00FF00" ], ThreeMfManifest.for(user: @user, node:).colors
    end

    test "a PrusaSlicer object with extruder 0 takes no colour" do
      node = write_threemf!(body: prusa_3mf(objects: [ { extruder: 0 } ],
                                            extruder_colours: %w[#FF0000 #00FF00]))

      assert_equal [ nil ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # `extruder_colour` IS THE PRINTER PROFILE'S AND IS BLANK IN MOST REAL PROJECTS; the colour the
    # maker actually loaded is `filament_colour`. Falling back per SLOT, not per file: slot 1 keeps
    # the profile's red while slot 2, blank there, takes the filament's blue.
    test "a blank extruder_colour slot falls back to that slot's filament_colour" do
      body = prusa_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                       extruder_colours: [ "#FF0000", "" ], filament_colours: %w[#111111 #0000FF])
      node = write_threemf!(body:)

      assert_equal [ "#FF0000", "#0000FF" ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # --- units -------------------------------------------------------------------

    # THE OTHER HALF OF THE MANIFEST, AND THE ONE A PLAIN CAD EXPORT NEEDS. three's loader ignores
    # `<model unit>` entirely, so an Onshape part in metres measures 1000x short in the viewer; the
    # factor here is what the dims line multiplies by. A file with no slicer metadata still answers
    # one nil per mesh, so nothing is painted over its own colorgroup.
    test "the declared unit becomes a millimetre factor, and a plain export names no colours" do
      { "millimeter" => 1.0, "meter" => 1000.0, "inch" => 25.4, "centimeter" => 10.0,
        "micron" => 0.001, "furlong" => 1.0 }.each do |unit, factor|
        node = write_threemf!(name: "#{unit}.3mf", body: plain_3mf(unit:))
        manifest = ThreeMfManifest.for(user: @user, node:)

        assert_in_delta factor, manifest.unit_factor, 1e-9, unit
        assert_equal [ nil ], manifest.colors, unit
      end
    end

    # AN ABSENT `unit` IS MILLIMETRES BY THE SPEC'S OWN DEFAULT, not "unknown".
    test "a model with no unit attribute is millimetres" do
      # Stripped from the DOCUMENT and repackaged — a `sub` on the zip's own bytes would corrupt it.
      node = write_threemf!(body: threemf_zip("3D/3dmodel.model" => plain_3mf_document.sub(' unit="millimeter"', "")))

      assert_in_delta 1.0, ThreeMfManifest.for(user: @user, node:).unit_factor
    end

    # --- not a 3MF we can read ---------------------------------------------------

    test "a file that is not a 3MF by name is never opened" do
      node = write_model!(name: "bracket.stl", body: binary_stl)

      counting_reads do |reads|
        assert_nil ThreeMfManifest.for(user: @user, node:)
        assert_empty reads, "a non-3MF was opened through the port"
      end
    end

    # EVERY MALFORMED SHAPE IS nil, NOT A 500 — the file page calls this on every 3MF it renders.
    test "garbage, a zip with no root model, and malformed XML are all nil" do
      {
        "not a zip at all" => "this is not an archive",
        "an empty file" => "",
        "a zip with no 3D/3dmodel.model" => threemf_zip("3D/somewhere-else.model" => plain_3mf_document),
        "malformed XML" => threemf_zip("3D/3dmodel.model" => "<model><resources><object id="),
        "a root element that is not <model>" => threemf_zip("3D/3dmodel.model" => "<notamodel/>")
      }.each do |why, body|
        node = write_threemf!(name: "#{SecureRandom.hex(3)}.3mf", body:)

        assert_nil ThreeMfManifest.for(user: @user, node:), why
      end
    end

    # A 3MF CUT SHORT IS THE ORDINARY MALFORMED SHAPE — an interrupted upload, a sync that stopped —
    # and rubyzip 3.6.0 does not answer it with Zip::Error: a real archive minus its last 1, 5 or 10
    # bytes raises NoMethodError or ArgumentError out of `open_buffer` (the review measured it), which
    # the method's own rescue never named, so every view of such a file was a 500. The archive is
    # now opened behind a rescue of exactly those classes and nothing else.
    # MUTATION: narrowing `open_zip`'s rescue back to `Zip::Error` reds this on the 1- and 5-byte cuts.
    test "a 3MF cut short by a few bytes is nil, not a raise" do
      whole = bambu_3mf
      [ 1, 5, 10 ].each do |cut|
        assert_nil ThreeMfManifest.manifest_from(whole[0...-cut]), "cut by #{cut} bytes"
      end
    end

    # A CYCLE IN THE COMPONENT GRAPH STOPS AT ITS FIRST REPEAT, NOT AT THE DEPTH LIMIT. Under a
    # depth bound alone an object naming itself three times is 3^16 walks — the review measured it
    # not finishing in 20 s, on a request thread, per page view. No conforming producer writes one,
    # which is exactly why it has to be a file this reader shrugs at rather than one it trusts.
    # MUTATION: removing BOTH bounds — the depth check and the budget decrement — reds this on the
    # timeout; either alone still stops it, which is the point of having two.
    test "a cyclic component graph terminates at once" do
      body = threemf_zip("3D/3dmodel.model" => <<~XML)
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1"><components>
              <component objectid="1"/><component objectid="1"/><component objectid="1"/>
            </components></object>
          </resources>
          <build><item objectid="1"/></build>
        </model>
      XML

      manifest = Timeout.timeout(5) { ThreeMfManifest.manifest_from(body) }

      assert_equal [], manifest.colors, "a cycle reaches no mesh"
    end

    # THE STEP BUDGET BOUNDS WORK THE CYCLE CHECK CANNOT SEE: a diamond-shaped graph repeats no
    # ancestor, so every branch is legal, and a root of 120 components each naming an object of 100
    # components is 12,000 leaves. Past MAX_STEPS the walk stops; the client's count check then
    # refuses the colours, which is the safe answer for a file shaped like nothing anyone printed.
    # MUTATION: removing the `budget` decrement reds this (12,000 leaves come back).
    test "a walk stops at MAX_STEPS instead of finishing a pathological graph" do
      fan = (1..100).map { |i| %(<component objectid="#{200 + i}"/>) }.join
      leaves = (1..100).map { |i| %(<object id="#{200 + i}"><mesh><vertices/><triangles/></mesh></object>) }.join
      root = (1..120).map { %(<component objectid="2"/>) }.join
      body = threemf_zip("3D/3dmodel.model" => <<~XML)
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            #{leaves}
            <object id="2"><components>#{fan}</components></object>
            <object id="1"><components>#{root}</components></object>
          </resources>
          <build><item objectid="1"/></build>
        </model>
      XML

      manifest = Timeout.timeout(10) { ThreeMfManifest.manifest_from(body) }

      assert_operator manifest.colors.size, :<, 12_000, "the budget must stop the walk short of every leaf"
      assert_operator manifest.colors.size, :<=, ThreeMfManifest::MAX_STEPS
    end

    # A COMPONENT NAMING A PART FILE THE ZIP DOES NOT HOLD EMITS NOTHING for that component, and the
    # manifest itself must not raise. That is all this pins: three's loader fails the WHOLE import
    # on a missing part (measured — see o3dv_test.rb's count-mismatch fixture), so the browser never
    # reaches applyColors for such a file and the shape of this list is moot there.
    test "a component pointing at a missing part file drops that mesh and keeps the rest" do
      body = bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ])
      body = threemf_without(body, "3D/Objects/object_101.model")
      node = write_threemf!(body:)

      assert_equal [ "#161616" ], ThreeMfManifest.for(user: @user, node:).colors
    end

    # AN UNMOUNTED SHARE MUST NOT 500 A FILE PAGE. The port's own two conditions are rescued;
    # driven here by deleting the bytes under a live row.
    test "a 3MF whose bytes are gone answers nil rather than raising" do
      node = write_threemf!
      @root.join(node.storage_path).delete

      assert_nil ThreeMfManifest.for(user: @user, node:)
    end

    # AN OUTAGE IS SAID; A MISSING FILE IS NOT (F onboarding). Both answer nil, but only the store
    # not answering raises the layout's banner flag (app/models/current.rb). The port's `read` is
    # replaced to raise each condition in turn; Current is reset between them, as a request would be.
    # The test cache is the null store, so each `for` really reaches `read`.
    test "an unreachable store answers nil and raises the banner flag; a missing package raises nothing" do
      node = write_threemf!

      answers = [ FileLayer::FetchError, FileLayer::NotFound ].to_h do |error|
        Current.reset
        adapter = FileLayer.current
        adapter.define_singleton_method(:read) { |_user, **_kw| raise error, "share not mounted" }
        begin
          assert_nil ThreeMfManifest.for(user: @user, node:), error.name
        ensure
          adapter.singleton_class.remove_method(:read)
        end
        [ error, Current.library_unreachable ]
      end

      assert answers[FileLayer::FetchError], "a FetchError did not raise the banner flag"
      assert_nil answers[FileLayer::NotFound], "a NotFound raised the banner flag; nothing is down"
    end

    # --- the bound ---------------------------------------------------------------

    # THE SIZE CHECK IS ON THE CATALOG'S OWN COLUMN, so an oversized package costs NO READ — and a
    # NULL size is refused rather than read, because `nil.to_i` is 0 and would pass the cap straight
    # into the port's own 256 MB bound. Asserted through the row rather than by writing 64 MB.
    test "a 3MF past READ_LIMIT, or of unknown size, is nil and is never read" do
      { "oversized" => ThreeMfManifest::READ_LIMIT + 1, "unknown size" => nil }.each do |why, size|
        node = write_threemf!(name: "#{SecureRandom.hex(3)}.3mf")
        node.update_column(:size, size)

        counting_reads do |reads|
          assert_nil ThreeMfManifest.for(user: @user, node:), why
          assert_empty reads, "a package of #{why} was opened through the port"
        end
      end
    end

    # --- the cache ---------------------------------------------------------------

    # ONE READ PER (node, content token). A file page renders the viewer and the user reloads it;
    # re-opening a 14 MB project each time is exactly the cost this cache exists to avoid — and nil
    # is cached too, so an STL-in-a-3MF-suit stays known-unreadable.
    #
    # MUTATION: drop the token from the cache key and the last assertion fails — the re-saved
    # project would answer from the stale entry.
    test "a manifest is read once per content token, nil included" do
      node = write_threemf!
      unreadable = write_threemf!(name: "broken.3mf", body: "not an archive")

      with_memory_cache do
        counting_reads do |reads|
          assert_equal [ "#161616", "#F98C36" ], ThreeMfManifest.for(user: @user, node:).colors
          assert_equal [ "#161616", "#F98C36" ], ThreeMfManifest.for(user: @user, node:).colors
          assert_equal [ node.node_id ], reads, "the second call re-opened the package"

          assert_nil ThreeMfManifest.for(user: @user, node: unreadable)
          assert_nil ThreeMfManifest.for(user: @user, node: unreadable)
          assert_equal [ node.node_id, unreadable.node_id ], reads,
                       "a nil manifest was not cached, so an unreadable file is re-read on every view"
        end

        # A RE-SAVE IS NEW CONTENT AND READS AGAIN — which also proves the cache answers about the
        # CURRENT bytes rather than the first ones it saw.
        recoloured = bambu_3mf(objects: [ { extruder: 3 }, { extruder: 3 } ])
        @root.join(node.storage_path).binwrite(recoloured)
        node.update_column(:content_hash, Digest::SHA256.hexdigest(recoloured))

        counting_reads do |reads|
          assert_equal [ "#FFFFFF", "#FFFFFF" ], ThreeMfManifest.for(user: @user, node: node.reload).colors
          assert_equal [ node.node_id ], reads, "a new content token did not re-read the package"
        end
      end
    end

    # A STORE THAT DID NOT ANSWER IS THIS VIEW'S nil, NEVER THE CONTENT'S — gerber_archive_test.rb's
    # pair of tests, for this reader's copy of the same wrapper. The rescue sat INSIDE the fetch, so
    # an outage cached "no manifest" for CACHE_TTL and an inch or metre export measured 25.4x or
    # 1000x short, in grey, until its bytes changed. The banner arm was already here; the cache was
    # not, and the null store this suite runs on could not see it.
    #
    # MUTATION: move the rescue back inside `Rails.cache.fetch` and the view after the outage answers
    # the cached nil without reading.
    test "an unreachable store is nil for that view, raises the banner, and is never cached" do
      node = write_threemf!
      seen = outage_then_recovery(node, FileLayer::FetchError)

      assert_nil seen[:during]
      assert seen[:banner], "an outage degraded the manifest to nil without raising the banner"
      assert_equal [ "#161616", "#F98C36" ], seen[:after]&.colors,
                   "the outage's nil was cached, so the project stayed grey after the store came back"
      assert_equal [ node.node_id, node.node_id ], seen[:reads], "the view after the outage did not read again"
    end

    test "a missing package is nil without the banner, and that nil is never cached either" do
      node = write_threemf!
      seen = outage_then_recovery(node, FileLayer::NotFound)

      assert_nil seen[:during]
      assert_nil seen[:banner], "a missing package raised the banner; nothing is down"
      assert_equal [ "#161616", "#F98C36" ], seen[:after]&.colors,
                   "a missing package's nil was cached, so the project stayed grey once it was back"
      assert_equal [ node.node_id, node.node_id ], seen[:reads], "the view after the miss did not read again"
    end

    # THE NAMESPACE MOVED WITH THE FIX, for gerber_archive_test.rb's reason: production already holds
    # nils that outages wrote under the old one. MUTATION: put it back and the planted nil is served.
    test "an answer cached under the namespace outages poisoned is never read" do
      node = write_threemf!

      with_memory_cache do
        Rails.cache.write([ "threemf-manifest", node.node_id, node.content_hash ], nil)
        assert_equal [ "#161616", "#F98C36" ], ThreeMfManifest.for(user: @user, node:)&.colors,
                     "a nil cached under the pre-fix namespace was served"
      end
    end

    private

    # ONE VIEW WHILE EVERY PORT READ RAISES `error`, THEN ONE AFTER THE STORE IS BACK, against a fresh
    # MemoryStore — gerber_archive_test.rb's helper of the same name, for this reader.
    def outage_then_recovery(node, error)
      with_memory_cache do
        Current.reset
        during, failed_reads = counting_reads(raising: error) { |r| [ ThreeMfManifest.for(user: @user, node:), r ] }
        banner = Current.library_unreachable
        Current.reset
        after, reads = counting_reads { |r| [ ThreeMfManifest.for(user: @user, node:), r ] }
        { during:, banner:, after:, reads: failed_reads + reads }
      end
    end

    # The plain fixture's root `<model>` document on its own, for the tests that need to damage it.
    def plain_3mf_document
      Zip::File.open_buffer(StringIO.new(plain_3mf.b)) do |zip|
        return zip.find_entry("3D/3dmodel.model").get_input_stream.read
      end
    end

    # The null store answers nothing, so a cache test needs a real one. Restored in `ensure`: a
    # leaked MemoryStore would make every later test in this worker cache-hit on stale rows.
    def with_memory_cache
      prior = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = prior
    end
  end
end
