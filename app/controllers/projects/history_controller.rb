module Projects
  # ONE PROJECT'S GIT HISTORY, read-only: the commits the sweep recorded, and — for one file at a
  # time — the versions of that file with a rendered tile beside each.
  #
  # TWO SURFACES, ONE SET OF STATES. `#show` is the panel above; `#compare` puts two versions of one
  # file side by side, as a LINE DIFF where the file is tracked as content and as an A/B slider over
  # two renders where it is a pointer (`Comparison`). Both resolve the four states below through
  # `#resolve`, because they are the same four facts about the same repository — a second copy of
  # that mapping is how two pages come to describe one failure differently.
  #
  # FOUR STATES, AND THE POINT OF THE PAGE IS THAT THEY NEVER RENDER ALIKE (§14a):
  #
  #   :ok            there are commits, and they are listed.
  #   :empty         this project has genuinely never been committed. THE ORDINARY CASE, not an
  #                  error: every project created before the feature shipped is here, and so is
  #                  every project whose files have not settled for a full scan interval yet
  #                  (docs/invariants/git-tracked-projects.md — settle detection costs one tick).
  #                  500ing on it is how a feature gets switched off in production.
  #   :unreachable   FileLayer::FetchError — the RETRYABLE answer, an unmounted share or a creds
  #                  blip. Rendering "you have no history" for it tells the maker their history is
  #                  gone when the NAS is merely asleep. §14a states the rule outright: never let a
  #                  recoverable-looking state and a permanent one render identically.
  #   :unavailable   FileLayer::NotFound — the TERMINAL answer. Reachable here for one real reason:
  #                  Share#repo_data_dir resolves through the project FOLDER, so a folder that was
  #                  deleted or renamed on the NAS raises rather than answering a path. Terminal
  #                  and permanent, so it must not wear the retryable wording either.
  #
  # NOTHING IS OPENED UNTIL THE INDEX SAYS THERE IS SOMETHING TO OPEN, and that early return is
  # load-bearing rather than an optimisation. `Maker::Git::Repo#hydrate!` MINTS `.git`, and an
  # empty `.git` is not inert — it is the marker `Maker::AttachToProject`'s `:in_working_tree`
  # reads, so minting one from a READ would switch §14f's intake filing off for that project,
  # silently, at the next scan, nowhere near this request. `Maker::Git::ProjectCommit#call!` and
  # `Maker::Git::VersionHistory#for_path` each return early for exactly this reason; this is the
  # third door and it has to do the same. `Maker::GitRepo` is an INDEX, never a source of truth,
  # which is exactly the right strength for a "is there anything to show" question and would be
  # the wrong strength for a destructive one.
  class HistoryController < ApplicationController
    # ONE PAGE OF COMMITS. Deliberately NOT `VersionHistory::LOG_LIMIT` (500): that number bounds
    # how far back ONE FILE's versions are looked for, where this one bounds how many rows a human
    # is asked to scroll. Sharing it would tie a rendering decision to a walk-depth decision, and
    # the next person to change either would silently change the other.
    COMMIT_LIMIT = 100

    # HOW MANY MISSING RENDER ROWS ONE REQUEST MAY MINT, in the spirit of
    # `Maker::Previews::ThumbnailMap::BACKFILL_LIMIT`: a file with 400 recorded versions must not
    # turn one page view into 400 inserts and 400 enqueued jobs. Self-healing across renders —
    # the next open mints the next batch.
    MINT_LIMIT = 50

    # A CAP ON THE DESCENT in `#node_at`, the same backstop and the same number as
    # `Maker::AttachToProject::MAX_ANCESTOR_WALK` and `Maker::Git::ProjectCommit::MAX_DEPTH`:
    # `parent_node_id` is a plain string column with no foreign key, so a cycle is representable,
    # and this walks a client-supplied path. Two different caps on the same tree would be two
    # different claims about how deep a library can get.
    MAX_DEPTH = Maker::AttachToProject::MAX_ANCESTOR_WALK

    # What one row of the version strip renders. A VALUE OBJECT rather than three parallel arrays,
    # and `state` is resolved HERE rather than in the partial because the resolution has a rule the
    # view must not be trusted to re-derive — see `#tile_state`.
    Tile = Data.define(:version, :state, :preview) do
      # THE SENTENCE FOR `state`, WRITTEN ONCE FOR BOTH SURFACES. The version strip and the compare
      # panel describe the same five states, and §14a's rule is that two different facts never wear
      # one sentence — "not kept" (the storage never retained these bytes) and "failed" (a bug)
      # being the pair that matters most. A second copy in a second template is exactly how one of
      # them quietly becomes the other, and neither template could tell.
      #
      # HERE RATHER THAN IN A HELPER for the same reason `#tile_state` resolves `state` here: the
      # rule belongs beside the resolution, not beside the markup.
      def label
        case state
        when "ready" then "Rendered"
        when "pending" then "Rendering…"
        when "not_kept" then "Not kept — this storage keeps no superseded copies"
        when "text" then "Text, stored in full"
        when "unsupported" then "No preview for this format"
        else "Preview failed"
        end
      end

      def ready? = state == "ready" && preview.present?
    end

    # WHAT #compare RESOLVED TO, and `kind` is the whole reason this feature is two surfaces rather
    # than one. A line diff of a STEP file is worthless — the bytes are a CAD kernel's
    # serialisation, and a diff of them says nothing a maker can act on — while two renders side
    # by side say everything. So:
    #
    #   :text    the file is tracked as CONTENT, so both versions' bytes are in the repository and
    #            `diff` holds a `Maker::Git::TextDiff::Result`.
    #   :visual  the file is tracked as a POINTER. `diff` is nil and the two tiles' cached renders
    #            are compared instead, behind the `version-compare` Stimulus controller.
    #
    # THE SPLIT IS `Maker::Git::Tracking.mode_for`, NEVER "do these bytes look like text". That is
    # the same question the COMMIT path already answered for this file, and asking it twice with two
    # rules is how the two surfaces come to disagree about one file — a pointer whose bytes happen
    # to be ASCII (an ASCII STL, a G-code export the classifier calls a model) would get a text diff
    # of two content HASHES, which is noise wearing a diff's clothes.
    #
    # `from`/`to` ARE TILES, NOT VERSIONS, because the visual half needs the cached render that
    # `#load_strip` already resolved and a second lookup per side is the N+1 the strip's own single
    # query exists to avoid.
    Comparison = Data.define(:kind, :from, :to, :diff)

    def show
      set_project_and_path
      @commits = []
      @tiles = []
      @state = resolve { load_history }
    end

    # TWO VERSIONS OF ONE FILE, SIDE BY SIDE. A SEPARATE ACTION rather than a panel bolted onto
    # #show: a comparison is a linkable thing (the two commits are in the query string), and two
    # full-width renders under a 100-row commit list would be neither.
    #
    # IT SHARES #show'S FOUR PAGE STATES EXACTLY, through `#resolve` — an unmounted share must not
    # read as "you have no history" on this page either, and writing the mapping out twice is how
    # two pages come to disagree about one failure.
    def compare
      set_project_and_path
      @tiles = []
      @comparison = nil
      @state = resolve { load_comparison }
    end

    private

    # BOTH ACTIONS TAKE THE SAME TWO PARAMETERS AND MUST TREAT THEM IDENTICALLY — the compare page
    # hands `@path` to `Maker::Git::Repo#blob_at`, so a second, laxer reading of it here would put
    # `#clean_path`'s refusal on one door and not the other.
    def set_project_and_path
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      @path = clean_path(params[:path])
    end

    # THE FOUR PAGE STATES, RESOLVED ONCE FOR BOTH ACTIONS. The controller header argues each; what
    # this method adds is that there is ONE mapping from a port failure to a sentence.
    #
    # THE `never_committed?` GUARD IS HERE SO NEITHER ACTION CAN FORGET IT. `hydrate!` MINTS `.git`,
    # and that directory is the marker `Maker::AttachToProject`'s `:in_working_tree` reads — so a
    # READ that opens the repository switches §14f's intake filing off for that project, silently,
    # at the next scan, nowhere near this request. A second door is exactly how such a guard gets
    # lost, which is why the door is shared rather than copied.
    def resolve
      return :empty if never_committed?

      yield
    rescue FileLayer::FetchError
      :unreachable
    rescue FileLayer::NotFound
      :unavailable
    rescue Maker::Git::Repo::UnmanagedRepository
      # A REPOSITORY THIS APP DID NOT CREATE, WHERE ONE OF OURS USED TO BE. Reachable in one
      # narrow way: the project had our repo (hence a `maker_git_repos` row, hence
      # `never_committed?` is false and the guard above lets us through), and the maker has since
      # replaced its `.git` with a clone of their own. `Maker::Git::Repo` refuses to open it --
      # correctly, that is tinkerex#170 -- and without this arm the refusal reaches the browser as
      # a 500 on an ordinary page view.
      #
      # A FIFTH STATE RATHER THAN FOLDING IT INTO `:unavailable`, for the reason the other four
      # exist: this one is neither missing nor retryable, nothing is wrong with the library, and
      # the only action that resolves it is the maker's. Saying "your library folder is missing"
      # would send them looking for a fault that is not there.
      :unmanaged
    end

    def load_history
      @commits = Maker::Git::Repo.for(@project).hydrate!.log(limit: COMMIT_LIMIT)
      # THE INDEX CAN BE STALE OR AHEAD OF THE REPOSITORY — `Maker::GitRepo`'s own header says so —
      # so the walk gets the last word. A row naming a head the repository no longer has is the
      # empty state, not a crash.
      return :empty if @commits.empty?

      load_strip if @path
      :ok
    end

    # THE COMPARE PAGE'S OWN LOAD. It needs the version strip and NOT the commit list: the strip is
    # what the picker's options come from and what the visual half's renders hang off, where a
    # hundred rows of unrelated commits are noise on a page about two of them.
    #
    # ONE REPO INSTANCE, REUSED FOR THE BLOB READS. `Maker::Git::VersionHistory` builds its own
    # inside `#load_strip`, as #show's path already does; on `share` the repository is operated on
    # in place, so hydrating twice re-reads nothing.
    def load_comparison
      repo = Maker::Git::Repo.for(@project).hydrate!
      return :empty if repo.log(limit: 1).empty?

      load_strip if @path
      @comparison = build_comparison(repo)
      :ok
    end

    # NIL IS THE IDLE PANEL, and it covers three ordinary situations rather than an error: no file
    # chosen, a file with fewer than two recorded versions, and a path with nothing behind it.
    def build_comparison(repo)
      return nil if @path.blank? || @tiles.size < 2

      from, to = selected_pair
      return nil if from.nil? || to.nil?

      return Comparison.new(kind: :visual, from:, to:, diff: nil) unless content_tracked?

      Comparison.new(kind: :text, from:, to:, diff: diff_between(repo, from, to))
    end

    def content_tracked? = Maker::Git::Tracking.mode_for(File.basename(@path)) == :content

    # WHICH TWO VERSIONS, AND A CALLER-SUPPLIED OID NEVER REACHES GIT. Each side is looked up in the
    # version list this request just built; an oid that is not in it selects nothing and the default
    # stands. That is what keeps `#diff_between`'s `blob_at` calls addressed only to commits we
    # recorded — the same "reject, never resolve" direction `#clean_path` takes one method down,
    # arrived at differently because this value is a SELECTION rather than a path.
    #
    # THE DEFAULT IS THE TWO NEWEST, so the page is useful on first open with no parameters at all.
    # `@tiles` is newest-first, so the OLDER of the pair is `[1]` — getting that backwards renders
    # every diff inside out, and reads as plausible.
    #
    # THE SAME VERSION ON BOTH SIDES IS ALLOWED. It is an empty diff and says so; silently
    # substituting a different pair would answer a question the user did not ask.
    def selected_pair
      by_oid = @tiles.index_by { |tile| tile.version.oid }
      picked = params[:compare].respond_to?(:permit) ? params[:compare].permit(:from, :to) : {}
      [ by_oid[picked[:from].to_s] || @tiles[1], by_oid[picked[:to].to_s] || @tiles[0] ]
    end

    # NO `.ptr` SUFFIX HERE, AND ADDING ONE WOULD BREAK EVERY TEXT DIFF. That suffix is a POINTER
    # storage detail `Maker::Git::VersionHistory#for_path` applies for the pointer mode only, and
    # this method runs behind `#content_tracked?`, where the bytes are committed at the plain path.
    #
    # THE RESCUE IS NARROW AND MUST NOT BE LEFT TO `#resolve`. A `FileLayer::NotFound` reaching the
    # outer handler renders "this project's library folder is missing", which would be false: the
    # folder is fine and one blob is not in one commit. §14a's rule that two different states never
    # wear one sentence binds inside a page as well as between pages.
    def diff_between(repo, from, to)
      Maker::Git::TextDiff.between(
        before: repo.blob_at(oid: from.version.oid, path: @path),
        after: repo.blob_at(oid: to.version.oid, path: @path)
      )
    rescue FileLayer::NotFound
      Maker::Git::TextDiff.missing
    end

    # `head_oid` BLANK, NOT "no row": a row is written by `Repo#commit!` and only ever with a head,
    # but a blank one would sail past a bare `.nil?` check and hydrate.
    def never_committed? = Maker::GitRepo.find_by(project: @project)&.head_oid.blank?

    # ONE FILE'S VERSIONS, PLUS ONE LOOKUP OF EVERY CACHED RENDER FOR THEM.
    #
    # THE LOCAL IS `recorded`, NOT THE OBVIOUS `versions`, AND THAT IS NOT STYLE. `test/
    # architecture_invariants_test.rb`'s seam guard matches `ENGINE_ASSOCIATIONS` as a Ripper
    # `:on_ident` — `versions` is one of the eight `has_many` names the retired engine tables were
    # reached through (§5), and the guard is deliberately blind to whether the identifier is a
    # local or a receiver, because `user.versions.find_by(...)` emits no constant token for a
    # const-only check to catch. Naming a local `versions` therefore fails `bin/ci` with a message
    # about the sync engine. Renaming it back is a red build, not a cleanup.
    #
    # THE PREVIEW LOOKUP IS ONE QUERY FOR THE WHOLE STRIP AND MUST STAY THAT WAY. A `find_by` per
    # version is invisible on a two-commit fixture and linear on a real project's history — the
    # exact shape `test/integration/web/page_query_budget_test.rb` exists to catch, and the one
    # mutation-checked for this page.
    #
    # KEYED ON `content_token` ALONE ON THE WAY OUT because that is what the tiles hold; the WHERE
    # additionally names project and filename, which is the selective, index-leading half of
    # `idx_maker_version_previews_unique`. `node_id` is deliberately NOT in the WHERE: a file that
    # was deleted and restored carries the same node_id, but one that was replaced does not, and a
    # render is keyed on the CONTENT (see the migration). Renders survive that; the strip does not
    # need to.
    def load_strip
      recorded = Maker::Git::VersionHistory.new(project: @project).for_path(@path)
      return if recorded.empty?

      previews = Maker::VersionPreview
                 .where(project_id: @project.id, source_filename: File.basename(@path))
                 .where(content_token: recorded.filter_map(&:content_token).uniq)
                 .index_by(&:content_token)
      previews = mint_missing(recorded, previews)
      @tiles = recorded.map do |v|
        Tile.new(version: v, state: tile_state(v, previews[v.content_token]),
                 preview: previews[v.content_token])
      end
    end

    # WHICH TILE THIS VERSION GETS, and the first branch is the one a reader is most likely to
    # "simplify" away. A CONTENT version's bytes are IN the repository, so there is nothing for the
    # byte store to have kept or lost and nothing for `Maker::RenderVersionPreviewJob` to fetch —
    # its `content_token` is the COMMIT OID, which no `FileLayer#read` can resolve. Folding it into
    # the pointer path mints a row the job can only ever mark `not_kept`, so a text file's history
    # would render as permanently lost content while the bytes sit in the commit.
    def tile_state(version, preview)
      return "text" unless version.pointer?
      return "not_kept" unless version.content_available?

      preview&.state || "pending"
    end

    # THE ONE SANCTIONED MINTING SITE. `Maker::VersionPreview`'s own header names it: rows are
    # created when someone opens History, and NOTHING on the save path, the scan path or the commit
    # path may create one — eager generation per save IS §14b's leak, spelled with a new table's
    # name on it.
    #
    # ONLY FOR A VERSION THE STORE CAN STILL RESOLVE. A `not_kept` version needs no row: its tile is
    # already the truth, and a row would send the job to fetch bytes `VersionHistory` has already
    # established are gone.
    #
    # `create_or_find_by!` RATHER THAN `find_or_create_by`, because the unique index is what
    # actually holds and two History opens can both read "no row yet" (the model says so beside the
    # validation). The enqueue is gated on `previously_new_record?` so a row somebody else just
    # minted is not re-rendered on every page view.
    def mint_missing(recorded, previews)
      node = node_at(@path)
      return previews if node.nil?

      name = File.basename(@path)
      minted = 0
      recorded.each do |v|
        next unless v.pointer? && v.content_available?
        next if previews.key?(v.content_token)
        break if minted >= MINT_LIMIT

        minted += 1
        row = Maker::VersionPreview.create_or_find_by!(
          project_id: @project.id, node_id: node.node_id,
          content_token: v.content_token, source_filename: name
        )
        previews[v.content_token] = row
        Maker::RenderVersionPreviewJob.perform_later(version_preview_id: row.id) if row.previously_new_record?
      end
      previews
    end

    # THE NODE A REPOSITORY-RELATIVE PATH NAMES, by DESCENDING from the project folder.
    #
    # A DESCENT, NOT A SECOND COPY OF `ProjectCommit#rel_from_tree`. That method answers the
    # opposite question — node to rel, by climbing `Maker::LibraryTree` and subtracting the
    # folder's own path — and it is private to a write path for good reason. This one is handed a
    # rel and needs the row, which no ascent can answer; it is one indexed `find_by` per segment,
    # which for the ordinary case (a file at the project folder's root) is exactly one.
    #
    # NIL IS AN ANSWER. A path with no live node behind it still RENDERS its versions — the commits
    # are real and their metadata is intact — it simply mints no render rows, because a render row
    # has to name a node. That is the same direction of degradation `VersionHistory` chose for an
    # unresolvable token: show the history, say less about the bytes.
    def node_at(rel)
      parent = @project.folder_node_id
      return nil if parent.blank?

      segments = rel.split("/")
      return nil if segments.size > MAX_DEPTH

      segments.each_with_index do |name, i|
        kind = i == segments.size - 1 ? "file" : "dir"
        node = current_user.nodes.present.find_by(parent_node_id: parent, name: name, kind: kind)
        return nil if node.nil?
        return node if kind == "file"

        parent = node.node_id
      end
      nil
    end

    # REJECT, NEVER NORMALIZE — `FileLayer::S3#key_for`'s rule, for the same reason: normalizing
    # `a/../b` produces a VALID path that names a different file, where a refusal names none. The
    # param reaches `Rugged::Tree#path`, and while a `..` segment there raises rather than escaping,
    # relying on that puts the guarantee in libgit2's hands instead of ours.
    def clean_path(raw)
      segments = raw.to_s.strip.split("/")
      return nil if segments.empty? || segments.size > MAX_DEPTH
      return nil if segments.any? { |s| s.blank? || s == "." || s == ".." }

      segments.join("/")
    end
  end
end
