require "test_helper"

module Web
  # THE WIZARD'S UPLOAD COMES BACK TO DONE (2026-11-09; onboarding spec, "Getting back to the wizard
  # after an upload"). files#create honours `return_to` only as an allowlisted flag naming a track,
  # and only for an upload into one of the user's own project folders. A fresh share library pins the
  # port, so this POSTs bytes on every leg and the three report the same runs; the chunk uploader's
  # half (a redirect value the page renders) is welcome_test.rb's.
  class FilesWelcomeReturnTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    STL = "solid b\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid b\n".freeze
    SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>\n).freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "return-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Lamp")
      @project.ensure_library_folder!(@user)
    end

    def upload(files, parent_node_id: @project.folder_node_id, **extra)
      list = files.map { |name, bytes| Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream", original_filename: name) }
      post files_path, params: { file: list.size == 1 ? list.first : list, parent_node_id: }.merge(extra)
    end

    test "an upload from the 3D track's Files step lands on its Done step, already filed" do
      upload({ "bracket.stl" => STL }, return_to: "welcome_models")
      assert_redirected_to welcome_done_path(track: "models", project: @project.slug)
      node = @user.nodes.present.find_by!(name: "bracket.stl")
      assert_equal "models", @user.nodes.find_by!(node_id: node.parent_node_id).name, "filed before the redirect"
      assert flash[:notice].present?
    end

    test "a batch from the files track lands on Done too" do
      upload({ "a.svg" => SVG, "b.svg" => SVG }, return_to: "welcome_files")
      assert_redirected_to welcome_done_path(track: "files", project: @project.slug)
    end

    test "an unknown return_to redirects as before" do
      upload({ "a.svg" => SVG }, return_to: "https://elsewhere.example/")
      # THE EXACT PAGE, NOT A PATTERN: %r{/files/[^/]+\z} also matches the files track's Done URL
      # (/welcome/files/done?project=lamp), so a guard written that way cannot fail (review, 2026-11-09).
      assert_redirected_to file_path(@user.nodes.present.find_by!(name: "a.svg").node_id)
    end

    test "a flag on an upload into a folder that is no project's changes nothing" do
      cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
      upload({ "a.svg" => SVG }, parent_node_id: cad.node_id, return_to: "welcome_files")
      assert_redirected_to file_path(@user.nodes.present.find_by!(name: "a.svg").node_id)
    end

    # A README, because it is the one name the sweep never files (Maker::AttachToProject keeps a README
    # at the project root): the second copy meets the first at the root and is refused. An SVG would
    # not be: the first is filed into its shelf, so the second lands without a clash.
    test "a refused upload goes back as it always has, not to Done" do
      upload({ "README.md" => "# Lamp\n" }, return_to: "welcome_files")
      upload({ "README.md" => "# Lamp\n" }, return_to: "welcome_files")
      assert_response :redirect
      assert_no_match %r{/welcome/}, response.location
    end
  end
end
