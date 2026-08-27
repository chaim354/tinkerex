module Maker
  module Git
    # DOES THIS FILE GO INTO THE REPOSITORY AS CONTENT, OR AS A POINTER TO CONTENT?
    #
    # WHY IT EXISTS. Git stores every version of a binary WHOLE -- a binary delta between two
    # meshes is near-worthless, so twenty saves of a 50 MB STEP file is roughly a gigabyte inside
    # `.git`, permanently: git cannot prune reachable history without rewriting it, which rewrites
    # every commit id the maker has ever seen. There is no later cleanup that fixes this, which is
    # why the decision has to be made at the moment a file enters a commit rather than deferred.
    #
    # IT IS ALSO WHAT MAKES THE UNDELTIFIED PACK WRITER AFFORDABLE, and the two decisions hold each
    # other up. That writer costs about 5x on bytes; five times SMALL is still small, but only
    # because everything large is a pointer. Make big files content and the pack writer's cost stops
    # being a rounding error -- change either decision and re-argue the other.
    #
    # THE PATTERN IS GIT-LFS'S, THE PROTOCOL IS NOT. There is no LFS server anywhere in this app, no
    # `lfs.url`, no batch API, no `.gitattributes` filter driver. A pointer here is a small text
    # blob naming a content hash the LIBRARY already holds -- resolving one is `FileLayer`'s job,
    # over the port, exactly as any other read is. The borrowed idea is only "commit a stable
    # reference instead of the bytes"; borrowing the wire format too would mean standing up a
    # service to serve bytes we already have.
    #
    # DERIVED FROM THE ONE VOCABULARY, NEVER A SECOND EXTENSION TABLE. `Maker::FileAttachment` owns
    # ROLE_BY_EXT / TEXT_ROLES / TEXT_EXTS / TEXT_BASENAMES and answers `text?` over all of them; a
    # hand-written list here would be exactly the drift `FilesHelper::EXT_FAMILIES` was rewritten to
    # end after two lists disagreed about `.svg` for months (§14d). It asks `text?` rather than
    # re-testing TEXT_ROLES itself for two reasons, both load-bearing:
    #
    #   * `.scad` is `cad_source` -- NOT a text role -- and is text anyway (TEXT_EXTS). A role check
    #     commits OpenSCAD source as an opaque blob, losing diffs on the one CAD format that has
    #     them.
    #   * `LICENSE`, `Makefile`, `README` have NO EXTENSION (`File.extname("LICENSE")` is ""), so no
    #     extension table can reach them -- and a repo's root is full of exactly those.
    #
    # "Is it text?" and "does git delta it usefully?" are the same question about the same files,
    # so they get the same answer from the same place. A new extension in ROLE_BY_EXT is answered
    # here with nobody editing this file.
    #
    # POINTER MODE IS THE DEFAULT, AND THE ASYMMETRY IS DELIBERATE. An unknown format wrongly made a
    # pointer costs one indirection; an unknown format wrongly made content can put an unbounded
    # binary into history that cannot be removed.
    #
    # NAME IS NOT THE ONLY AXIS -- SIZE OVERRIDES IT. A text NAME says nothing about how many bytes
    # are behind it, and the whole hazard above is measured in bytes, so `MAX_CONTENT_BYTES` demotes
    # anything past it whatever the name says. See that constant for where the number comes from and
    # what would change it.
    #
    # A POINTER TO A SUPERSEDED VERSION RESOLVES ONLY WHERE THE STORE KEPT THOSE BYTES, and the
    # commit does not record whether it did. On `chunk_remote` the sync server holds every version,
    # so old pointers resolve. On `s3` they resolve only where the bucket has versioning turned on
    # -- the user's own bucket, the user's own setting. On `share` they do NOT: the maker's overwrite
    # in Finder destroyed the previous bytes before this app ever saw them (§14a -- share and s3 are
    # current-state only, deliberately). So a UI reading history must be able to say "this version's
    # bytes were not kept" -- the COMMIT is real and its metadata is intact; only the content is
    # gone. Rendering that as a missing or corrupt commit tells the maker their history is broken
    # when what actually happened is the storage they chose never retained the file.
    module Tracking
      # The `version` line of a pointer body. Ours, not LFS's `https://git-lfs.github.com/spec/v1`
      # -- a reader must never mistake one of these for something an LFS client can resolve.
      POINTER_VERSION = "tinkerex/v1".freeze

      # THE SIZE CEILING FOR CONTENT TRACKING. Over this a file is a POINTER whatever its name says,
      # because a 400 MB Markdown file is still a 400 MB blob: this pack writer stores every version
      # of it WHOLE, forever, in a history git cannot prune without rewriting every commit id the
      # maker has ever seen. Role alone cannot see that -- `notes.md` and a 400 MB `notes.md` are
      # the same filename -- which is why the ceiling overrides the role rather than the other way
      # round.
      #
      # THIS NUMBER IS REASONED, NOT MEASURED AGAINST A REAL LIBRARY, and saying so is the point.
      # `rake git_tracking:size_distribution` exists to take that measurement and HAS NOT BEEN RUN
      # against the maker's own share deployment -- this build box holds test data only. It was
      # chosen instead from the two figures that ARE checkable inside this repo:
      #
      #   * `Maker::Git::TextDiff::MAX_BYTES` is 256 KiB PER SIDE. Past it the compare surface
      #     REFUSES the diff outright, so a content-tracked version above the cap already renders
      #     like a pointer one; the only thing content tracking still buys up there is that the
      #     bytes survive on `share`, where the store keeps no history at all. 4 MiB is 16x that
      #     cap, so nothing a maker can actually diff comes anywhere near being demoted.
      #   * THE PACK WRITER IS UNDELTIFIED, so a file costs its full size in EVERY version it
      #     appears in and there is no amortisation to lean on. The measured whole-project pack is
      #     3.9 MB at 1,500 commits (docs/invariants/git-tracked-projects.md) -- so at 4 MiB a
      #     SINGLE version of a SINGLE file already costs more than that entire history. That is
      #     the line this constant draws: above it, one file stops being a rounding error, which is
      #     precisely the condition that makes the 5x undeltified writer affordable.
      #
      # WHAT WOULD CHANGE IT: a p99 from a real library landing materially away from 4 MiB (raise
      # it rather than demote ordinary source; lower it rather than let the common case dominate
      # the pack), or a deltifying pack writer, which would void the second bullet's arithmetic
      # entirely. Replace the number and this comment together.
      MAX_CONTENT_BYTES = 4 * 1024 * 1024

      # CROSSING THE CEILING IS A DELETE PLUS AN ADD, DECIDED RATHER THAN INHERITED. A text file
      # that grows past it moves from `notes.md` to `notes.md.ptr`, and git records exactly that.
      # Both alternatives are worse:
      #
      #   * Committing the pointer body AT `notes.md` keeps the path stable but makes "is this a
      #     pointer" a question about the BLOB instead of the path -- ambiguous for a text file
      #     whose content happens to look like a pointer body, and it silently reinterprets every
      #     repository already committed under the `.ptr` convention.
      #   * "Once content, always content" needs HEAD's tree to decide, which this module cannot
      #     see, and it permanently exempts exactly the file the ceiling exists for: the `.md` that
      #     reached 400 MB keeps being committed whole.
      #
      # NOTHING IS LOST FROM THE REPOSITORY -- both halves of that file's history are in it. What
      # IS lost is that `Maker::Git::VersionHistory#for_path` derives the mode from the NAME alone
      # and so renders only ONE half. That is a real gap and it is written down as a known
      # limitation in docs/invariants/git-tracked-projects.md rather than papered over here.

      module_function

      # :content or :pointer.
      #
      # `size:` IS OPTIONAL, AND AN ABSENT SIZE MEANS "I DO NOT KNOW" RATHER THAN "IT IS HUGE".
      # Defaulting nil to :pointer would be the safe direction if this were the only door, and it
      # is not: the READ paths (`VersionHistory#for_path`, `Projects::HistoryController`, and the
      # measurement task) hold a filename and no row, so answering :pointer there would make every
      # content-tracked source file's history unreadable at a stroke. The unbounded-binary risk is
      # closed at the WRITE door instead -- `Maker::Git::ProjectCommit#paths_for` is the only
      # caller that can put bytes into a commit, and it always passes `node.size`.
      #
      # `nodes.size` IS NULLABLE, so that one caller can still hand this nil. A row with no observed
      # size then falls back to the name, which is what shipped before this ceiling existed rather
      # than a new gap -- and the next scan that observes the file gives it a size.
      #
      # IT STILL TAKES A NAME RATHER THAN A NODE, and that is load-bearing twice over: a caller
      # deciding what to do with a file it has not read yet can ask, and the measurement task can
      # ask the ROLE-ONLY question -- which is the only question that can CHOOSE a threshold, since
      # a report filtered by the threshold hides exactly the files it exists to find. `mode_for(node)`
      # would have made that question unaskable.
      def mode_for(name, size: nil)
        return :pointer if size && size > MAX_CONTENT_BYTES

        Maker::FileAttachment.text?(name) ? :content : :pointer
      end

      # The blob body committed in place of the bytes. Trailing newline included: this is a text
      # blob and a git diff of one without it reads "\ No newline at end of file" forever.
      #
      # `oid` CARRIES `content_hash` VERBATIM, NAMESPACE AND ALL, and must keep doing so. That
      # value is the §14a identity ladder's output: `sha256:` on chunk_remote, but `md5:` or
      # even `etag:` on s3, where the rung reached depends on how the object was uploaded.
      # Stripping the prefix to make every pointer look like an LFS `sha256` oid would state a
      # hash ALGORITHM the bytes were never hashed with -- and an `etag:` value is additionally
      # content-STATE rather than content-DETERMINED, which a reader has to be able to tell.
      def pointer_for(node)
        "version #{POINTER_VERSION}\noid #{node.content_hash}\nsize #{node.size}\n"
      end
    end
  end
end
