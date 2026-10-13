require "test_helper"
require "support/public_fixture"

module Web
  # AN UNREACHABLE LIBRARY IS SAID ON THE PAGE, NOT HIDDEN (F onboarding, 2026-10-13).
  #
  # `Maker::Previews::ThumbnailMap.for` rescues the port's FetchError to an empty map, so the page
  # goes on rendering from the catalog with its thumbnails degraded, and until this it said nothing
  # about why. `Current.library_unreachable` is raised exactly at that rescue, and the layout renders
  # one banner when it is up. The banner NEVER PROBES THE STORE: a page that did not touch the port
  # says nothing, so no request pays a round trip for the sentence.
  #
  # RECENT (`/`) IS THE PAGE, NOT THE FILES PAGE, AND THAT IS THIS SUITE'S PRECONDITION RATHER THAN A
  # PREFERENCE. `FilesController#index` stats its own page and hands the answer to
  # `ThumbnailMap.from_info`, so a FetchError there reaches the controller's `rescue_from` (a
  # redirect), never this rescue. Recent calls `ThumbnailMap.for` with its recent files, so the one
  # live file seeded below is what makes it ask the port at all.
  #
  # PINNED TO SHARE ON EVERY LEG (PublicFixture's rule), so the cause the banner names is asserted
  # through each backend's own CAPABILITIES, never through a backend name.
  class LibraryUnreachableTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as, make_file!

    # The house stub helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
    # Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # The store, unreachable for the block. `stat_all` is the one port call Recent's ThumbnailMap
    # makes; everything else on the real adapter (capabilities, the top bar's upload flow) answers.
    def unreachable(&)
      replacing(FileLayer.current, :stat_all, ->(*) { raise FileLayer::FetchError, "share unmounted" }, &)
    end

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      make_file!(@user, "part.stl", dir)
    end

    test "a page whose thumbnails could not be fetched carries the banner" do
      unreachable { get root_path }
      assert_response :success
      assert_select ".library-unreachable", 1
      assert_select ".library-unreachable", text: /can't be reached/i
      # THE POPULATED ARM IS THE ONE template_hygiene_test.rb's sweep cannot render (no page there
      # fails the port), so its output is checked for a leaked ERB delimiter here instead.
      assert_not_includes response.body, "<%"
      assert_not_includes response.body, "%>"
    end

    test "a page that reached the library carries no banner" do
      get root_path
      assert_response :success
      assert_select ".library-unreachable", 0
    end

    test "the flag does not leak into the next request" do
      unreachable { get root_path }
      # ESTABLISHED FIRST, or the assertion below passes over a flag that was never raised.
      assert_select ".library-unreachable", 1
      get root_path
      assert_response :success
      assert_select ".library-unreachable", 0
    end

    # PAIRS, NOT A HASH KEYED ON THE CAPABILITIES: two backends that came to answer alike would
    # collapse into one key and drop a case without anything going red.
    test "the banner names the likely cause, read off the backend's own capabilities" do
      s3 = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                             secret_access_key: "sk", client: Object.new)
      [
        [ FileLayer.current.capabilities, "the library folder may be unmounted" ],
        [ s3.capabilities, "the storage bucket isn't answering" ],
        [ FileLayer::ChunkRemote::CAPABILITIES, "the sync server may be down" ]
      ].each do |caps, cause|
        replacing(FileLayer.current, :capabilities, -> { caps }) { unreachable { get root_path } }
        assert_response :success
        assert_select ".library-unreachable", { count: 1, text: /#{Regexp.escape(cause)}/ },
                      "#{caps.inspect} should name #{cause.inspect}"
      end
    end
  end
end
