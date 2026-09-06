require "test_helper"
require "rugged"

module Web
  # STAGE 3, S3-5: the releases panel and its two write doors (Projects::ReleasesController --
  # create / destroy), on the project page and on the public one.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY NODE EXISTS. The fixture writes real files and
  # a real git repository, so this suite cannot ride the ambient backend: on s3 and chunk_remote the
  # folder mkdir alone is a Forbidden / a library provisioning, and a working tree is only openable
  # where the library is a real filesystem (release_snapshot_test.rb and project_repo_card_test.rb
  # pin share for the same reason, and their headers record it).
  #
  # THE FOLDER IS ROWS PLUS A REAL DIRECTORY, NEVER `ensure_library_folder!` -- that is a real mkdir
  # through the port, which is the house rule test/support/public_fixture.rb states at length.
  class ProjectReleasesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "release-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
      @user.nodes.find_by!(node_id: @folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
      @folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, @project.slug))
      @root.join(@folder.storage_path).mkpath
    end

    # Real bytes under the project's own folder, indexed by ONE scan. A scan rather than
    # `create_node!` rows because the release compares CONTENT TOKENS and on share a token IS the
    # catalog's `content_hash` -- so a fixture that never hashed anything would compare nil to nil
    # and every "changed since" case would pass for the wrong reason.
    def seed!(files, repo: nil, tags: [], annotated: [])
      files.each do |rel, body|
        path = @root.join(@folder.storage_path, rel)
        path.dirname.mkpath
        path.write(body)
      end
      seed_repo!(repo, tags, annotated) if repo
      Library::ScanJob.new.perform(user_id: @user.id)
    end

    # A real git repository INSIDE the project's folder -- the picker only offers working trees the
    # folder holds, so one at the library root would leave `@release_repos` empty. Returns the
    # commit every tag points at.
    def seed_repo!(name, tags, annotated)
      dir = @root.join(@folder.storage_path, name).to_s
      FileUtils.mkdir_p(dir)
      repo = Rugged::Repository.init_at(dir)
      File.write(File.join(dir, "main.c"), "int main(void) { return 0; }\n")
      index = repo.index
      index.add(path: "main.c", oid: Rugged::Blob.from_workdir(repo, "main.c"), mode: 0o100644)
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      @commit_oid = Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "Bring up firmware",
                                          parents: [], update_ref: "HEAD", author: who, committer: who)
      tags.each { |t| repo.tags.create(t, @commit_oid) }
      annotated.each { |t| repo.tags.create(t, @commit_oid, message: "Release #{t}", tagger: who) }
      @commit_oid
    end

    def node!(name) = @user.nodes.present.find_by!(name:, kind: "file")

    def repo_node!(name) = @user.nodes.present.find_by!(name:, kind: "dir", parent_node_id: @folder.node_id)

    def create_release!(**attrs)
      post project_releases_path(@project), params: { release: { version: "v1.0.0" }.merge(attrs) }
    end

    def other_user!
      User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                   confirmed_at: Time.current)
    end

    # --- 1. the panel and the composer -----------------------------------------------------------

    test "the empty state, and the composer's rendered field names" do
      seed!({ "README.md" => "# Desk Lamp\n" })

      get project_path(@project)
      assert_response :success
      assert_select "section.panel.releases-panel h2", text: "Releases"
      assert_select ".releases-panel .mono.muted", text: "0 releases"
      assert_select ".releases-panel p.muted", text: "No releases yet."
      assert_select "details.release", count: 0

      # THE RENDERED FIELD NAMES, not a Ruby hash posted past the form (§14d): a `form_with` missing
      # `scope:` emits `[version]`-shaped params the controller's `require` rejects, and every test
      # below would stay green because they post `params: { release: {...} }` directly.
      assert_select "details.composer.release-add summary", text: "Create release"
      assert_select "form[action=?]", project_releases_path(@project)
      assert_select "input[name=?]", "release[version]"
      assert_select "lexxy-editor[name=?]", "release[notes]"
      # No repository in the folder, so the tag is free text and the page says why.
      assert_select "input[name=?]", "release[git_tag]"
      assert_select "select[name=?]", "release[git_tag]", count: 0
      assert_select ".release-add p.muted", text: /local folder/
    end

    # THE PICKER IS ONE SELECT CARRYING TWO FACTS -- "<repo node_id>:<tag>" -- because a <select>
    # cannot fill a second field without JS. Asserting the OPTION VALUE is what makes the encoding
    # a checked contract rather than a comment; the controller's half is pinned by the create case
    # two tests down, which posts exactly this string.
    test "with a repository in the folder the tag picker is one grouped select of encoded values" do
      seed!({ "README.md" => "# Desk Lamp\n" }, repo: "firmware", tags: %w[v0.1.0 v0.2.0])
      firmware = repo_node!("firmware")

      get project_path(@project)
      assert_response :success
      assert_select "select[name=?]", "release[git_tag]" do
        assert_select "option[value=?]", "", text: "No tag"
        assert_select "optgroup[label=?]", "firmware" do
          assert_select "option[value=?]", "#{firmware.node_id}:v0.1.0", text: "v0.1.0"
          assert_select "option[value=?]", "#{firmware.node_id}:v0.2.0", text: "v0.2.0"
        end
      end
      assert_select "input[name=?]", "release[git_tag]", count: 0
      assert_select ".release-add p.muted", text: /local folder/, count: 0
    end

    # --- 2. create ------------------------------------------------------------------------------

    test "create snapshots the folder, names the file count and lists the release" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })
      @project.boms.create!(user: @user, revision: 1)
      @project.boms.create!(user: @user, revision: 2)

      assert_difference "Maker::Release.count", 1 do
        create_release!(notes: "<div>First cut.</div>")
      end
      release = Maker::Release.order(:id).last
      assert_equal "v1.0.0", release.version
      assert_equal 2, release.files.count
      assert_equal 2, release.bom_revision
      assert_redirected_to project_path(@project)
      assert_equal "Released v1.0.0 with 2 files.", flash[:notice]

      follow_redirect!
      assert_select ".releases-panel .mono.muted", text: "1 release"
      assert_select "details.release[open]" do
        assert_select ".release-version", text: "v1.0.0"
        assert_select "time", count: 1
        assert_select "span.muted", text: "2 files"
        assert_select "span.muted", text: "BOM rev 2"
        assert_select ".release-notes", text: /First cut\./
        assert_select "table.release-files tbody tr", count: 2
        assert_select "td.col-path", text: "README.md"
        assert_select "td.col-path", text: "models/base.stl"
        assert_select "td.col-dl a", text: "Download", count: 2
      end
      assert_select ".badge.changed", count: 0
    end

    test "releases list newest first, and only the newest is open" do
      seed!({ "README.md" => "# Desk Lamp\n" })
      create_release!(version: "v0.1.0")
      travel 1.minute
      create_release!(version: "v0.2.0")

      get project_path(@project)
      versions = css_select("details.release .release-version").map { |el| el.text.strip }
      assert_equal %w[v0.2.0 v0.1.0], versions
      assert_equal 1, css_select("details.release[open]").size
      assert_equal "v0.2.0", css_select("details.release[open] .release-version").first.text.strip
    end

    # --- 3. tags --------------------------------------------------------------------------------

    test "a tag picked from the composer records the commit and renders its short oid" do
      seed!({ "README.md" => "# Desk Lamp\n" }, repo: "firmware", tags: %w[v0.1.0])
      firmware = repo_node!("firmware")

      # EXACTLY WHAT THE SELECT POSTS: the encoded option value, with no `release[repo_node_id]`
      # beside it. This is the controller's split under test, not a hand-separated pair.
      create_release!(git_tag: "#{firmware.node_id}:v0.1.0")
      release = Maker::Release.order(:id).last

      assert_equal "v0.1.0", release.git_tag
      assert_equal firmware.node_id, release.repo_node_id
      assert_equal @commit_oid.to_s, release.git_oid
      assert_equal "Released v1.0.0 with 2 files.", flash[:notice],
                   "a verified tag says nothing extra — the oid on the page is what shows it resolved"

      follow_redirect!
      assert_select "details.release summary .badge", text: "v0.1.0"
      assert_select "details.release summary .mono.muted", text: @commit_oid.to_s[0, 8]
      assert_select "summary .badge[title]", count: 0
    end

    test "a tag that does not exist in the picked repository refuses the release" do
      seed!({ "README.md" => "# Desk Lamp\n" }, repo: "firmware", tags: %w[v0.1.0])
      firmware = repo_node!("firmware")

      assert_no_difference "Maker::Release.count" do
        create_release!(git_tag: "#{firmware.node_id}:v9.9.9")
      end
      assert_redirected_to project_path(@project)
      assert_match(/Release not created/, flash[:alert])
      assert_match(/v9\.9\.9/, flash[:alert])
    end

    # A LIBRARY THAT IS NOT A LOCAL FOLDER HAS NO REPOSITORY THIS PROCESS CAN READ, so the tag is
    # stored as typed and the flash says so. The panel then shows the tag with no commit beside it,
    # which is the only visible difference from a verified one — hence the title.
    test "a typed tag with no repository is recorded, not verified, and says so" do
      seed!({ "README.md" => "# Desk Lamp\n" })

      create_release!(git_tag: "v1.0.0-rc1")
      release = Maker::Release.order(:id).last

      assert_equal "v1.0.0-rc1", release.git_tag
      assert_nil release.git_oid
      assert_nil release.repo_node_id
      assert_equal "Released v1.0.0 with 1 file (tag recorded, not verified).", flash[:notice]

      follow_redirect!
      assert_select "summary .badge[title=?]", "recorded, not verified", text: "v1.0.0-rc1"
    end

    # --- 4. refusals ----------------------------------------------------------------------------

    test "a duplicate version is refused with the model's own message" do
      seed!({ "README.md" => "# Desk Lamp\n" })
      create_release!

      assert_no_difference "Maker::Release.count" do
        create_release!
      end
      assert_redirected_to project_path(@project)
      assert_match(/Release not created/, flash[:alert])
      assert_match(/already a release of this project/, flash[:alert])
    end

    test "a blank version is refused" do
      seed!({ "README.md" => "# Desk Lamp\n" })

      assert_no_difference "Maker::Release.count" do
        create_release!(version: "")
      end
      assert_match(/Release not created/, flash[:alert])
    end

    # --- 5. changed since -----------------------------------------------------------------------

    # `stat_all` READS THE CATALOG ON SHARE, so rewriting `content_hash` is what a file changing
    # under the release looks like from the panel's side (§14a: the token is the content hash here
    # and the sync server's version id on chunk_remote).
    test "a file whose content moved on since the release is counted and marked" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })
      create_release!
      node!("base.stl").update_column(:content_hash, "h-changed")

      get project_path(@project)
      assert_select "details.release summary .badge.changed", text: "1 changed since"
      rows = css_select("table.release-files tbody tr")
      changed = rows.find { |r| r.css("td.col-path").text.strip == "models/base.stl" }
      assert_equal "changed", changed.css("td.col-state").text.strip
      assert_equal "", rows.find { |r| r.css("td.col-path").text.strip == "README.md" }.css("td.col-state").text.strip
      # A CHANGED FILE STILL DOWNLOADS -- the link delivers the CURRENT bytes, which is the whole
      # point of a release that never copied any.
      assert_equal 2, css_select("td.col-dl a").size
    end

    test "a file deleted after the release loses its link and says where it went" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })
      create_release!
      node!("base.stl").update!(deleted: true)

      get project_path(@project)
      assert_select "details.release summary .badge.changed", text: "1 changed since"
      rows = css_select("table.release-files tbody tr")
      gone = rows.find { |r| r.css("td.col-path").text.strip == "models/base.stl" }
      assert_equal "gone", gone.css("td.col-state").text.strip
      assert_equal "no longer in the library", gone.css("td.col-dl").text.strip
      assert_equal 0, gone.css("td.col-dl a").size
      assert_equal 1, css_select("td.col-dl a").size, "the surviving file still downloads"
    end

    # --- 6. destroy and tenancy ------------------------------------------------------------------

    # A RECORD THAT IS NOT COMPLETE SAYS SO, TWICE: in the flash the moment it is made and on the
    # row forever (`files_truncated` is a column). The snapshot's cap is injected at 1 -- building
    # five thousand files is not a test -- through the constant the default kwarg reads.
    def with_snapshot_cap(cap)
      klass = Maker::ReleaseSnapshot
      original = klass::FILE_CAP
      klass.send(:remove_const, :FILE_CAP)
      klass.const_set(:FILE_CAP, cap)
      yield
    ensure
      klass.send(:remove_const, :FILE_CAP)
      klass.const_set(:FILE_CAP, original)
    end

    test "a release of a folder larger than the snapshot's cap says so in the flash and on its row" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })

      with_snapshot_cap(1) { create_release! }

      assert_equal "Released v1.0.0 with 1 file (first 1 of a larger folder).", flash[:notice]
      release = Maker::Release.order(:id).last
      assert_equal true, release.files_truncated

      follow_redirect!
      assert_select "details.release summary .badge.truncated", text: "1 of a larger folder"

      @user.update!(handle: "ada")
      @project.update!(visibility: "public")
      get public_project_path("ada", @project.slug)
      assert_response :success
      assert_select "details.release summary .badge.truncated", text: "1 of a larger folder"
    end

    test "destroy removes the release and its file rows, and touches no bytes" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })
      create_release!
      release = Maker::Release.order(:id).last

      assert_difference "Maker::ReleaseFile.count", -2 do
        assert_difference "Maker::Release.count", -1 do
          delete release_path(release)
        end
      end
      assert_redirected_to project_path(@project)
      assert_equal "Removed release v1.0.0.", flash[:notice]
      assert_equal 2, @user.nodes.present.where(kind: "file").count, "a release never owned the bytes"
    end

    test "a foreign release cannot be destroyed and a foreign project cannot be released" do
      other = other_user!
      foreign = other.maker_projects.create!(name: "Theirs")
      foreign_release = foreign.releases.create!(user: other, version: "v1", published_at: Time.current)

      delete release_path(foreign_release)
      assert_response :not_found

      assert_no_difference "Maker::Release.count" do
        post project_releases_path(foreign), params: { release: { version: "v2" } }
      end
      assert_response :not_found
    end

    # --- 7. the public page ----------------------------------------------------------------------

    # THE SAME RELEASE, READ BY A STRANGER. The three things this pins that the private panel cannot:
    # every link carries the unlisted token, there is no composer and no Remove, and a file that has
    # left the project is refused a link by `permits?` rather than merely by being gone.
    test "the public page lists the release with token-carrying downloads, no composer and no remove" do
      seed!({ "README.md" => "# Desk Lamp\n", "models/base.stl" => "solid base\n" })
      create_release!(notes: "<div>First cut.</div>")
      @user.update!(handle: "ada")
      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token
      # LIVE BUT NO LONGER THE PROJECT'S: moved to the library root AND detached, so `page_nodes`
      # still finds it and only `permits?` can refuse it. A tombstoned file would make this case
      # pass with the permission check deleted. BOTH HALVES ARE NEEDED because `permits?` permits by
      # ancestry OR by attachment, and Library::ScanJob's project intake attaches every file it
      # files into a project's folder (§14f) — so moving the node alone leaves the attachment arm
      # answering true, which is how this assertion first read green against a broken claim.
      moved = node!("base.stl")
      @project.file_attachments.find_by(node_id: moved.node_id)&.destroy!
      moved.update!(parent_node_id: nil)

      get public_project_path("ada", @project.slug, k: token)
      assert_response :success

      assert_select "section.panel.releases-panel h2", text: "Releases"
      assert_select ".releases-panel .mono.muted", text: "1 release"
      assert_select "details.release .release-version", text: "v1.0.0"
      assert_select ".release-notes", text: /First cut\./
      assert_select "details.composer", count: 0
      assert_select ".releases-panel form", count: 0

      rows = css_select(".releases-panel table.release-files tbody tr")
      assert_equal 2, rows.size
      readme = rows.find { |r| r.css("td.col-path").text.strip == "README.md" }
      link = readme.css("td.col-dl a").first
      assert link, "a file still in the project downloads"
      assert_includes link["href"], "k=#{token}"
      assert_includes link["href"], "download=1"

      moved = rows.find { |r| r.css("td.col-path").text.strip == "models/base.stl" }
      assert_equal 0, moved.css("td.col-dl a").size,
                   "a file that has left the project is not linked, however live its node is"
      assert_equal "no longer available", moved.css("td.col-dl").text.strip
    end

    test "the releases panel is omitted from a public page with no releases, and a private project is still 404" do
      seed!({ "README.md" => "# Desk Lamp\n" })
      @user.update!(handle: "ada")
      @project.update!(visibility: "public")

      get public_project_path("ada", @project.slug)
      assert_response :success
      assert_select "section.panel.releases-panel", count: 0

      @project.update!(visibility: "private")
      get public_project_path("ada", @project.slug)
      assert_response :not_found
    end
  end
end
