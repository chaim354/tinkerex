require "test_helper"

# THE JOBS THAT MUST NOT OVERLAP, AND THE KEY THEY SCOPE ON.
#
# WHAT THIS CAN AND CANNOT ASSERT, STATED UP FRONT so nobody reads more into a green run than it
# earns. Solid Queue enforces `limits_concurrency` in its OWN backend, at enqueue time, via a
# database semaphore. The test env does not run that backend, so no test here can prove that a
# second job is actually blocked or discarded — asserting that would need a live worker, and a
# test that merely enqueued twice and asserted "two jobs enqueued" would pass identically with the
# limit removed, which is this repo's dominant failure mode (§15) rather than a guard.
#
# What IS assertable, and is the part that actually broke in review, is the DECLARATION and the
# COMPUTED KEY. `concurrency_key` is a Proc that Solid Queue instance_execs against the job's
# ActiveJob `arguments`, so a job taking keyword arguments hands it ONE Hash, not the kwargs — get
# that wrong and the key silently computes to nil, `concurrency_limited?` answers false, and the
# limit is inert with nothing anywhere to say so. These tests pin exactly that: the limit exists,
# it is 1, and the key separates the things it must separate while joining the things it must join.
class ConcurrencyLimitsTest < ActiveSupport::TestCase
  setup do
    @a = User.create!(email: "conc-a@example.com")
    @b = User.create!(email: "conc-b@example.com")
  end

  # The scan and the two intakes are per-user: one user's slow library must not stall another's.
  #
  # Maker::ModelIntakeJob JOINED THIS LIST WITH THE JOB ITSELF, not later. A new job copying the
  # `key: ->(args) { args[:user_id] }` shape is exactly the case this file's header describes — get
  # the Proc's arity wrong and the key computes to nil, the limit is inert, and nothing anywhere
  # says so. Mutation-checked, and one tried mutation is worth recording because it stayed GREEN
  # and was RIGHT to: `on_conflict: :block` turns this RED, and so does a TYPO'd key (`args[:uid]`
  # -> nil -> the inert limit). `key: ->(args) { args.first }` does NOT, and that is not a gap —
  # `args` is `[{user_id: 1}]`, so `args.first` still yields a key carrying the user and still
  # separating two of them. It is uglier, not broken. The defect this guards is a key that is nil
  # or shared.
  [ Library::ScanJob, Maker::ProjectIntakeJob, Maker::ModelIntakeJob ].each do |klass|
    test "#{klass} limits concurrency to one run per user" do
      assert_equal 1, klass.concurrency_limit
      assert_equal :discard, klass.concurrency_on_conflict,
                   "a queued duplicate sweep only re-does the running one's work"

      mine  = klass.new(user_id: @a.id).concurrency_key
      again = klass.new(user_id: @a.id).concurrency_key
      other = klass.new(user_id: @b.id).concurrency_key

      assert mine.present?, "a nil key means concurrency_limited? is false and the limit is INERT"
      assert_includes mine, @a.id.to_s, "the key must actually carry the user"
      assert_equal mine, again, "the same user's two runs must contend for one semaphore"
      assert_not_equal mine, other, "different users must not serialize behind each other"
    end
  end

  # ScanJob's other argument must not fragment the key: a share deployment passes `root:` and an
  # s3 one does not, and an operator's explicit `root:` scan has to contend with the scheduled run
  # for the same user — otherwise the two overlap, which is the whole thing being prevented.
  test "Library::ScanJob's key ignores root: so a rooted scan still contends with a scheduled one" do
    assert_equal Library::ScanJob.new(user_id: @a.id).concurrency_key,
                 Library::ScanJob.new(user_id: @a.id, root: "/mnt/library").concurrency_key
  end

  # A LIBRARY-FOLDER CHANGE HOLDS THE SCAN'S OWN SEMAPHORE (K §5), so the two keys must be EQUAL,
  # not merely alike. Solid Queue keys are "<group>/<key>" and the default group is the class name,
  # so without `group: "Library::ScanJob"` this job's key is "Library::RootChangeJob/<id>": present,
  # per user, and contending with nothing -- a reset running underneath a scan, with every other
  # assertion in this file still green. :block, not the scan's :discard: a change must happen.
  test "Library::RootChangeJob shares Library::ScanJob's semaphore, per user, and waits for it" do
    assert_equal 1, Library::RootChangeJob.concurrency_limit
    assert_equal :block, Library::RootChangeJob.concurrency_on_conflict

    scan = Library::ScanJob.new(user_id: @a.id, root: "/mnt/library").concurrency_key
    assert_equal scan, Library::RootChangeJob.new(user_id: @a.id).concurrency_key
    assert_equal scan, Library::RootChangeJob.new(user_id: @a.id, start_over: true).concurrency_key,
                 "start_over: must not fragment the key"
    assert_not_equal scan, Library::RootChangeJob.new(user_id: @b.id).concurrency_key,
                     "different users must not serialize behind each other"
  end
end
