module Library
  # One entry as an observer saw it — the vocabulary the observing half and the deciding half
  # share. `Library::Scanner` (a mounted share) produces these; `Library::Reconciler` consumes
  # them; from Phase 3 an S3 lister produces them too.
  #
  # It lives here, and not on the Scanner, for that last reason: a second observer that is not a
  # filesystem walk would otherwise have to name `Scanner::Observation` to describe a bucket it
  # never walks. `Library::Scanner::Observation` remains an alias of this class, so the name the
  # existing call sites use still resolves to exactly this constant.
  #
  # `size` is nil for directories (a directory's st_size is an allocation detail — 96, 4096 —
  # and storing it in nodes.size would be meaningless bytes in a column that means "how big is
  # this file").
  #
  # WHY `content_hash` IS OPTIONAL — and it is the whole reason this class has its own file.
  #
  # The Reconciler hashes LAZILY, and that is right for a share: identity there costs a read of
  # the bytes, so a file whose (path, mtime, size) is unchanged is skipped without ever being
  # opened, and a 2TB archive is not re-read every pass. An Observation carrying only what a stat
  # gives is what buys that.
  #
  # S3 inverts both halves. Identity arrives FREE in the listing (the ETag is right there), so
  # lazily "saving" a read means DOWNLOADING the object instead — a full egress of the bucket on
  # first scan, which is precisely the cost the "point it at my existing storage" on-ramp exists
  # to avoid. And S3's `last_modified` is second-granularity, so the (mtime, size) skip is
  # coarser there than a share's nanoseconds.
  #
  # So an observer that already KNOWS the identity may say so, and is then never asked to pay for
  # it a second time: the Reconciler takes `content_hash` verbatim and never calls its reader,
  # and the incremental skip compares the identity directly — free, exact, and no granularity
  # question. An observer that does not know it leaves this nil and the lazy path is bit-for-bit
  # what it was.
  #
  # The VALUE is opaque here on purpose. A share supplies a bare SHA-256 hex digest; S3 supplies
  # a namespaced `md5:` / `sha256:` / `etag:` string whose prefix records how content-determined
  # it is (FileLayer::S3::ObjectIdentity). This class does not care — it only carries it, and the
  # Reconciler only ever compares two of them for equality. Do not "normalize" or parse it here:
  # a value from one observer is never compared against a value from another, because a library
  # has exactly one backend (FileLayer.current), chosen per deployment.
  Observation = Data.define(:rel_path, :size, :mtime, :dir, :content_hash) do
    # `Data.define` has no default-value syntax, and this is the mechanism for one: Data funnels
    # BOTH construction forms through #initialize — `new(rel, size, mtime, dir)` positionally and
    # `new(rel_path: ..., dir: ...)` by keyword — so a keyword default here serves them both, and
    # the Scanner's four-argument call sites keep working untouched.
    #
    # `super` does all the real work, which is why this form and not a `def self.new` override:
    # the override would have to reimplement the positional/keyword split by hand, and `#with`
    # calls `new` too, so getting it subtly wrong would break `with` rather than anything a test
    # of `new` would notice. Frozen-ness, `==`, `#with`, `deconstruct_keys` and the missing-
    # keyword ArgumentError are all inherited unchanged. In particular a four-arg Observation and
    # an explicit `content_hash: nil` one are `==` — pinned by a test, because the pairing buckets
    # key on Observation equality.
    def initialize(rel_path:, size:, mtime:, dir:, content_hash: nil) = super
  end
end
