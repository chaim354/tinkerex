ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# THE SUITE IS HERMETIC BY FIXTURE (§14c), AND bin/ci's share and s3 legs run
# `bin/rails db:test:prepare test` IN ONE PROCESS, which boots development first. development.rb
# defaults ADDON_SOURCE_PATH to a sibling `tinkerex-addons` checkout, and ENV outlives the boot —
# so on any machine with that sibling cloned, /tools listed the REAL addons and
# cohesion_vocabulary_test's empty-state assertion failed (main included, reproduced 2026-10-08).
# The runners have no sibling, which is why CI never saw it. Only that exact default is dropped: a
# value a test or a developer set on purpose is left alone.
dev_addon_default = File.expand_path("../../tinkerex-addons/addons", __dir__)
ENV.delete("ADDON_SOURCE_PATH") if ENV["ADDON_SOURCE_PATH"] == dev_addon_default

# Devise registers its `mappings` (used by Devise::Mailer to resolve a record's scope) while
# DRAWING the routes (`devise_for :users`). Routes load lazily, so in a parallel test worker a
# Devise mailer can fire (e.g. a confirmation email when a confirmable account is created)
# BEFORE that worker has drawn its routes → an intermittent "Could not find a valid mapping"
# from Devise::Mailers::Helpers#find_scope!. Force the routes (and thus the mappings) to be
# loaded up front so the mailer can always resolve its scope.
Rails.application.reload_routes_unless_loaded if Rails.application.respond_to?(:reload_routes_unless_loaded)
Rails.application.routes.url_helpers # touch to ensure routes are drawn

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers. Parallel workers each need their
    # own database; with the SQLite default that's a free per-worker file, but when an
    # external Postgres is selected via DATABASE_URL (managed/SaaS validation) the
    # per-worker DB-name derivation stalls, so run single-process there. Set
    # PARALLEL_WORKERS=1 to force single-process anywhere.
    if ENV["DATABASE_URL"].to_s.start_with?("postgres")
      parallelize(workers: 1)
    else
      parallelize(workers: :number_of_processors)
    end

    # Each parallel worker gets its OWN database — `ls storage/` shows `test.sqlite3_0` …
    # `test.sqlite3_9`, one per worker, exactly as the comment above says Rails does. (This
    # comment used to claim the opposite, "each worker shares one DB", and it was cited as the
    # explanation for an intermittent `SQLite3::BusyException` that a shared file would explain
    # and per-worker files cannot — see the record (CLAUDE.md §11), "The intermittent".) The chunk dir below
    # is still needed, and for the reason it gives rather than that one: the MemoryChunkStore
    # writes real files to tmp/dev-chunks that SURVIVE a transaction rollback, so DB isolation
    # buys nothing there. A keyspace-enumerating operation (Sync::ChunkReaper) in one worker would
    # otherwise see objects another worker — or an earlier, rolled-back test reusing an
    # autoincrement user id — left behind. Give each worker its own chunk dir so the storage
    # keyspace is as isolated as the DB already is. (Single-process runs leave it unset
    # → base dir, which is fine.)
    parallelize_setup do |worker|
      ENV["CHUNK_STORE_WORKER"] = worker.to_s
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # RESET THE RATE-LIMIT COUNTER BETWEEN TESTS.
    #
    # The auth throttles (Users::SessionsController and friends) key on `request.remote_ip`, and
    # EVERY integration test in the suite is 127.0.0.1 — so without this, one shared counter is
    # spent across an entire worker's tests and the sign-in in a later test's `setup` is
    # throttled. That does not fail as "you have been rate limited": the test simply is not
    # signed in, so it fails as `302 redirect to /users/sign_in`, or as a missing `<h1>`, in a
    # test that has nothing to do with auth. Measured, adding the throttles without this:
    # **306 failures / 20 errors** across the suite.
    #
    # This is test ISOLATION, not a weakened throttle. The limits stay live in the test env —
    # `config.action_controller.cache_store` is a real MemoryStore precisely so they can fire —
    # and auth_throttle_test drives each one past its limit inside a single test, which this
    # per-test clear does not touch.
    setup { ActionController::Base.cache_store.clear }

    # Run a block on a box that has no SVG rasterizer.
    #
    # THE ONLY WAY A TOOLCHAIN GATE ASSERTS ANYTHING. Asked plainly on a box that HAS resvg,
    # every `available?` is true however it is implemented — so a test about what happens
    # WITHOUT the binary has to create that box. Stubs the predicate rather than pointing
    # RESVG_BIN at a bogus path: same answer, no ENV to leak into the next test in this worker.
    #
    # Shared rather than copied. Three suites need it (lbrn2, geometry, the preview job), and a
    # per-file copy is how one of them silently stops stubbing the thing it means to.
    #
    # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist in
    # this suite (requiring it is a LoadError) -- the same reason lbrn2_test's parse-count guard
    # and `with_concurrent_file_attachment` below rebind methods this way. `original` is an
    # UnboundMethod and `define_method` takes one directly, so the ensure reinstalls the exact
    # original implementation rather than hoping something else is underneath it.
    def without_svg_rasterizer
      mod = Maker::Previews::SvgRasterizer.singleton_class
      original = mod.instance_method(:available?)
      mod.define_method(:available?) { false }
      yield
    ensure
      mod.define_method(:available?, original)
    end

    # Pin the FileLayer backend for the duration of one test.
    #
    # A test whose FIXTURES are chunk-shaped (ManifestChunk rows, Storage::ChunkStore blobs) is a
    # chunk test, and must SAY so: FileLayer.current otherwise reads the ambient LIBRARY_BACKEND,
    # so the whole suite run under LIBRARY_BACKEND=share pointed those tests at the Share adapter,
    # which looked for the fixtures' bytes on a disk that has none. The failure was the honest
    # signal ("this test depends on the ambient backend"), not a bug in either adapter — and the
    # ci.yml `test-share-backend` leg exists to keep catching it.
    #
    # Call it in setup. The teardown below restores the prior value whether or not it was called,
    # so nothing leaks into the next test in the worker.
    # SEEDS A FILE THROUGH THE PORT-WRITABLE DOOR, FOR ANY TEST THAT JUST NEEDS A FILE TO EXIST.
    #
    # ONE DEFINITION, deliberately. Before Arc D Part 2 this was an `upload` helper copied between
    # files_flow_test.rb and lbrn_geometry_test.rb -- the second one's own comment said "copied
    # from files_flow_test.rb's own helper rather than reinvented" -- and both drove the presigned
    # two-phase chain (hash -> begin_upload -> PUT -> finalize_upload). That chain is
    # `syncable`-gated: with embedded chunk retired it answers 501 on share, and its body tells the
    # caller to "Upload through POST /files" instead, which is what this does.
    #
    # THE NODE ID COMES OUT OF THE Location HEADER. #create answers `redirect_to
    # file_path(info.node_id)`, so the id is already on the wire -- exact, and it cannot be
    # confused by the several suites that upload the same NAME twice on purpose (the clobber and
    # replace paths). Looking the node up by name was tried first and is wrong for a second reason
    # besides ambiguity: a REFUSED upload also redirects, to the index, so the lookup reported
    # "not found" for a write that was rejected, several frames from the assertion that cared.
    # Hence the explicit Location shape check and the flash in the message -- that is how the
    # "already exists" clobber refusal behind a whole suite's failures was found at all.
    def port_upload(name, bytes, parent_node_id: nil)
      body = { file: Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream",
                                                  original_filename: name) }
      body[:parent_node_id] = parent_node_id if parent_node_id
      post files_path, params: body
      assert_response :redirect, "POST /files failed: #{response.body[0, 300]}"
      loc = response.headers["Location"].to_s
      assert_match(%r{/files/[^/]+\z}, loc,
                   "upload of #{name.inspect} was refused: #{flash[:alert] || flash[:notice]}")
      loc.split("/").last
    end

    # A NODE ROW **PLUS THE FILE IT CLAIMS TO BE**, for suites whose fixtures used to be rows alone.
    #
    # CLAUDE.md §14a records the trap this exists to close, in as many words: "a test fixture built
    # with nodes.create! has a NULL storage_path, which cannot exist on share/s3". On embedded
    # chunk that was harmless -- a node IS a row there and a move is a changelog entry -- so whole
    # suites seeded with bare `nodes.create!` and pinned chunk to match. On share a move resolves
    # through storage_path and renames an ACTUAL FILE, so those fixtures produce moves that fail on
    # a file that was never there.
    #
    # NO-OPS WHEN THERE IS NO @root, deliberately, so a suite that has not opted into a real share
    # library keeps exactly its old behaviour rather than silently half-materialising. Pair it with
    # `@root = use_fresh_share_library!` in setup; that helper cleans up after itself.
    def create_node!(user, **attrs)
      node = user.nodes.create!(**attrs)
      root = defined?(@root) ? @root : nil
      return node unless root

      parent = attrs[:parent_node_id] && user.nodes.find_by(node_id: attrs[:parent_node_id])
      rel = parent&.storage_path.present? ? File.join(parent.storage_path, node.name) : node.name
      path = root.join(rel)
      if node.kind == "dir"
        path.mkpath
      else
        path.dirname.mkpath
        # Only ENAMETOOLONG is tolerated: some suites deliberately build a name the filesystem
        # cannot hold, and the ROW is what those tests need. Anything wider would let a genuinely
        # broken fixture look like a passing test.
        begin
          path.binwrite("x")
        rescue Errno::ENAMETOOLONG
          nil
        end
      end
      node.update!(storage_path: rel)
      node
    end

    # A PROJECT FOLDER WITHOUT THE PORT. Writes the two dir ROWS (`Projects/`, `Projects/<slug>`)
    # and points folder_node_id at the second, so Maker::Project#ensure_library_folder! -- which the
    # project page and Home call best-effort for their upload controls -- finds a live dir and
    # returns WITHOUT a mkdir. That is what lets a test about what a page READS from a folder run
    # on whichever backend the leg supplies: through the port, the same fixture is a real mkdir,
    # which on the s3 leg is a Forbidden against the stub bucket and on chunk_remote provisions a
    # sync-server library per email (eleven and two errors respectively, 2026-09-04). A test that
    # goes on to upload or move BYTES still needs use_fresh_share_library! and create_node!.
    def project_folder_rows!(user, project)
      projects = user.nodes.find_by(name: Maker::ProjectFolders::ROOT, kind: "dir", parent_node_id: nil, deleted: false) ||
                 user.nodes.create!(node_id: SecureRandom.uuid, name: Maker::ProjectFolders::ROOT, kind: "dir",
                                    mtime: 1, size: 0)
      folder = user.nodes.create!(node_id: SecureRandom.uuid, name: project.slug, kind: "dir",
                                  parent_node_id: projects.node_id, mtime: 1, size: 0)
      project.update_column(:folder_node_id, folder.node_id)
      folder
    end

    # A LIBRARY ROOT THAT IS FRESH FOR THIS ONE TEST. The ambient LIBRARY_PATH is a single tmpdir
    # for the whole run while the database rolls back per test, so files outlive the rows that
    # named them and Share's clobber refusal (§14a) rejects the second test to write a given name.
    # `FileLayer.current =` rather than pin_file_layer_backend for the reason share_delivery_test.rb
    # records: the pin rebuilds from ENV and would additionally need LIBRARY_PATH, which its
    # teardown does not restore.
    #
    # THE HELPER OWNS THE TEARDOWN OF EVERY DIRECTORY IT MINTS, and it has to. A direct assignment
    # sets no @file_layer_backend_pinned, so this used to be the CALLER's obligation -- and the
    # obligation was silently unmeetable: rescan_test.rb REASSIGNS `@root` to a second tmpdir
    # mid-test, so its (correct-looking) teardown removed the second directory and dropped the
    # first, leaking five per run out of the eleven a full suite leaked. 2,817 stale
    # `test-library*` directories on the build box when it was measured.
    #
    # RECORDED IN `@fresh_share_library_roots`, DELIBERATELY NOT IN `@root`: `@root` is the ivar 36
    # callers assign this to and are free to reassign, which is exactly how the leak happened. An
    # ARRAY rather than one ivar for the same reason one level down -- a second call in one test
    # would otherwise drop the first directory on the floor. Callers keep `@root = ...` unchanged;
    # create_node! above still reads @root.
    #
    # EXISTING PER-FILE TEARDOWNS STAY CORRECT AND BECOME REDUNDANT, not wrong: ActiveSupport
    # registers `teardown` as an :after callback and :after callbacks run in reverse declaration
    # order, so a subclass's block runs FIRST (probed, not assumed) and the shared one below finds
    # the directory already gone -- `remove_entry` is guarded on `exist?` and `FileLayer.reset!` is
    # idempotent. Do not sweep them out on a pattern match: fifteen of them own a `@root` this
    # helper never minted, and deleting theirs converts a cleanup into a leak.
    def use_fresh_share_library!
      root = Pathname.new(Dir.mktmpdir("test-library"))
      (@fresh_share_library_roots ||= []) << root
      FileLayer.current = FileLayer::Share.new(root: root.to_s)
      root
    end

    def pin_file_layer_backend(name)
      # Capture the prior value ONCE. A second call in the same test would otherwise overwrite it
      # with the first pin's value, and teardown would "restore" that into the next test in this
      # worker — a leak that no test would report.
      @file_layer_backend_prior = ENV["LIBRARY_BACKEND"] unless @file_layer_backend_pinned
      @file_layer_backend_pinned = true
      ENV["LIBRARY_BACKEND"] = name
      FileLayer.reset!
    end

    teardown do
      if @file_layer_backend_pinned
        ENV["LIBRARY_BACKEND"] = @file_layer_backend_prior
        FileLayer.reset!
      end
      if @fresh_share_library_roots
        # The reset is load-bearing, and NOT covered by the branch above: use_fresh_share_library!
        # assigns FileLayer.current directly and sets no @file_layer_backend_pinned, so without it
        # a Share adapter pointing at a directory this block is about to delete leaks into the next
        # test in this forked worker -- where it surfaces as the KeyError previews_test.rb describes
        # rather than as anything naming this helper.
        FileLayer.reset!
        @fresh_share_library_roots.each { |root| FileUtils.remove_entry(root) if root.exist? }
      end
    end

    # Simulates a genuinely CONCURRENT writer landing the identical (user, attachable_type,
    # attachable_id, node_id) row an instant before this block's own create_or_find_by! attempts
    # to insert it — the race Task 9a's follow-up (RecordNotUnique -> "treat it as already
    # attached") closes on AttachToProject#call, Models::AttachmentsController#create,
    # Projects::EntryPhotosController#create and
    # CurrentProject#attach_addon_files_to_current_project. Shared here rather than duplicated
    # per file (unlike e.g. project_intake_test.rb's with_broken_move) because it is genuinely easy
    # to get subtly wrong, and it very nearly was — see below.
    #
    # TAKES NO user:/attachable:/node_id: — it does not need to be TOLD the tuple, it READS it off
    # the intercepted call. `create!(attributes.merge(role:))`, called on `self` (the SAME
    # association-scoped relation create_or_find_by! was itself called on, e.g.
    # @project.file_attachments), inherits that association's attachable_type/attachable_id scope
    # exactly the way an ordinary create! on it would — and `attributes` already carries `user:`
    # and `node_id:`, since those are literally what the real call passed. This is WHY it can also
    # cover CurrentProject#attach_addon_files_to_current_project's multi-file loop with no changes:
    # that method calls create_or_find_by! once per output file with a node_id chosen at RUNTIME
    # (the addon's generated files), which a hook parameterized with one fixed node_id up front
    # could not have raced against without first knowing which id to name.
    #
    # HOOKS ActiveRecord::Relation#create_or_find_by! ITSELF, ONE CALL FRAME OUTSIDE it — NOT
    # Maker::FileAttachment#save!, which was tried first and is WRONG for this specific method, in
    # a way worth recording so nobody reaches for it again. create_or_find_by! wraps its own create
    # attempt in `transaction(requires_new: true)` — a SAVEPOINT — so a write performed from
    # INSIDE that call frame (which is all a #save! hook can reach, since save! only runs once
    # create_or_find_by! has already opened its savepoint) is rolled back TOGETHER WITH the failed
    # insert the instant it conflicts, and never survives to be found. The symptom was
    # ActiveRecord::RecordNotFound out of create_or_find_by!'s own rescue: the "concurrent" row
    # really was inserted, then vanished in the very same rollback as the row that lost the race,
    # because both were inside the identical savepoint — a race test that looked like it was
    # reproducing the bug and was actually just breaking the fix's own rescue path. Hooking the
    # CALLER's call to create_or_find_by! avoids this: the injected row lands in whatever
    # transaction is ALREADY open when this runs (the wrapping test transaction here; a real
    # request's ambient transaction, if any, in production) — one level UP from the savepoint
    # create_or_find_by! is about to open — so it is untouched when that savepoint rolls back.
    #
    # GATED ON `klass == Maker::FileAttachment` because Relation#create_or_find_by! is shared by
    # EVERY model in the app (Devise's own queries included) — patched globally for the duration of
    # the block, but inert everywhere else. GATED ON firing ONCE so create_or_find_by!'s OWN
    # internal create attempt (a DIFFERENT method, create!, so it does not re-enter this hook
    # anyway) cannot retrigger it, and so a caller that legitimately calls create_or_find_by! more
    # than once inside the block only races the first.
    #
    # RESTORED VIA define_method(:create_or_find_by!, original), NOT remove_method — a second
    # subtlety that cost as much debugging as the first. create_or_find_by! is defined DIRECTLY on
    # Relation (verified: Relation.instance_method(:create_or_find_by!).owner ==
    # ActiveRecord::Relation), not inherited from an included module, so remove_method does not
    # "uncover" an ancestor implementation the way it would for e.g. Maker::FileAttachment#save!
    # (see project_intake_test.rb's race test) — it deletes the method OUTRIGHT. The very next
    # unrelated create_or_find_by! call anywhere in the process then hit Ruby's method_missing on
    # Relation, which delegates to the model class, which (Querying) delegates back to `all.
    # create_or_find_by!` — a FRESH Relation, ALSO missing the method — forever: SystemStackError,
    # and it surfaced on the NEXT test in the file, not this one, because the corruption outlives
    # a single test's `ensure` block once it happens. `original` is an UnboundMethod, and
    # `define_method` accepts one directly in place of a block — reinstalling the exact original
    # implementation rather than merely hoping something else is underneath it.
    #
    # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist in
    # this suite (requiring it is a LoadError).
    def with_concurrent_file_attachment(role: "other")
      raced = false
      original = ActiveRecord::Relation.instance_method(:create_or_find_by!)
      ActiveRecord::Relation.define_method(:create_or_find_by!) do |attributes, &block|
        if !raced && klass == Maker::FileAttachment
          raced = true
          create!(attributes.merge(role:))
        end
        original.bind(self).call(attributes, &block)
      end
      yield
    ensure
      ActiveRecord::Relation.define_method(:create_or_find_by!, original)
    end

    # Add more helper methods to be used by all tests here...
  end
