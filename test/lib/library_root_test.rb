require "test_helper"
require "tmpdir"
require_relative "../support/fake_s3"

# THE LIBRARY FOLDER IS THE MOUNT PLUS A STORED CHOICE (K, 2026-10-20) -- Tinkerex::LibraryRoot, the
# one reader and writer of `library.root`. Every test builds a real mount, because the rules are about
# a filesystem: what may become the root, and what the chooser may list.
class LibraryRootTest < ActiveSupport::TestCase
  KEY = Tinkerex::LibraryRoot::KEY
  Invalid = Tinkerex::LibraryRoot::Invalid

  setup do
    @mount = Pathname.new(Dir.mktmpdir("mount")).expand_path
    @outside = Pathname.new(Dir.mktmpdir("outside")).expand_path
    @prior_path = ENV["LIBRARY_PATH"]
    ENV["LIBRARY_PATH"] = @mount.to_s
    FileLayer.reset!
  end

  teardown do
    @prior_path.nil? ? ENV.delete("LIBRARY_PATH") : ENV["LIBRARY_PATH"] = @prior_path
    FileLayer.reset!
    [ @mount, @outside ].each { |dir| FileUtils.remove_entry(dir) if dir&.exist? }
  end

  def share! = FileLayer.current = FileLayer::Share.new(root: @mount.to_s)

  def mkdirs(*rels) = rels.each { |rel| FileUtils.mkdir_p(@mount.join(rel)) }

  # ============================================================ pending? and path

  test "a share library with no stored choice is pending, and the whole mount is its root" do
    share!
    Setting.forget(KEY)

    assert Tinkerex::LibraryRoot.pending?
    assert_equal @mount, Tinkerex::LibraryRoot.path, "pending is not a boot state: the mount stays a valid root"
  end

  test "a stored empty choice is the whole mount, and is not pending" do
    share!
    Setting.put(KEY, "")

    assert_not Tinkerex::LibraryRoot.pending?
    assert_equal @mount, Tinkerex::LibraryRoot.path
  end

  test "an s3 library is never pending, whatever the row says" do
    FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                          secret_access_key: "sk", client: FakeS3.new.client)
    Setting.forget(KEY)

    assert_not Tinkerex::LibraryRoot.pending?, "s3 has no folder to choose"
  end

  # ============================================================ choose!

  test "choose! writes the choice, joins it onto the mount and resets the adapter" do
    mkdirs("Workshop/3d")
    FileLayer.current # build the adapter over the mount, so the reset is what moves it

    assert_equal "Workshop/3d", Tinkerex::LibraryRoot.choose!("Workshop/3d")

    assert_equal "Workshop/3d", Setting.get(KEY)
    assert_equal @mount.join("Workshop/3d"), Tinkerex::LibraryRoot.path
    assert_equal @mount.join("Workshop/3d"), FileLayer.current.root,
                 "choose! must reset FileLayer.current, or this process keeps serving the old root"
  end

  test "choose! with an empty string chooses the whole mount" do
    Setting.forget(KEY)

    Tinkerex::LibraryRoot.choose!("")

    assert_equal "", Setting.get(KEY)
  end

  # REJECT, NEVER NORMALISE. Each rejection must name its rule and write nothing.
  {
    "an absolute path" => [ "/etc", /absolute path/ ],
    "a parent step" => [ "a/../b", /step outside/ ],
    "an empty segment" => [ "a//b", /empty folder name/ ],
    "a trailing slash" => [ "a/", /empty folder name/ ],
    "a dot-folder" => [ ".config", /hidden or reserved/ ],
    "the trash" => [ ".trash", /hidden or reserved/ ],
    "a temp name" => [ ".maker-tmp-x", /hidden or reserved/ ],
    "a folder inside .git" => [ "repo/.git", /hidden or reserved/ ],
    "OS clutter with no dot" => [ "__MACOSX", /hidden or reserved/ ],
    "a missing folder" => [ "nowhere", /not a folder any more/ ]
  }.each do |what, (value, message)|
    test "choose! refuses #{what} and writes nothing" do
      mkdirs("a/b", "repo/.git", "__MACOSX", ".config")
      Setting.put(KEY, "before")

      error = assert_raises(Invalid) { Tinkerex::LibraryRoot.choose!(value) }

      assert_match message, error.message
      assert_equal "before", Setting.get(KEY)
    end
  end

  test "choose! refuses a plain file" do
    @mount.join("notes.txt").write("x")

    error = assert_raises(Invalid) { Tinkerex::LibraryRoot.choose!("notes.txt") }
    assert_match(/not a folder/, error.message)
  end

  # THE LINK IS REFUSED BY NAME, NOT FOLLOWED: the escape target is a real, writable directory, so
  # only the lstat on the segment stops it (mutation-checked: `stat` for `lstat` turns this green).
  test "choose! refuses a link to a folder outside the mount" do
    File.symlink(@outside.to_s, @mount.join("escape").to_s)
    Setting.put(KEY, "before")

    error = assert_raises(Invalid) { Tinkerex::LibraryRoot.choose!("escape") }

    assert_match(/is a link/, error.message)
    assert_equal "before", Setting.get(KEY)
  end

  test "choose! refuses a path whose middle segment is a link" do
    FileUtils.mkdir_p(@outside.join("inner"))
    File.symlink(@outside.to_s, @mount.join("linked").to_s)

    error = assert_raises(Invalid) { Tinkerex::LibraryRoot.choose!("linked/inner") }
    assert_match(/is a link/, error.message)
  end

  # THE PUID MESSAGE (K §4.3). LibraryBackendCheck.writable! is the boot guard's real touch-probe;
  # 0555 is a mode it refuses. (On an ACL filesystem no unit test can tell it from File.writable?,
  # which library_backend_check.rb already records.)
  test "choose! refuses a folder the app cannot write, naming the user it runs as, and writes nothing" do
    skip "root writes through 0555" if Process.uid.zero?

    mkdirs("locked")
    File.chmod(0o555, @mount.join("locked"))
    Setting.forget(KEY)

    error = assert_raises(Invalid) { Tinkerex::LibraryRoot.choose!("locked") }

    assert_match(/runs as user #{Process.uid}:#{Process.gid}/, error.message)
    assert_match(/PUID and PGID/, error.message)
    assert_not Setting.exists?(key: KEY)
  ensure
    File.chmod(0o755, @mount.join("locked")) if @mount.join("locked").exist?
  end

  test "clear! chooses the whole mount" do
    Setting.put(KEY, "Workshop")

    Tinkerex::LibraryRoot.clear!

    assert_equal "", Setting.get(KEY)
  end

  # ============================================================ children

  test "children lists subfolders only, sorted without regard to case" do
    mkdirs("Gamma", "beta", "Alpha")

    assert_equal %w[Alpha beta Gamma], Tinkerex::LibraryRoot.children("").entries
  end

  test "children of a subfolder answers paths relative to the mount" do
    mkdirs("beta/inner", "beta/other")

    listing = Tinkerex::LibraryRoot.children("beta")

    assert_equal "beta", listing.parent
    assert_equal %w[beta/inner beta/other], listing.entries
  end

  # ONE ASSERTION PER RULE, so removing a filter is one red. `.trash`, `.maker-tmp-x` and `repo/.git`
  # carry no rule of their own (the dot rule covers them) and are asserted for the record.
  test "children hides a dot-folder" do
    mkdirs("Alpha", ".config")
    assert_not_includes Tinkerex::LibraryRoot.children("").entries, ".config"
  end

  test "children hides reserved names that carry no dot" do
    mkdirs("Alpha", "__MACOSX")
    assert_not_includes Tinkerex::LibraryRoot.children("").entries, "__MACOSX"
  end

  test "children hides a linked folder" do
    mkdirs("Alpha")
    File.symlink(@outside.to_s, @mount.join("linked").to_s)
    assert_not_includes Tinkerex::LibraryRoot.children("").entries, "linked"
  end

  test "children hides a plain file" do
    mkdirs("Alpha")
    @mount.join("notes.txt").write("x")
    assert_equal %w[Alpha], Tinkerex::LibraryRoot.children("").entries
  end

  test "children hides the trash, a temp folder and a repository's .git" do
    mkdirs("Alpha", ".trash", ".maker-tmp-x", "repo/.git")

    assert_equal %w[Alpha repo], Tinkerex::LibraryRoot.children("").entries
    assert_equal [], Tinkerex::LibraryRoot.children("repo").entries
  end

  test "children stops at the cap and says so" do
    mkdirs("a", "b", "c")

    listing = Tinkerex::LibraryRoot.children("", limit: 2)

    assert_equal %w[a b], listing.entries
    assert listing.truncated
    assert_not Tinkerex::LibraryRoot.children("").truncated
  end

  test "children refuses a parent outside the mount" do
    assert_raises(Invalid) { Tinkerex::LibraryRoot.children("..") }
    assert_raises(Invalid) { Tinkerex::LibraryRoot.children("/etc") }
  end
end
