require "test_helper"

module Maker
  # STAGE 3, S3-4: the README reader extracted out of Maker::RepoCard so the public project page can
  # render the PROJECT FOLDER's own README with the same rules and a different link target.
  # project_repo_card_test.rb is the behavioural pin for the move; this suite pins the unit's own
  # two parameters — which rows are searched, and what a resolved relative href turns into.
  class ReadmeTest < ActiveSupport::TestCase
    # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY NODE IS CREATED. This suite reads REAL
    # BYTES through the port, so it cannot ride the ambient backend: on s3 and chunk_remote a
    # create_node! fixture has no object behind it at all. create_node! reads `@root` (not
    # `@library`) to decide whether to materialise a file, so that is the ivar this suite assigns.
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "readme-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder!(@user, @project)
    end

    # The house mutation-check helper (project_repo_card_test.rb and project_folder_listing_test.rb
    # carry the same body; there is no shared copy in test_helper.rb, so each suite that needs it
    # defines its own). Replaces ONE INSTANCE's singleton method — here FileLayer.current's `read`,
    # which is memoised for the process, so every caller in the block sees the replacement.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # project_folder_rows! is deliberately PORT-FREE — two dir ROWS, nothing on disk — which is what
    # lets a folder fixture run on any backend. This suite goes on to read a README's bytes, so the
    # rows additionally need a storage_path and the directory needs to exist. Setting them here
    # rather than calling Project#ensure_library_folder! keeps the fixture off the port (that call
    # is a real mkdir, red on s3/chunk_remote) while making create_node! derive
    # `Projects/<slug>/…` for everything below.
    def project_folder!(user, project)
      folder = project_folder_rows!(user, project)
      user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
      folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
      @root.join(folder.storage_path).mkpath
      folder
    end

    def dir!(name, parent)
      create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir",
                   parent_node_id: parent.node_id, mtime: 1, size: 0)
    end

    # `size:` IS THE CATALOG'S SIZE AND THE READ_LIMIT GATE READS IT, so it is passed separately
    # from the bytes: a fixture can claim a 2 MB README while holding two lines, which is exactly
    # how the gate is proven without writing 2 MB. create_node! writes the letter "x" through the
    # port's own path arithmetic; the real text is written over it at the storage_path the catalog
    # ends up holding, so the two can never disagree about where the file is.
    def file!(name, parent, body: "x", size: nil)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent.node_id, mtime: 1, size: size || body.bytesize)
      @root.join(node.storage_path).binwrite(body)
      node
    end

    def listing = Maker::ProjectFolderListing.new(@user, @project)

    # The caller's half of the contract: a node_id in, a URL out. The public page's URLs are not
    # this class's business, so the test's lambda is deliberately not a route helper.
    LINK = ->(id) { "/u/ada/desk-lamp/files/#{id}" }

    def readme_for(rows: nil, base_path: nil, list: nil, link: LINK)
      list ||= listing
      Maker::Readme.for(user: @user, rows: rows || list.loose,
                        base_path: base_path || list.path, listing: list, link:)
    end

    test "the folder's own README.md is found among the loose rows and rendered" do
      file!("README.md", @folder, body: "# Desk Lamp\n\n- a lamp\n")

      readme = readme_for

      assert_match %r{<h1>Desk Lamp</h1>}, readme.html
      assert_match %r{<li>a lamp</li>}, readme.html
      assert_nil readme.note
    end

    test "no README at all is nil — not a Readme carrying a note" do
      file!("notes.txt", @folder)

      assert_nil readme_for
    end

    # The order of NAMES is the preference order, and the wider list is the point of the extraction:
    # a project folder's README is written by a human in Finder, not by a `git init` template.
    test "README.txt is found when there is no README.md, and README.md wins when both exist" do
      file!("README.txt", @folder, body: "# From the txt\n")

      assert_match %r{From the txt}, readme_for.html

      file!("README.md", @folder, body: "# From the md\n")

      assert_match %r{From the md}, readme_for.html
    end

    test "a relative link resolves through the listing's path index and the caller's link lambda" do
      models = dir!("models", @folder)
      base = file!("base.stl", models)
      file!("README.md", @folder, body: "See [the base plate](models/base.stl) for the enclosure.\n")

      readme = readme_for

      assert_match %r{<a href="/u/ada/desk-lamp/files/#{base.node_id}">the base plate</a>}, readme.html
    end

    test "a relative link to a path the folder does not hold becomes plain text" do
      file!("README.md", @folder, body: "See [the base plate](models/base.stl).\n")

      readme = readme_for

      assert_no_match %r{<a[\s>]}, readme.html
      assert_match %r{the base plate}, readme.html
    end

    # THE MUTATION-BEARING CASE. `base_path` is the README's OWN directory as a full library path,
    # and a nested one is what proves the join: a README inside Projects/desk-lamp/firmware naming
    # `docs/pinout.md` must ask the index for Projects/desk-lamp/firmware/docs/pinout.md. Dropping
    # the join (`index[href]`) still resolves nothing here, and dropping only the BASE would ask for
    # `docs/pinout.md`, which no listing key ever equals.
    test "a nested README resolves against its own directory, not against the folder root" do
      firmware = dir!("firmware", @folder)
      docs = dir!("docs", firmware)
      pinout = file!("pinout.md", docs)
      file!("README.md", firmware, body: "The [pinout](docs/pinout.md) is current.\n")
      # A second file with the same relative path from the FOLDER root, so a base-less lookup has
      # something plausible to find and the assertion below still names the right node.
      root_docs = dir!("docs", @folder)
      other = file!("pinout.md", root_docs)

      list = listing
      dir = list.tree.find { |d| d.name == "firmware" }
      readme = readme_for(rows: dir.files, base_path: dir.path, list:)

      assert_equal "Projects/desk-lamp/firmware", dir.path
      assert_match %r{<a href="/u/ada/desk-lamp/files/#{pinout.node_id}">pinout</a>}, readme.html
      assert_no_match %r{#{other.node_id}}, readme.html
    end

    # `path_index` KEYS ARE FULL LIBRARY PATHS ("Projects/desk-lamp/models/base.stl"), so the base
    # must be the README's real directory — a bare "" resolves NOTHING and every relative link
    # quietly becomes prose. Pinned because the failure is silent: the page renders, the links are
    # just gone. The Pathname arithmetic itself is fine (`Pathname.new("").join("models/x.stl")` is
    # "models/x.stl"); it is the KEY SPACE that disagrees.
    test "a base_path that is not the README's own directory resolves nothing" do
      models = dir!("models", @folder)
      file!("base.stl", models)
      file!("README.md", @folder, body: "See [the base plate](models/base.stl).\n")

      assert_equal "models/x.stl", Pathname.new("").join("models/x.stl").cleanpath.to_s
      assert_equal "Projects/desk-lamp", listing.path

      readme = readme_for(base_path: "")

      assert_no_match %r{<a[\s>]}, readme.html
      assert_match %r{the base plate}, readme.html
    end

    # THE CATALOG'S SIZE GATES THE READ. The port's `read` has no byte limit, so the render cap
    # alone streamed a README of any size before cutting it (review, S3-2) — on chunk_remote a full
    # WAN stream. The port's `read` is replaced with a raise: the gate must hold before it.
    test "a README the catalog says is huge is never read; the note says so" do
      file!("README.md", @folder, body: "# Small on disk\n", size: 2.megabytes)

      readme = replacing(FileLayer.current, :read, ->(*) { raise "the port must not be read past READ_LIMIT" }) do
        readme_for
      end

      assert_nil readme.html
      assert_match %r{too large to show}, readme.note
      assert_match %r{2048 KB}, readme.note
    end

    test "a README just under the read limit is still read" do
      file!("README.md", @folder, body: "# Read me\n", size: Maker::Readme::READ_LIMIT)

      assert_match %r{<h1>Read me</h1>}, readme_for.html
    end

    test "a README past the render cap is truncated with a note, and what precedes the cut renders" do
      file!("README.md", @folder, body: "# Desk Lamp\n\n" + ("word " * 20_000))

      readme = readme_for

      assert_match %r{<h1>Desk Lamp</h1>}, readme.html
      assert_match %r{Showing the first 64 KB}, readme.note
    end

    # AN UNMOUNTED SHARE MUST NOT TAKE THE PAGE DOWN — FetchError (retryable) and NotFound
    # (terminal) both degrade to the same note here, because a reader has nothing different to do
    # about either one.
    test "a port that cannot deliver the bytes degrades to a note, never an exception" do
      file!("README.md", @folder, body: "# Desk Lamp\n")

      %w[FetchError NotFound].each do |error|
        readme = replacing(FileLayer.current, :read, ->(*) { raise FileLayer.const_get(error), "share not mounted" }) do
          readme_for
        end

        assert_nil readme.html, error
        assert_equal "README unavailable.", readme.note, error
      end
    end

    # The repo card is now this class's first caller, not a second copy of it — its three constants
    # are the SAME objects, so they cannot drift. `assert_same` on ALL THREE: `assert_equal` stays
    # green if someone re-types `README_CAP = 64 * 1024` in repo_card.rb, which is exactly the
    # drift this test exists to refuse (S3-4's review). Small Integers are immediates, so
    # `(64 * 1024).equal?(65536)` holds and the assertion is meaningful rather than flaky.
    test "Maker::RepoCard's README constants are aliases of this class's" do
      assert_same Maker::Readme::NAMES, Maker::RepoCard::README_NAMES
      assert_same Maker::Readme::CAP, Maker::RepoCard::README_CAP
      assert_same Maker::Readme::READ_LIMIT, Maker::RepoCard::README_READ_LIMIT
    end
  end
end
