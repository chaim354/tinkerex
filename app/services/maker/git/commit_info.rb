module Maker
  module Git
    # What the UI reads. A VALUE OBJECT RATHER THAN A Rugged::Commit, and that is not a style
    # preference: a Rugged object holds a live handle into the repository directory, and on s3 and
    # chunk_remote that directory is an EPHEMERAL CACHE this app throws away between requests by
    # design. Handing one to a view is a use-after-free waiting for a slow render.
    CommitInfo = Data.define(:oid, :message, :author, :time, :parent_oids) do
      def short_oid = oid[0, 7]

      # The first commit has no parent. Named rather than left as `parent_oids.empty?` at call
      # sites, because the version list has to render it differently (there is no "compare with
      # previous" for it) and one spelling is what keeps those two views agreeing.
      def root? = parent_oids.empty?
    end
  end
end
