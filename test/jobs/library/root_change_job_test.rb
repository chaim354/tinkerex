require "test_helper"
require "tmpdir"

module Library
  # A LIBRARY-FOLDER CHANGE, DRIVEN AGAINST A REAL MOUNT (K §5). LIBRARY_PATH is pointed at a tmpdir
  # holding folder A, the catalog is scanned from A, and the choice then moves to another folder.
  #
  # SHARE BY NATURE, RUN ON EVERY LEG (§15: the three legs must report identical RUN counts). The
  # setup is the same everywhere -- a commanded scan of A works on any backend -- and only the
  # assertions branch: on s3 and chunk_remote the change has no folder to apply to, so the job must
  # neither scan nor reset, and the catalog must come out exactly as it went in.
  class RootChangeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # 10 of 10 files gone is 100% of the catalog, far past LIBRARY_SCAN_MAX_DELETE_PCT's default of
    # 20 -- and the guard has no floor (Library::Reconciler#guard_mass_deletion!), so a small
    # library is refused as surely as a large one.
    FILES = 10

    setup do
      @saved_library_path = ENV["LIBRARY_PATH"]
      @mount = Pathname.new(Dir.mktmpdir("root-change"))
      ENV["LIBRARY_PATH"] = @mount.to_s
      FileLayer.reset!

      @user = User.create!(email: "root-change-#{SecureRandom.hex(4)}@example.com")
      write_files!("A", "a")
      write_files!("C", "c")
      Tinkerex::LibraryRoot.choose!("A")
      Library::ScanJob.perform_now(user_id: @user.id, root: @mount.join("A").to_s)
      @scanned_at = @user.reload.library_scanned_at
      @before = catalog
      assert_equal FILES, @before.size, "the scan of A must have indexed it"
    end

    teardown do
      ENV["LIBRARY_PATH"] = @saved_library_path
      FileLayer.reset!
      FileUtils.remove_entry(@mount) if @mount&.exist?
    end

    # The same files under a new name (the old folder renamed on the host): storage_path is relative
    # to the root, so every file scans as unchanged and keeps its node_id, attachments and all.
    test "switching to the same files under another folder keeps every node" do
      File.rename(@mount.join("A"), @mount.join("B"))
      Tinkerex::LibraryRoot.choose!("B")

      Library::RootChangeJob.perform_now(user_id: @user.id)

      assert_equal @before, catalog, "every node_id unchanged, at the same relative path"
      assert_equal 0, @user.nodes.where(deleted: true).count, "nothing tombstoned"
      if share?
        assert_operator @user.reload.library_scanned_at, :>, @scanned_at, "the new folder was scanned"
      else
        assert_unchanged_off_share
      end
    end

    # A DIFFERENT library is what the mass-deletion guard exists to refuse, and "switch" must reach
    # it unweakened (K §5). Mutation-checked: LIBRARY_SCAN_MAX_DELETE_PCT=100 turns this RED.
    test "switching onto a different set of files is refused by the mass-deletion guard" do
      Tinkerex::LibraryRoot.choose!("C")

      if share?
        err = assert_raises(Library::Scanner::UnsafeScan) do
          Library::RootChangeJob.perform_now(user_id: @user.id)
        end
        assert_match(%r{#{FILES}/#{FILES} observable files}, err.message)
      else
        Library::RootChangeJob.perform_now(user_id: @user.id)
        assert_unchanged_off_share
      end
      assert_equal @before, catalog, "a refused scan leaves the catalog exactly as it was"
    end

    test "starting over with a different set of files indexes exactly those, and never touches disk" do
      Tinkerex::LibraryRoot.choose!("C")

      Library::RootChangeJob.perform_now(user_id: @user.id, start_over: true)

      if share?
        assert_equal names("c").sort, catalog.keys.sort, "exactly C's files, at their relative paths"
        assert_empty @before.values & catalog.values, "a fresh catalog: no node_id survives the reset"
        assert_equal 0, @user.nodes.where(deleted: true).count, "the old catalog is gone, not tombstoned"
      else
        # The job's gate order: a reset asked before the share check wipes this catalog (RED on the
        # s3 leg, mutation-checked).
        assert_equal @before, catalog, "off share there is no folder change to start over for"
        assert_unchanged_off_share
      end
      names("a").each { |name| assert @mount.join("A", name).file?, "#{name} is still on disk" }
    end

    private

    def share? = FileLayer.current.is_a?(FileLayer::Share)

    # No reset and no scan: the stamp a scan writes did not move.
    def assert_unchanged_off_share
      assert_equal @scanned_at, @user.reload.library_scanned_at, "no scan ran off share"
    end

    def names(prefix) = (1..FILES).map { |i| "#{prefix}-#{i}.txt" }

    # Distinct names AND distinct bytes per folder: a shared name would match by path and a shared
    # (hash, size) would pair as a move, and either would hide the different-library case.
    def write_files!(folder, prefix)
      dir = @mount.join(folder)
      dir.mkpath
      names(prefix).each_with_index { |name, i| dir.join(name).binwrite("#{prefix} #{i} " * (i + 1)) }
    end

    # Live files by relative path => node_id.
    def catalog = @user.nodes.present.where(kind: "file").pluck(:storage_path, :node_id).to_h
  end
end
