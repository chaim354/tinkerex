require "test_helper"
require "support/public_fixture"

module Web
  # AN UNREACHABLE LIBRARY IS SAID ON THE PAGE, NOT HIDDEN (F onboarding, 2026-10-13).
  #
  # A reader that degrades a FetchError into quieter output during a render (Maker::Readme,
  # Maker::RepoCard, Maker::GerberSets, Maker::ThreeMfManifest) raises Current.library_unreachable,
  # and the layout renders one banner when it is up. The banner NEVER PROBES THE STORE: a page that
  # did not touch the port says nothing, so no request pays a round trip for the sentence.
  #
  # THE REAL PATH IS THE PROJECT PAGE'S README, read through the port by Maker::Readme. Its `read`
  # is replaced for one request: a FetchError keeps the page up with "README unavailable." AND the
  # banner; a NotFound gives the same note and NO banner, because a file that is gone is not an
  # outage. That pair is what pins the split rescue.
  #
  # PINNED TO SHARE ON EVERY LEG (PublicFixture's rule), so the README has real bytes behind it and
  # the cause the banner names is asserted through each backend's own CAPABILITIES, never a name.
  class LibraryUnreachableTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as, make_project_folder!, make_file!

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

    # Every port `read` in the block raises `error`. The README is the one read this page makes.
    def reads_raise(error, &)
      replacing(FileLayer.current, :read, ->(*) { raise error, "share unmounted" }, &)
    end

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      @project = @user.maker_projects.create!(name: "Tray")
      folder = make_project_folder!(@user, @project)
      make_file!(@user, "README.md", folder, body: "# Tray\n\nWalnut.\n")
    end

    test "a page that reached its README carries no banner" do
      get project_path(@project)
      assert_response :success
      # THE README REALLY IS READ ON THIS PAGE, or the stubbed reads below would prove nothing.
      assert_select ".readme-card .markdown h1", text: "Tray"
      assert_select ".library-unreachable", 0
    end

    test "a README the store cannot deliver leaves the page up, says so, and carries the banner" do
      reads_raise(FileLayer::FetchError) { get project_path(@project) }
      assert_response :success
      assert_select ".readme-card .markdown", 0
      assert_select ".readme-card .readme-note", text: "README unavailable."
      assert_select ".library-unreachable", 1
      assert_select ".library-unreachable", text: /can't be reached/i
      # THE POPULATED ARM IS THE ONE template_hygiene_test.rb's sweep cannot render (no page there
      # fails the port), so its output is checked for a leaked ERB delimiter here instead.
      assert_not_includes response.body, "<%"
      assert_not_includes response.body, "%>"
    end

    test "a README that is gone gets the same note and no banner, because nothing is down" do
      reads_raise(FileLayer::NotFound) { get project_path(@project) }
      assert_response :success
      assert_select ".readme-card .readme-note", text: "README unavailable."
      assert_select ".library-unreachable", 0
    end

    test "the flag does not leak into the next request" do
      reads_raise(FileLayer::FetchError) { get project_path(@project) }
      # ESTABLISHED FIRST, or the assertion below passes over a flag that was never raised.
      assert_select ".library-unreachable", 1
      get project_path(@project)
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
        replacing(FileLayer.current, :capabilities, -> { caps }) do
          reads_raise(FileLayer::FetchError) { get project_path(@project) }
        end
        assert_response :success
        assert_select ".library-unreachable", { count: 1, text: /#{Regexp.escape(cause)}/ },
                      "#{caps.inspect} should name #{cause.inspect}"
      end
    end

    # PLUMBING, THROUGH A PATH THAT CANNOT FIRE IN PRODUCTION TODAY. Maker::Previews::ThumbnailMap.for
    # raises the flag from its FetchError rescue too, but `stat_all` is catalog-only on all three
    # adapters, so only a stubbed port reaches that rescue. This keeps the setter wired for an
    # adapter whose `stat_all` does read the store. Recent (/) asks ThumbnailMap.for about its
    # recent files, and the README seeded above is one.
    test "plumbing: the thumbnail map's rescue raises the flag too, through a stubbed stat_all" do
      replacing(FileLayer.current, :stat_all, ->(*) { raise FileLayer::FetchError, "share unmounted" }) do
        get root_path
      end
      assert_response :success
      assert_select ".library-unreachable", 1
    end
  end
end
