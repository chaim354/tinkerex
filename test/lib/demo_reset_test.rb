require "test_helper"
require "support/public_fixture"

# THE NIGHTLY RESET, RUN FOR REAL: a demo library a visitor has dirtied becomes exactly the committed
# seed set again, through the port, with the account recreated and the scan's post-reconcile sequence
# (discovery, the filing sweep, the model catalog) run over it.
#
# IT PINS SHARE, FIRST LINE OF SETUP, AND THAT IS WHAT MAKES IT HONEST ON ALL THREE CI LEGS.
# `use_fresh_share_library!` hands this test a real Share port over its own temp directory whatever
# LIBRARY_BACKEND the leg exported, so every byte the reset deletes, purges and writes is a real file
# this test can read back — on the s3 leg the stub bucket would hold nothing, and on chunk_remote
# there is no byte write at all (which the reset refuses; see the refusal test below).
class DemoResetTest < ActiveSupport::TestCase
  include PublicFixture

  SEED_DIR = Rails.root.join("db/seeds/demo")
  FOLDER = "Projects/Desk Lamp".freeze

  setup do
    @root = use_fresh_share_library!
    @user = make_owner!(handle: "demo")
    @port = FileLayer.current

    # WHAT A DAY OF VISITORS LEAVES: two folders and three files through the port (one of them over a
    # seed path, so the reset must replace content as well as remove it), a project claiming the
    # visitor's folder, a note, a device, and a ready preview with a real attached asset.
    projects = @port.mkdir(@user, name: "Projects")
    graffiti = @port.mkdir(@user, parent_node_id: projects.node_id, name: "Graffiti")
    @tag = @port.write(@user, parent_node_id: graffiti.node_id, name: "tag.svg", io: StringIO.new("<svg/>"))
    @port.write(@user, name: "Welcome.md", io: StringIO.new("defaced\n"))
    loose = @port.write(@user, name: "loose.stl", io: StringIO.new("solid loose\nendsolid loose\n"))

    @user.maker_projects.create!(name: "Graffiti", folder_node_id: graffiti.node_id)
    @user.maker_notes.create!(node_id: loose.node_id, body: "left by a visitor")
    Device.register!(user: @user, name: "visitor laptop")
    ready_preview!(@user, @user.nodes.find_by!(node_id: loose.node_id))
  end

  def reset!(user = @user, seed_dir: SEED_DIR) = Tinkerex::DemoReset.new(user:, seed_dir:).call

  # Every file and folder the seed directory holds, relative to it — read off the directory itself,
  # so a file added to db/seeds/demo needs no edit here.
  def seed_paths = Dir.glob("**/*", base: SEED_DIR).sort

  def library_paths(user) = user.nodes.present.pluck(:storage_path).sort

  def trash_entries = Dir.children(@root.join(Library::Scanner::TRASH_PREFIX))

  test "a dirtied demo library and account become exactly the seed set again" do
    old_id = @user.id
    old_email = @user.email

    fresh = reset!

    # THE ACCOUNT IS A NEW ROW WITH THE SAME ADDRESS. A new id is what signs out every visitor holding
    # the old one; a password nobody was told is what keeps the account behind the one-click door.
    assert_equal old_email, fresh.email
    assert_equal "demo", fresh.handle
    refute_equal old_id, fresh.id
    assert fresh.confirmed_at.present?, "an unconfirmed account cannot be signed in"
    refute fresh.valid_password?(PublicFixture::PASSWORD), "the visitor-era password still works"

    # THE OLD ACCOUNT IS GONE WITH EVERYTHING IT OWNED — the User model's `dependent:` chain, not a
    # hand-rolled sweep. Devices FIRST, ahead of the row itself: `devices.user_id` carries a real
    # foreign key, so a reset that drops the row without its chain cannot even run, and the only
    # way to skip the destroy and still finish is to move the old row aside — which is caught here,
    # by the visitor's device still being enrolled.
    assert_empty Device.where(user_id: old_id), "a device the old account enrolled survived the reset"
    assert_empty Maker::Note.where(user_id: old_id)
    assert_empty Maker::Preview.where(user_id: old_id)
    assert_empty Maker::Project.where(user_id: old_id)
    assert_empty Node.where(user_id: old_id)
    refute User.exists?(old_id), "the old row survived"

    # THE LIBRARY IS THE SEED, NOTHING MORE AND NOTHING LESS: the visitor's folder and stray file are
    # gone, and the scan found nothing on disk the port did not write.
    assert_equal seed_paths, library_paths(fresh)
    assert_equal SEED_DIR.join("#{FOLDER}/models/base.stl").binread,
                 @root.join("#{FOLDER}/models/base.stl").binread
    assert_equal SEED_DIR.join("Welcome.md").binread, @root.join("Welcome.md").binread,
                 "a seed file a visitor overwrote was not put back"
    refute @root.join("Projects/Graffiti").exist?
    refute @root.join("loose.stl").exist?

    # THE TRASH THE DELETES FILLED IS EMPTIED — and `.trash` itself is kept, as the reaper always
    # keeps it (an empty root reads as an unmounted share).
    assert @root.join(Library::Scanner::TRASH_PREFIX).directory?, "the reset removed .trash itself"
    assert_empty trash_entries, "the deleted library is still sitting in the trash"
  end

  test "the scan runs its whole sequence: the project is discovered and its folder swept" do
    fresh = reset!

    # The seed's two project folders, each discovered, and nothing else.
    assert_equal [ "Desk Lamp", "catan" ], fresh.maker_projects.pluck(:name).sort
    folder = fresh.nodes.present.find_by!(storage_path: FOLDER)
    project = fresh.maker_projects.find_by!(name: "Desk Lamp")
    assert_equal "Desk Lamp", project.name
    assert_equal folder.node_id, project.folder_node_id
    assert project.discovered_at.present?, "the project was not made by discovery"

    # WHAT THE FILING SWEEP ACTUALLY DID, OBSERVED: it attached all five files under the folder and
    # moved none of them. The README is the folder's only loose file and is attached but never filed
    # (`:project_readme`); everything else already sits in a subfolder, which the sweep never
    # revisits (root = inbox). `last_sweep_moves` is 0 rather than nil — nil would mean no sweep that
    # was allowed to file ever finished.
    readme = fresh.nodes.present.find_by!(storage_path: "#{FOLDER}/README.md")
    assert_equal folder.node_id, readme.parent_node_id, "the README was filed away from the root"
    in_folder = fresh.nodes.present.where(kind: "file").where("storage_path LIKE ?", "#{FOLDER}/%")
    assert_equal 5, in_folder.count
    assert_equal in_folder.pluck(:node_id).sort, project.file_attachments.pluck(:node_id).sort
    assert_equal 0, project.last_sweep_moves
    assert project.last_swept_at.present?

    # The thumbnails the upload door would have queued. A port write is not an upload and the scan
    # sees these files as unchanged, so without the reset asking, the demo would never get a picture.
    stl = fresh.nodes.present.find_by!(storage_path: "#{FOLDER}/models/base.stl")
    preview = fresh.maker_previews.find_by(node_id: stl.node_id, kind: "thumbnail")
    assert preview, "no thumbnail was queued for the seed's STL"
    assert_equal stl.content_hash, preview.version_id
  end

  test "a second reset lands on the same state" do
    first = reset!
    first_paths = library_paths(first)
    first_projects = first.maker_projects.pluck(:name).sort

    second = reset!(first)

    refute_equal first.id, second.id
    assert_equal first.email, second.email
    assert_equal "demo", second.handle
    assert_equal first_paths, library_paths(second)
    assert_equal seed_paths, library_paths(second)
    assert_equal first_projects, second.maker_projects.pluck(:name).sort
    assert_empty trash_entries
  end

  test "a missing or empty seed directory is refused before anything is touched" do
    before = library_paths(@user)

    err = assert_raises(Tinkerex::DemoReset::Refused) { reset!(seed_dir: @root.join("no-such-seed")) }
    assert_match(/no-such-seed/, err.message, "the refusal must name the directory it looked for")

    # Folders and OS clutter but no file is still nothing to seed from.
    empty = Pathname.new(Dir.mktmpdir("demo-seed"))
    empty.join("Projects").mkpath
    empty.join(".DS_Store").binwrite("clutter")
    err = assert_raises(Tinkerex::DemoReset::Refused) { reset!(seed_dir: empty) }
    assert_match(/no files/, err.message)

    assert User.exists?(@user.id), "a refused reset destroyed the account"
    assert_equal before, library_paths(@user), "a refused reset changed the library"
    assert_equal 1, @user.devices.count
  ensure
    FileUtils.remove_entry(empty) if empty&.exist?
  end

  # ON SHARE AND S3 THE LIBRARY IS EVERY ACCOUNT'S (Tinkerex::Registration's header), so a second
  # account here means the reset's delete would take that account's files too. Both halves, in one
  # test: refused with the other account present, and the same reset runs once it is gone — so the
  # condition is exactly "another account exists", not something else about this library.
  test "on a library another account shares it refuses before touching anything, then runs once it is the only one" do
    other = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current)
    # A trash entry that must survive the refusal: the purge is a phase too.
    @port.delete(@user, node_id: @tag.node_id)
    paths = library_paths(@user)
    trash = trash_entries
    refute_empty trash

    err = assert_raises(Tinkerex::DemoReset::Refused) { reset! }
    assert_match(/would wipe a library 1 other account shares/, err.message)

    assert_equal @user.id, User.find(@user.id).id, "the demo row was replaced anyway"
    assert_equal paths, library_paths(@user), "a node was deleted before the refusal"
    assert_equal trash, trash_entries, "the trash was purged before the refusal"
    assert @root.join("loose.stl").exist?
    assert_equal 1, @user.devices.count

    other.destroy!
    assert_equal seed_paths, library_paths(reset!)
  end

  # A PORT THAT IS NEITHER SHARE NOR S3 — chunk_remote, today — has no byte write and no trash this
  # app owns, so the reset could delete the library and then fail to put anything back. It must say
  # so before its first delete. Anything the reset asks of the port is recorded, so "nothing was
  # touched" is an observation rather than an inference.
  class RecordingPort
    attr_reader :calls

    def initialize = @calls = []

    def method_missing(name, *, **)
      @calls << name
      nil
    end

    def respond_to_missing?(*) = true
  end

  test "a backend the reset cannot rebuild is refused before its first delete" do
    port = RecordingPort.new
    FileLayer.current = port

    err = assert_raises(Tinkerex::DemoReset::Refused) { reset! }
    assert_match(/share or s3/, err.message)
    assert_empty port.calls, "the reset reached the port before refusing"
    assert User.exists?(@user.id), "the account was destroyed before the refusal"
  end

  # THE SEED IS THE OWNER'S WHOLE `catan` PROJECT (about 61 MB) beside the small Desk Lamp set: the
  # landing on tinkerex.com shows twelve of its files and the demo holds all of them, by the owner's
  # decision (2026-10-16; docs/superpowers/specs/2026-10-16-landing-format-wall-design.md §3). It
  # ships in the image and is rewritten every night, so the ceiling still matters: it catches a
  # whole library committed by accident.
  test "the committed seed set stays within its budget" do
    bytes = Dir.glob("**/*", base: SEED_DIR).sum { |rel| File.file?(SEED_DIR.join(rel)) ? File.size(SEED_DIR.join(rel)) : 0 }
    assert_operator bytes, :<, 70 * 1024 * 1024,
                    "db/seeds/demo ships in the image and is rewritten every night; keep it under 70 MB"
  end

  # EVERY NAME IN THE SHIPPED SEED IS ONE THE PORT ACCEPTS. The reset writes each entry through
  # mkdir/write, and a single name the doors refuse (a `.git`, a `.trash`, a slash) would fail the
  # nightly reset on the public box -- found by a visitor, not by this suite, unless this asks. It
  # reads the reset's OWN walk, never `seed_paths`: a glob skips dot-names, the very names (`.git`,
  # `.trash`) this exists to catch, and an empty `.trash` in the seed left it green (mutation-checked).
  test "every name in the shipped seed is one the doors accept" do
    names = Tinkerex::DemoReset.seed_entries(SEED_DIR).flat_map { |rel, _path| rel.split("/") }.uniq
    assert_operator names.size, :>, 20, "the scan found too few names; did SEED_DIR move?"
    refused = names.reject { |n| Maker::MoveNode.valid_leaf_name?(n) && !Library::ReservedNames.reserved?(n) }
    assert_empty refused, "the reset would refuse these seed names: #{refused.inspect}"
  end
end
