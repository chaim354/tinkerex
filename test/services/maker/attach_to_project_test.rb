require "test_helper"

module Maker
  # The attach policy, one rule per test, WITHOUT HTTP.
  #
  # THIS FILE IS THE POINT OF THE EXTRACTION. The rules used to live inline in
  # Projects::AttachmentsController#create, where the only way to ask "does a model's file stay
  # put?" was to drive a request — so when #relocate was added it called the move directly, below
  # every rule, and three of them silently did not apply. A rule that can be asked a question
  # directly is a rule the next door can be checked against.
  #
  # PINNED TO CHUNK, like the web tests: the rules are backend-neutral, but the move they gate is
  # Maker::MoveNode's two-door branch, and on share/s3 the port would want a real disk or bucket
  # behind every fixture. The doors themselves are covered per-backend in move_node_test.rb.
  class AttachToProjectTest < ActiveSupport::TestCase
    setup do
      # A real share library, and fixtures that exist on disk -- see test_helper's create_node!
      # for why (§14a: a bare nodes.create! leaves a NULL storage_path, which cannot exist here).
      @root = use_fresh_share_library!
      @user = User.create!(email: "atp-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @lamp = @user.maker_projects.create!(name: "Desk Lamp")
      @bench = @user.maker_projects.create!(name: "Bench")
      @node = create_node!(@user, node_id: "f-1", name: "bracket.stl", kind: "file")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def service(project = @lamp) = Maker::AttachToProject.new(user: @user, project:)

    def lamp_folder = @lamp.ensure_library_folder!(@user)

    # Real SQL round-trips inside the block. Same shape as project_intake_test.rb's helper of the
    # same name: `uncached` so the AR query cache cannot make a repeat measurement read
    # artificially low, schema and transaction bookkeeping excluded so only real work counts.
    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == "SCHEMA" || payload[:cached]
        next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|RELEASE|SAVEPOINT|PRAGMA)/i)
        count += 1
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      end
      count
    end

    # --- #refusal_for: the rules themselves ---------------------------------------

    test "an ordinary unattached file has nothing standing in its way" do
      assert_nil service.refusal_for(@node)
    end

    # A directory has no place in a project folder, and FileLayer::S3#move refuses one outright
    # (movable_file!) — so allowing it would be a policy that works on share/chunk and 422s on s3.
    test "a directory is refused" do
      dir = create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")
      assert_equal :not_a_file, service.refusal_for(dir)
    end

    # THE RULE #relocate USED TO MISS. An imported model is its STL plus instructions plus cover,
    # curated into Models/<slug>/; moving one out guts the folder.
    test "a file that belongs to a model is refused" do
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :model_bundle, service.refusal_for(@node)
    end

    # MEMBERSHIP IS THE ATTACHMENT, NOT THE FOLDER — the rule reads the row, so a file sitting in
    # Models/widget/ without one is an ordinary file, and a member moved out of that folder is
    # still a member. Both directions, because the wrong test (checking the parent) would pass the
    # first half and fail the second.
    test "model membership is the attachment row, not where the bytes sit" do
      model = @user.maker_models.create!(title: "Widget")
      folder = model.ensure_library_folder!(@user)

      stray = create_node!(@user, node_id: "f-stray", name: "stray.stl", kind: "file",
                                  parent_node_id: folder.node_id)
      assert_nil service.refusal_for(stray), "sitting in the folder does not make it a member"

      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :model_bundle, service.refusal_for(@node),
                   "and a member that lives elsewhere is still a member"
    end

    # SCOPED THROUGH THE ATTACHMENTS TABLE, which keys files by a bare node_id string with no FK —
    # so an unscoped lookup would find another user's row naming the same id and refuse (or worse,
    # attach) on the strength of a stranger's model.
    test "another user's model attachment does not claim my file" do
      other = User.create!(email: "atpo-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      other.nodes.create!(node_id: "f-1", name: "theirs.stl", kind: "file") # ids are unique per user, not globally
      other.maker_models.create!(title: "Theirs")
           .file_attachments.create!(user: other, node_id: "f-1", role: "model")

      assert_nil service.refusal_for(@node)
    end

    test "a file another project already claims is refused" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :attached_elsewhere, service.refusal_for(@node)
    end

    test "this project's own attachment is not 'elsewhere'" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_nil service.refusal_for(@node)
    end

    # --- :in_working_tree ---------------------------------------------------------
    #
    # A REPO IN THE LIBRARY IS AN ORDINARY THING AND THE SWEEP USED TO TEAR IT APART. §14f's
    # root-is-inbox rule files every file at a project folder's root by category, so a repo cloned
    # at Projects/<slug>/ lost its README.md to docs/ and its main.py to other/, unattended, every
    # sweep — a delete plus an untracked add as far as git is concerned.
    #
    # UNSCOPED, unlike :attached_elsewhere, and the asymmetry is the point. A refusal here does NOT
    # mean "refuse the attachment": #call returns `relocation: (move(node) if refusal.nil?)`, so it
    # means ATTACH THE ROW AND LEAVE THE BYTES WHERE THEY ARE — the right answer at all four of
    # #refusal_for's callers. :attached_elsewhere needed `within_own_folder:` because its stated
    # reason is positional and stopped applying to one caller; "do not move a file out from under
    # git" has no such exception.
    test "a file inside a working tree is refused, at any depth" do
      repo = create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "d-git", name: ".git", kind: "dir", parent_node_id: "d-repo")
      src = create_node!(@user, node_id: "f-src", name: "main.cpp", kind: "file",
                         parent_node_id: repo.node_id)
      nested = create_node!(@user, node_id: "d-src", name: "src", kind: "dir",
                            parent_node_id: repo.node_id)
      deep = create_node!(@user, node_id: "f-deep", name: "util.cpp", kind: "file",
                          parent_node_id: nested.node_id)

      assert_equal :in_working_tree, service.refusal_for(src)
      assert_equal :in_working_tree, service.refusal_for(deep)
    end

    test "the refusal is NOT scoped by within_own_folder: — it holds for the sweep too" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "d-git", name: ".git", kind: "dir", parent_node_id: "d-repo")
      src = create_node!(@user, node_id: "f-src", name: "main.cpp", kind: "file",
                         parent_node_id: "d-repo")

      assert_equal :in_working_tree, service.refusal_for(src, within_own_folder: true),
                   "ProjectIntake#place passes within_own_folder: true; the repo rule must survive it"
    end

    test "a sibling folder that merely CONTAINS a repo is not itself a working tree" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "d-git", name: ".git", kind: "dir", parent_node_id: "d-repo")

      assert_nil service.refusal_for(@node), "bracket.stl is at the root; the repo is one folder over"
    end

    # A TOMBSTONE IS NOT A WORKING TREE. `present` in the lookup is what makes this true — without
    # it, deleting a repo would freeze its former folder against the sweep forever, with nothing
    # visible anywhere saying why.
    test "a TOMBSTONED .git does not make a folder a working tree" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      marker = create_node!(@user, node_id: "d-git", name: ".git", kind: "dir",
                            parent_node_id: "d-repo")
      src = create_node!(@user, node_id: "f-src", name: "main.cpp", kind: "file",
                         parent_node_id: "d-repo")
      marker.update!(deleted: true)

      assert_nil service.refusal_for(src)
    end

    # A file merely NAMED like git metadata is an ordinary file. This is the segment-vs-prefix
    # distinction Library::OsClutter gets wrong at everyone's peril.
    test ".gitignore is a file, not a marker" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "f-ign", name: ".gitignore", kind: "file",
                   parent_node_id: "d-repo")
      src = create_node!(@user, node_id: "f-src", name: "main.cpp", kind: "file",
                         parent_node_id: "d-repo")

      assert_nil service.refusal_for(src)
    end

    # A FILE named `.git` is not a marker either — only a DIRECTORY is. (A real repo can have a
    # `.git` FILE, in a submodule or a worktree, where it holds a `gitdir:` pointer; treating that
    # as a marker would be right by accident and wrong by construction, since nothing here reads
    # the pointer. Keep the rule "a directory named .git" and let a submodule's own .git dir,
    # wherever it really lives, do the work.)
    test "a FILE named .git is not a marker" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "f-git", name: ".git", kind: "file", parent_node_id: "d-repo")
      src = create_node!(@user, node_id: "f-src", name: "main.cpp", kind: "file",
                         parent_node_id: "d-repo")

      assert_nil service.refusal_for(src)
    end

    # THE COST OF THE RULE IS A PROPERTY WORTH ASSERTING, not trusting: ProjectIntake sweeps every
    # file at one folder's root through this method, so an uncached ancestor walk is two queries
    # per LEVEL per FILE on an unattended 15-minute job.
    #
    # ASSERTED AS "DEPTH IS FREE", WITH NO LITERAL ANYWHERE. A count of zero is impossible here —
    # #refusal_for spends two queries per file on :model_bundle and :attached_elsewhere before it
    # ever reaches this rule — and a literal would pin the sum of all three rules, so it would
    # break the next time an unrelated rule changed. Constancy in N does not discriminate either:
    # an uncached walk is still linear in the file count, so doubling the files doubles the cost
    # whether or not the cache exists. What DOES discriminate is DEPTH: cached, a file four levels
    # down costs exactly what a file one level down costs; uncached, it costs six queries more.
    test "the ancestor walk is cached per parent, so depth costs nothing per file" do
      create_node!(@user, node_id: "d-repo", name: "firmware", kind: "dir")
      create_node!(@user, node_id: "d-git", name: ".git", kind: "dir", parent_node_id: "d-repo")
      create_node!(@user, node_id: "d-a", name: "a", kind: "dir", parent_node_id: "d-repo")
      create_node!(@user, node_id: "d-b", name: "b", kind: "dir", parent_node_id: "d-a")
      create_node!(@user, node_id: "d-c", name: "c", kind: "dir", parent_node_id: "d-b")

      shallow = 5.times.map do |i|
        create_node!(@user, node_id: "f-s#{i}", name: "s#{i}.cpp", kind: "file",
                     parent_node_id: "d-repo")
      end
      deep = 5.times.map do |i|
        create_node!(@user, node_id: "f-d#{i}", name: "d#{i}.cpp", kind: "file",
                     parent_node_id: "d-c")
      end

      policy = service
      policy.refusal_for(shallow.first) # warm each parent's entry
      policy.refusal_for(deep.first)

      shallow_cost = count_queries { shallow.each { |f| policy.refusal_for(f) } }
      deep_cost = count_queries { deep.each { |f| policy.refusal_for(f) } }

      assert_equal shallow_cost, deep_cost,
                   "a file four levels inside the repo cost #{deep_cost} queries against " \
                   "#{shallow_cost} one level in — the ancestor walk is running per file"
    end

    # --- #relocate: the rules, applied ---------------------------------------------

    # THE ENDPOINT FINISHES AN ATTACH, so there has to be one. Without this, a POST to a project
    # the user never attached anything to moved the file in AND minted the project's folder.
    test "relocate refuses when there is no attachment to finish, and creates no folder" do
      assert_equal :not_attached, service(@bench).relocate(@node)
      assert_nil @node.reload.parent_node_id
      assert_nil @bench.reload.folder_node_id
    end

    test "relocate applies every refusal, and moves nothing while doing it" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :model_bundle, service.relocate(@node)
      assert_nil @node.reload.parent_node_id

      model.file_attachments.destroy_all
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :attached_elsewhere, service.relocate(@node)
      assert_nil @node.reload.parent_node_id
    end

    test "relocate moves an attached file under the requested name" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :moved, service.relocate(@node, new_name: "bracket (2).stl")
      @node.reload
      assert_equal lamp_folder.node_id, @node.parent_node_id
      assert_equal "bracket (2).stl", @node.name
      assert_equal "f-1", @node.node_id, "the node_id is what every attachment points at"
    end

    # ONE SYMBOL PER OUTCOME, because the caller words a different sentence for each. :bad_name is
    # separate from :unavailable on purpose — "try again later" is false for a name that can never
    # work, and move_node.rb asked for the split by name.
    test "relocate names each move outcome" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      create_node!(@user, node_id: "f-2", name: "taken.stl", kind: "file",
                          parent_node_id: lamp_folder.node_id)

      assert_equal :conflict, service.relocate(@node, new_name: "taken.stl")
      assert_equal :bad_name, service.relocate(@node, new_name: "../escape.stl")
      assert_equal :bad_name, service.relocate(@node, new_name: [ "a/b.stl" ])
      assert_nil @node.reload.parent_node_id, "none of those may have moved anything"

      assert_equal :moved, service.relocate(@node)
      assert_equal :already_there, service.relocate(@node),
                   "same folder, same name — a no-op the sync engine must not be told about"
    end

    # --- #call: the attach door -----------------------------------------------------

    test "attaching an unattached file creates the row and moves it in" do
      result = service.call(@node)

      assert_equal :moved, result.relocation
      assert result.created
      assert_nil result.model
      assert_equal [ "f-1" ], result.attachments.map(&:node_id)
      assert_equal lamp_folder.node_id, @node.reload.parent_node_id
    end

    # nil, NOT a refusal symbol: "not moved" and "never tried" are different facts, and #create's
    # JSON door reports the second as a present-and-null key.
    test "a refused move reports nil relocation, not the reason" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      result = service.call(@node)

      assert_nil result.relocation
      assert_equal 1, @lamp.file_attachments.count, "…but the attach still happens"
    end

    test "attaching twice creates nothing the second time" do
      service.call(@node)
      result = service.call(@node)

      assert_not result.created, "claiming Created for a row that already existed would be a lie"
      assert_equal 1, @lamp.file_attachments.count
    end

    # THE RACE TASK 9a's FOLLOW-UP CLOSES, ON THIS METHOD SPECIFICALLY — NOT A BUG FIX, and that
    # correction is the point of this comment. The test above covers the ORDINARY already-attached
    # case: a row that existed before #call's find step ran. This one covers the case that shape
    # cannot, by construction: a second writer landing the identical
    # (user, attachable_type, attachable_id, node_id) tuple in the gap between #call's find step
    # finding nothing and its own create actually running. THE FIRST DRAFT OF THIS TASK ASSUMED
    # find_or_create_by! was find_by || create! — the naive shape with no protection for that gap
    # — and reported #call as newly exposed to an uncaught RecordNotUnique the moment Task 9a's
    # unique index existed, the same way Models::AttachmentsController#create and
    # Projects::EntryPhotosController#create genuinely are (both call bare create!, verified
    # separately to still raise). THAT WAS WRONG, caught only by driving this test against the
    # UNCHANGED method and watching it pass: in this Rails version (8.1.3),
    # `find_or_create_by!(attrs, &block) = find_by(attrs) || create_or_find_by!(attrs, &block)` —
    # source-checked directly (ActiveRecord::Relation.instance_method(:find_or_create_by!)
    # .source_location) — so the "not found" fallback ALREADY goes through create_or_find_by!'s
    # own savepoint-and-rescue. #call was never actually broken here. This test pins that fact
    # rather than proving a fix, which is worth keeping precisely because it is not obvious from
    # reading the call site — a future Rails upgrade that reverted find_or_create_by! to its older,
    # naive shape would regress this silently otherwise. The service now spells create_or_find_by!
    # explicitly anyway (see #call's comment for why: one fewer query in the common non-racing
    # case, and the safety no longer depends on unstated Rails-version behavior a reader would have
    # to go and check, the same way this test just had to).
    #
    # with_concurrent_file_attachment (test_helper.rb) is the shared simulation for this and its
    # two siblings (Models::AttachmentsController#create, Projects::EntryPhotosController#create;
    # the current project's addon attach was a third until slice 4 of the 2026-10-08 redesign) —
    # see its own comment for why the obvious #save!-hook approach is wrong here specifically.
    test "#call is safe under a concurrent attach of the same file" do
      result = nil
      assert_nothing_raised do
        with_concurrent_file_attachment do
          result = service.call(@node)
        end
      end

      assert_equal 1, @lamp.file_attachments.where(node_id: "f-1").count,
                   "exactly one row must survive the race — not two, and not zero"
      assert_not result.created,
                 "this request lost the race — it must not claim to have created the row"
      assert_equal "other", result.attachments.first.role,
                   "the returned row must be the WINNER's — the race's own row, not ours"
    end

    # Models::AttachmentsController does not filter by kind, so a dir CAN belong to a model — and
    # #attach_bundle keeps live FILES only, so the triggering node was absent from its own result:
    # "Attached 0 files from Widget." on the HTML door and `undefined method 'node_id' for nil` on
    # the JSON one. Both reproduced before the fix.
    test "a directory that belongs to a model attaches as itself, not as a bundle" do
      dir = create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "d-1", role: "other")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      result = service.call(dir)

      assert_nil result.model, "a dir has nothing to relocate under any rule"
      assert_equal [ "d-1" ], result.attachments.map(&:node_id)
      assert_nil result.relocation
      assert_equal "d-1", result.attachments.first.node_id,
                   "the triggering node must be in its own result — the JSON door reads it"
    end

    test "attaching a model's file brings the whole bundle and moves nothing" do
      model = @user.maker_models.create!(title: "Widget")
      folder = model.ensure_library_folder!(@user)
      %w[widget.stl instructions.pdf cover.png].each_with_index do |name, i|
        create_node!(@user, node_id: "m-#{i}", name:, kind: "file", parent_node_id: folder.node_id)
        model.file_attachments.create!(user: @user, node_id: "m-#{i}", role: "other")
      end

      result = service.call(@user.nodes.find_by(node_id: "m-0"))

      assert_equal :model_bundle, result.relocation
      assert_equal model, result.model
      assert_equal %w[m-0 m-1 m-2], result.attachments.map(&:node_id).sort
      assert_equal folder.node_id, @user.nodes.find_by(node_id: "m-0").parent_node_id
      # The role is derived PER FILE: a bundle is a PDF and a PNG and an STL, so copying the
      # triggering file's role would label the instructions "model".
      assert_equal %w[image instructions model],
                   result.attachments.map(&:role).sort
    end
  end
end
