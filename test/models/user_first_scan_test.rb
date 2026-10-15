require "test_helper"

# THE FIRST SCAN FOLLOWS THE ACCOUNT (J, 2026-10-15). Library::ScanJob is enqueued per user, so a
# boot-time scan finds no one to scan for on a fresh install; the account's creation is the moment
# the library gets a reader. This is what makes "indexed on start" true for a stranger who drops the
# compose file into a folder of files and signs up: the folder is indexed within seconds of the first
# account, with no Rescan. The first test skips on a backend that does not poll (chunk_remote's leg);
# the second stubs the capability on the others and runs naturally there.
class UserFirstScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end

  def create_account! = User.create!(email: "scan-#{SecureRandom.hex(4)}@example.com", password: "a-long-enough-password", confirmed_at: Time.current)

  test "a new account enqueues one library scan naming itself, on a backend whose catalog comes from polling" do
    skip "not a scannable backend" unless FileLayer.current.capabilities.scannable?
    user = nil
    assert_enqueued_with(job: Library::ScanJob) { user = create_account! }
    args = enqueued_jobs.map { |j| j[:args].first }.select { |a| a.is_a?(Hash) && a["user_id"] == user.id }
    assert_equal 1, args.size, "exactly one scan for the new account: #{enqueued_jobs.inspect}"
  end

  test "nothing is enqueued when the backend is not scannable" do
    caps = FileLayer.current.capabilities.with(scannable: false)
    replacing(FileLayer.current, :capabilities, -> { caps }) do
      assert_no_enqueued_jobs(only: Library::ScanJob) { create_account! }
    end
  end
end