end

module ActionDispatch
  class IntegrationTest
    # Bootstrap a CONFIRMED account + its first device DIRECTLY (no HTTP), returning the same
    # JSON-shaped payload the removed POST /v1/auth/register endpoint did. Device enrollment
    # in production now goes through POST /v1/devices/login (email+password via Devise); these
    # sync/maker integration tests don't exercise the human-auth bootstrap, so they build the
    # user + device directly (CLAUDE.md: tests build users/devices directly). Keys are strings
    # to match the old `JSON.parse(response.body)` return.
    def bootstrap_account(email:, device_name: "device")
      user = User.find_by(email:) ||
             User.create!(email:, confirmed_at: Time.current, omniauth_signup: true)
      device = Device.register!(user:, name: device_name)
      {
        "user_id" => user.id, "device_id" => device.id,
        "device_token" => device.plaintext_token, "head_seq" => user.head_seq
      }
    end

    # Token-only convenience for the many helpers that returned just the device token.
    def bootstrap_token(email:, device_name: "device")
      bootstrap_account(email:, device_name:)["device_token"]
    end

    # THE CURRENT PROJECT, READ FROM WHICHEVER STORE IS AUTHORITATIVE (slice 0, 2026-09-10).
    #
    # Ten assertions across three suites read `session[:current_project_id]` directly. That was the
    # storage, not the behaviour, and when the pointer moved onto the user row every one of them
    # went red while the feature worked perfectly — a test pinned to an implementation detail.
    # `users.remember_current_project` now decides which store answers, so asking through this
    # helper keeps a test true under BOTH settings and says what it means.
    def current_project_id_for(user)
      user.reload.remember_current_project ? user.current_project_id : session[:current_project_id]
    end
  end
end
