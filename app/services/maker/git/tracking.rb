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

      module_function

      # :content or :pointer. Takes a NAME, not a node, so a caller deciding what to do with a file
      # it has not read yet can ask.
      def mode_for(name)
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
