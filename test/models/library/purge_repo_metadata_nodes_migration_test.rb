require "test_helper"
require Dir[Rails.root.join("db/migrate/*_purge_repo_metadata_nodes.rb")].first

module Library
  # DRIVES THE MIGRATION, IN THE ENVIRONMENT THAT BROKE IT. `bin/ci setup` failed on a clean clone
  # at 6273b60 — `db:prepare` aborted with `KeyError: key not found: "LIBRARY_PATH"` raised five
  # frames below this migration, because it asks FileLayer.current for a capability and a fresh
  # clone configures no library backend at all.
  #
  # NOTHING IN CI COULD SEE IT: `setup` is in config/ci.rb's LOCAL_ONLY_GATES, so no CI job runs it
  # (`bin/ci --list-ci` omits it), and every deployed destination sets its own backend's env — so
  # the three backend legs, the deploy, and the service's own suite were all green over a migration
  # that could not run on a developer's machine. This file is the leg that can go red for it, and
  # it deliberately drives `up` rather than the service, because two of the three defects lived
  # OUTSIDE the service: the factory not passing the backend it resolved to its guard, and this
  # migration re-asking FileLayer inside the very branch that handles FileLayer being unaskable.
  class PurgeRepoMetadataNodesMigrationTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "purge-migration-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    def run_migration
      migration = PurgeRepoMetadataNodes.new
      migration.verbose = true
      out, = capture_io { migration.up }
      out
    end

    # A node beneath a marker, built the way Library::Reconciler builds one on share/s3 —
    # storage_path AND a real parent chain, since the purge resolves by walking parents.
    def node_under_git
      repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir",
                                 storage_path: "firmware")
      marker = @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                                   storage_path: "firmware/.git", parent_node_id: repo.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "config", kind: "file", size: 1,
                          storage_path: "firmware/.git/config", parent_node_id: marker.node_id)
    end

    # THE REGRESSION, STATED AS THE THING THAT ACTUALLY BROKE. Not "the service returns declined" —
    # `db:prepare` must complete. Mutation-check by reverting either half: FileLayer.build calling
    # `LibraryBackendCheck.check!` with no arguments again, or #decline_reason dropping its rescue.
    test "a fresh clone with no library backend configured migrates without raising" do
      inner = node_under_git

      with_no_library_configured { assert_nothing_raised { run_migration } }

      assert Node.exists?(inner.id),
             "a migration that could not even ask which backend this is must destroy nothing"
    end

    # A SILENT DECLINE WOULD BE THE WORSE FIX. On a real deployment this branch means the purge did
    # not happen, and the operator has to be able to read that off the deploy log — so it is not
    # enough for `up` to survive, it has to SAY which of the two declines this was. Pinned on the
    # migration's own OUTPUT rather than on Result#reason, because the defect was the migration
    # composing a sentence of its own that named the wrong one.
    test "the decline names the CONFIGURATION, not a scannable backend that is not there" do
      out = with_no_library_configured { run_migration }

      assert_match(/declined/, out)
      assert_match(/no library backend is configured/, out)
      assert_no_match(/not a scannable backend/, out,
                      "there is no adapter here to make that claim about — it would be false")
    end

    # THE OTHER DIRECTION, AND WITHOUT IT THE TWO ABOVE ARE SATISFIED BY A MIGRATION THAT DOES
    # NOTHING ANYWHERE. This is the work the migration exists to do, on a backend that can do it.
    test "a scannable backend still does the purge" do
      root = use_fresh_share_library!
      inner = node_under_git

      out = run_migration

      assert_not Node.exists?(inner.id), "the whole point: the row beneath .git is destroyed"
      assert_match(/destroyed 1 node/, out)
    ensure
      FileUtils.remove_entry(root) if root&.exist?
    end

    # A FRESH CLONE, WHICH IS BOTH KNOBS UNSET RATHER THAN ONE. The share CI leg exports
    # LIBRARY_PATH and the other two legs export their own backend's env, so clearing
    # LIBRARY_BACKEND alone leaves all three configured and this file would assert nothing on any
    # of them. Clearing both also keeps the reproduction honest end to end: the factory falls
    # through to its `share` DEFAULT arm, which is the arm whose guard was being skipped.
    def with_no_library_configured
      prior = %w[LIBRARY_BACKEND LIBRARY_PATH].to_h { |k| [ k, ENV[k] ] }
      prior.each_key { |k| ENV[k] = nil }
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end
  end
end
