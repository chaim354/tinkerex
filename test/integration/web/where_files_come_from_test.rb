require "test_helper"
require "support/public_fixture"

module Web
  # WHERE FILES COME FROM, AND WHAT A Projects/ FOLDER BECOMES (F onboarding, 2026-10-13). A
  # brand-new library said "No files yet. Upload one." and nothing about the folder on the server,
  # the desktop app, or the sweep that files a project folder's loose files into type folders — the
  # app moved a maker's files first and explained itself afterwards. The copy now comes from ONE
  # partial, shared/_where_files_come_from, which branches on the port's capabilities, so Recent,
  # the Library and Projects say the same true thing on every backend.
  #
  # EVERY TEST HERE PINS SHARE (`use_fresh_share_library!`, PublicFixture's rule), so the ambient
  # backend leg never decides which arm renders. The other two backends' arms are reached by
  # stubbing CAPABILITIES — the key the partial reads — with each adapter's OWN answer rather than a
  # copy of it: chunk_remote's constant and S3's method, so a capability change in either adapter
  # reaches these tests with no edit here. Without the stub the desktop-app and bucket arms would
  # never render once in this class, on any leg (§14e: a guard whose precondition is never
  # established is not a guard).
  class WhereFilesComeFromTest < ActionDispatch::IntegrationTest
    include PublicFixture

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

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
    end

    # S3's answer without S3's configuration: `FileLayer::S3#capabilities` reads no instance state,
    # so an allocated instance answers exactly what a configured one does.
    def s3_capabilities = FileLayer::S3.allocate.capabilities

    def with_capabilities(caps, &)
      replacing(FileLayer.current, :capabilities, -> { caps }, &)
    end

    def text_of(selector) = css_select(selector).map(&:text).join(" ").squish

    # --- Recent ----------------------------------------------------------------------------------

    test "Recent's getting-started panel names every way a file arrives on this library" do
      get root_path
      assert_response :success
      assert_select ".getting-started", 1
      # No "Recently changed" panel with nothing in it beside the one that says how to fill it.
      assert_select ".home-files", 0

      sources = text_of(".getting-started .file-sources")
      assert_match(/Upload, in the top bar/, sources)
      assert_match(/library folder on the server.*within 15 minutes.*Rescan library/, sources)
      refute_match(/desktop app|storage bucket/, sources, "a share library has neither")

      assert_match(/directly inside Projects\/.*becomes a project within 15 minutes/,
                   text_of(".getting-started .projects-intake"))
      assert_match(/filed into type folders/, text_of(".getting-started .projects-intake"))
      assert_select ".getting-started .projects-intake a[href=?]", settings_filing_rules_path
      assert_select ".getting-started a[href=?]", tools_path
      # Task 3 of the same plan adds the route; the literal keeps this green on its own.
      assert_select ".getting-started a[href=?]", "/help"
    end

    test "the panel is gone once a file exists" do
      dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      make_file!(@user, "part.stl", dir)
      get root_path
      assert_select ".getting-started", 0
      assert_select ".home-files .recent-grid .grid-card", 1
    end

    test "a bucket-backed library names the bucket, not a folder" do
      with_capabilities(s3_capabilities) { get root_path }
      assert_response :success
      sources = text_of(".getting-started .file-sources")
      assert_match(/storage bucket.*within 15 minutes.*Rescan library/, sources)
      refute_match(/library folder|desktop app/, sources)
    end

    test "a synced library names the desktop app and promises no scan" do
      with_capabilities(FileLayer::ChunkRemote::CAPABILITIES) { get root_path }
      assert_response :success
      sources = text_of(".getting-started .file-sources")
      assert_match(/Upload, in the top bar/, sources)
      assert_match(/desktop app/, sources)
      # Nothing polls a chunk_remote library and there is no Rescan door (require_scannable!).
      refute_match(/15 minutes|Rescan library|library folder|storage bucket/, sources)
      # Discovery runs every 15 minutes on this backend too (config/recurring.yml).
      assert_match(/becomes a project within 15 minutes/, text_of(".getting-started .projects-intake"))
    end

    # --- The Library -----------------------------------------------------------------------------

    test "the Library's new-library state says the same" do
      get files_path
      assert_response :success
      assert_select ".library-main .empty", 1
      empty = text_of(".library-main .empty")
      assert_match(/Your library is empty/, empty)
      assert_match(/Upload, in the top bar/, empty)
      assert_match(/library folder on the server.*within 15 minutes/, empty)
      assert_match(/becomes a project/, empty)
      assert_select ".library-main .empty .projects-intake a[href=?]", settings_filing_rules_path
    end

    test "an empty folder says so, and how to fill it" do
      dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      get files_path(folder: dir.node_id)
      assert_select ".library-main .empty", 1
      assert_match(/This folder is empty/, text_of(".library-main .empty"))
      assert_select ".library-main .empty .file-sources", 1
    end

    # THE OTHER TWO EMPTINESSES ARE NOT A NEW LIBRARY. Said to someone who searched or filtered,
    # "here is how files arrive" reads as "your library is empty" — the lie files/index's own
    # comment names.
    test "a search or a type filter that finds nothing keeps its own sentence" do
      get files_path(q: "zzz")
      assert_select ".empty", text: /No files match/
      assert_select ".file-sources", 0
      get files_path(ext: "stl")
      assert_select ".empty", text: /No files match/
      assert_select ".file-sources", 0
    end

    test "a project's folder says what the sweep will do to it, before it does it" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = make_project_folder!(@user, project)

      get files_path(folder: folder.node_id)
      assert_select ".project-folder-note", 1
      note = text_of(".project-folder-note")
      assert_match(/filed into type folders within 15 minutes/, note)
      assert_match(/README/, note)
      assert_select ".project-folder-note a[href=?]", project_path(project), text: "Desk Lamp"
      assert_select ".project-folder-note a[href=?]", settings_filing_rules_path

      # Off, the sweep files nothing (ProjectIntake#call), and the line must not say it will.
      project.update!(autofile: false)
      get files_path(folder: folder.node_id)
      note = text_of(".project-folder-note")
      assert_match(/Automatic filing is off/, note)
      refute_match(/filed into type folders/, note)
    end

    test "only the project folder itself carries the note" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = make_project_folder!(@user, project)
      sub = make_dir!(@user, "models", folder)
      plain = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")

      get files_path(folder: sub.node_id)
      assert_select ".project-folder-note", 0
      get files_path(folder: plain.node_id)
      assert_select ".project-folder-note", 0
    end

    # --- Projects --------------------------------------------------------------------------------

    test "the Projects page says what a Projects folder becomes before anything is moved" do
      get projects_path
      assert_response :success
      assert_select ".empty", 1
      empty = text_of(".empty")
      assert_match(/No projects yet/, empty)
      assert_match(/directly inside Projects\/.*becomes a project within 15 minutes/, empty)
      assert_match(/filed into type folders/, empty)
      assert_select ".empty .projects-intake a[href=?]", settings_filing_rules_path
      assert_select ".empty a[href=?]", new_project_path
      # The ways FILES arrive are the Library's question, not this page's.
      assert_select ".empty .file-sources", 0
    end

    test "a filtered or an all-archived Projects page does not claim there are none" do
      get projects_path(archived: 1)
      assert_select ".empty", text: "No archived projects."

      @user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".empty", text: /Every project is archived/
      refute_match(/No projects yet/, response.body)
      assert_select ".empty .projects-intake", 1

      # A filter that matched nothing, in either view: there ARE projects, just none of this kind.
      [ projects_path(kind: "laser"), projects_path(archived: 1, kind: "laser") ].each do |path|
        get path
        assert_select ".empty", text: "No projects match."
        assert_select ".projects-intake", 0
      end
    end
  end
end
