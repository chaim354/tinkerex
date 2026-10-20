# DEPLOYMENT-WIDE FACTS CHOSEN IN THE APP (K, 2026-10-20) -- see db/migrate/*_create_settings.rb.
# Read through `get`, written through `put`, and nothing else touches the table.
#
# `get` IS MEMOISED PER PROCESS, and that is the point rather than an optimisation: the library
# redirect (ApplicationController) asks on EVERY signed-in request, and a setting changes once in a
# deployment's life. `put` and `forget` drop the memo in THIS process. Another process -- a bin/jobs
# container -- keeps its memo until it restarts, the same caveat FileLayer.current's memo carries
# (Tinkerex::LibraryRoot says where the page states it). Tests clear it per test (test_helper.rb),
# because the memo outlives each test's rollback.
#
# NO TABLE MEANS NO VALUE, AND IS NOT MEMOISED: migrations older than this table build
# FileLayer.current (db/migrate/*_purge_repo_metadata_nodes.rb), which now reads a setting, so a
# database part-way through `db:migrate` must answer nil rather than raise.
class Setting < ApplicationRecord
  MUTEX = Mutex.new

  validates :key, presence: true, uniqueness: true

  class << self
    # A MISS READS OUTSIDE THE LOCK AND STORES ONLY IF NO WRITE LANDED MEANWHILE (found in review).
    # Without the generation, a reader whose SELECT ran before a concurrent `put` committed, and whose
    # store ran after that `put` dropped the memo, kept the OLD value for the life of the process --
    # reproduced as a share library scanning the whole mount after a subfolder was chosen. Frozen on
    # store, so no caller can edit the value every other caller is handed.
    def get(key)
      generation = nil
      MUTEX.synchronize do
        @cache ||= {}
        return @cache[key] if @cache.key?(key)

        generation = @generation
      end
      return nil unless table_exists?

      value = find_by(key:)&.value&.freeze
      MUTEX.synchronize { (@cache ||= {})[key] = value if @generation == generation }
      value
    end

    # An UPSERT on the unique key, so two people confirming at once cannot raise RecordNotUnique. The
    # timestamps are Ruby's, not upsert's own CURRENT_TIMESTAMP: `changed_at` is compared with a
    # job's `enqueued_at`, which is Ruby's clock, and the two must be one clock (and one `travel_to`).
    def put(key, value)
      now = Time.current
      upsert({ key:, value: value.to_s, created_at: now, updated_at: now },
             unique_by: :key, update_only: %i[value updated_at], record_timestamps: false)
      invalidate(key)
      value
    end

    def forget(key)
      where(key:).delete_all
      invalidate(key)
    end

    # When the value last changed, for a job that must know whether it was queued before that.
    # Unmemoised: its one caller is a background scan, never a page.
    def changed_at(key) = where(key:).pick(:updated_at)

    def reset_cache!
      MUTEX.synchronize do
        @cache = nil
        @generation = @generation.to_i + 1
      end
    end

    private

    # AFTER the write, so a reader that missed the memo while the write was in flight cannot store
    # what it read before it (#get).
    def invalidate(key)
      MUTEX.synchronize do
        @cache&.delete(key)
        @generation = @generation.to_i + 1
      end
    end
  end
end
