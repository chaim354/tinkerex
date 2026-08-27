namespace :git_tracking do
  # WHAT WOULD BE COMMITTED AS CONTENT, BY SIZE. Read-only -- it reads `nodes` and writes nothing,
  # so it is safe to run against a live library.
  #
  # IT EXISTS BECAUSE `Maker::Git::Tracking::MAX_CONTENT_BYTES` IS REASONED RATHER THAN MEASURED.
  # That constant names the two checkable figures it was derived from and says plainly that no real
  # library was consulted; this task is how that gets fixed. Run it on the **share** deployment --
  # that is where the real data is, chunk_remote and s3 hold test users only -- and set the ceiling
  # from the p99 rather than from a round number.
  #
  # IT ASKS THE ROLE-ONLY QUESTION ON PURPOSE, passing no `size:` to `mode_for`. Filtering by the
  # current ceiling would hide exactly the files the ceiling exists to catch, and a report that
  # cannot see them cannot be used to choose a better one. The `over` column is reported separately
  # so the demotion the current value would cause is visible beside the distribution that argues
  # about it.
  #
  # IT IS A SUPERSET OF WHAT THE COMMIT PATH ACTUALLY SEES, stated rather than implied: only files
  # beneath a project folder are committed (`ProjectCommit#eligible_nodes`), and `.git` internals
  # are excluded there by descent rather than by a filter a flat query can reuse. Reproducing that
  # descent here would be a second spelling of it, which is the drift §14d keeps warning about --
  # and a superset is the right direction of wrong for choosing a ceiling, because every file it
  # over-counts is one more chance to see a pathological size.
  #
  # ROWS ARE STREAMED AND ONLY TWO COLUMNS ARE READ. A real library is hundreds of thousands of
  # rows and this must not instantiate a model per file to ask a question about a filename.
  desc "Report the size distribution of content-tracked files per user (read-only)"
  task size_distribution: :environment do
    User.find_each do |user|
      sizes = []
      over = 0

      user.nodes.present.where(kind: "file")
          .in_batches(of: 5_000) do |batch|
        batch.pluck(:name, :size).each do |name, size|
          next unless Maker::Git::Tracking.mode_for(name) == :content
          next if size.nil?

          sizes << size
          over += 1 if size > Maker::Git::Tracking::MAX_CONTENT_BYTES
        end
      end

      next if sizes.empty?

      sizes.sort!
      # NEAREST-RANK, CLAMPED. `sizes[(n * p).floor]` walks off the end at p=100 and returns nil,
      # which formats as an empty column rather than an error -- the quiet kind of wrong.
      pct = ->(p) { sizes[((sizes.size * p / 100.0).floor).clamp(0, sizes.size - 1)] }
      human = ->(b) { ActiveSupport::NumberHelper.number_to_human_size(b) }

      puts format("user=%d n=%d p50=%s p90=%s p95=%s p99=%s max=%s over_ceiling=%d",
                  user.id, sizes.size,
                  human.(pct.(50)), human.(pct.(90)), human.(pct.(95)), human.(pct.(99)),
                  human.(sizes.last), over)
    end

    puts "ceiling=#{ActiveSupport::NumberHelper.number_to_human_size(Maker::Git::Tracking::MAX_CONTENT_BYTES)} " \
         "(Maker::Git::Tracking::MAX_CONTENT_BYTES) — set it from p99, and update that constant's comment"
  end
end
