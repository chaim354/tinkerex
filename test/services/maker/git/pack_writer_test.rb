require "test_helper"

# THE ONLY TEST THAT PROVES ANYTHING HERE IS ONE REAL GIT RUNS. A hand-rolled parser in the test
# would share whatever misunderstanding the writer has and confirm it -- the FakeS3 lesson (§14e),
# where an exactly-inverse encode/decode pair kept 79 of 80 tests green over silent data loss.
# Assert the WIRE, and let git be the reader.
class Maker::Git::PackWriterTest < ActiveSupport::TestCase
  def setup
    skip "needs the git binary" unless system("git --version > /dev/null 2>&1")
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  test "git reads a pack this writes, with every loose object deleted" do
    build_repo_with_commits(3)
    objects = loose_objects

    Maker::Git::PackWriter.write(File.join(@dir, ".git/objects/pack"), objects)
    delete_loose_objects!

    assert_equal 0, loose_object_paths.size, "setup error: loose objects survived"
    assert git("fsck --full --strict"), "git fsck rejected the pack"
    assert_equal "3", git_out("rev-list --count HEAD")
  end

  test "the oid this writer names matches the oid git computed" do
    build_repo_with_commits(2)
    loose_objects.each do |oid, type, payload|
      recomputed = Digest::SHA1.hexdigest("#{type} #{payload.bytesize}\0".b + payload)
      assert_equal oid, recomputed, "oid naming rule disagrees with git for a #{type}"
    end
  end

  test "it refuses an offset past the idx v2 4-byte field rather than writing a corrupt idx" do
    # A >2 GiB pack needs the large-offset table, which this writer does not implement. Writing a
    # truncated offset instead would produce an idx that PARSES and resolves the wrong objects --
    # silent corruption of someone's history. Refuse loudly.
    huge = [ { oid: "a" * 40, offset: 0x80000000, crc: 0 } ]
    assert_raises(RuntimeError) { Maker::Git::PackWriter.build_idx(huge, "x" * 20) }
  end

  private

  def git(args) = system("git -C #{@dir} #{args} > /dev/null 2>&1")
  def git_out(args) = `git -C #{@dir} #{args}`.strip

  def build_repo_with_commits(count)
    system("git init -q #{@dir} && git -C #{@dir} config gc.auto 0 && " \
           "git -C #{@dir} config user.email b@t && git -C #{@dir} config user.name Bot")
    count.times do |i|
      File.write(File.join(@dir, "f.txt"), "line #{i}\n", mode: "a")
      system("git -C #{@dir} add -A && git -C #{@dir} commit -qm 'c#{i}' --no-gpg-sign")
    end
  end

  def loose_object_paths = Dir.glob(File.join(@dir, ".git/objects/??/*"))

  def loose_objects
    loose_object_paths.map do |path|
      oid = path.split("/")[-2] + File.basename(path)
      type, payload = Maker::Git::PackWriter.read_loose(path)
      [ oid, type, payload ]
    end
  end

  def delete_loose_objects! = loose_object_paths.each { |p| File.unlink(p) }
end
