# DEPLOYMENT-WIDE FACTS CHOSEN IN THE APP (K, 2026-10-20) -- see db/migrate/*_create_settings.rb.
# Read through `get`, written through `put`, and nothing else touches the table.
#
# `get` IS CACHED PER REQUEST AND PER JOB (Current.settings), NEVER PER PROCESS. The library
# redirect (ApplicationController) and FileLayer::Share#root ask on every request and every port
# call, so one query per request or job is the cost; a process-wide memo would be cheaper and is
# WRONG HERE: Solid Queue's Puma plugin FORKS its workers, and a value memoised in one process is
# never told about a `put` in another -- a folder chosen in the browser left every worker scanning,
# filing and previewing the old one until a restart (found in review, Solid Queue 1.7's
# `start_forked`). The executor clears Current around each request and each job, so every process
# reads the row fresh at the start of its next unit of work, and one request or one job sees one
# value throughout. Stored values are frozen, so no caller edits what the next one is handed.
#
# NO TABLE MEANS NO VALUE, AND IS NOT CACHED: migrations older than this table build
# FileLayer.current (db/migrate/*_purge_repo_metadata_nodes.rb), which now reads a setting, so a
# database part-way through `db:migrate` must answer nil rather than raise.
class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  class << self
    def get(key)
      cache = (Current.settings ||= {})
      return cache[key] if cache.key?(key)
      return nil unless table_exists?

      cache[key] = find_by(key:)&.value&.freeze
    end

    # An UPSERT on the unique key, so two people confirming at once cannot raise RecordNotUnique. The
    # timestamps are Ruby's, not upsert's own CURRENT_TIMESTAMP: `changed_at` is compared with a
    # job's `enqueued_at`, which is Ruby's clock, and the two must be one clock (and one `travel_to`).
    def put(key, value)
      now = Time.current
      upsert({ key:, value: value.to_s, created_at: now, updated_at: now },
             unique_by: :key, update_only: %i[value updated_at], record_timestamps: false)
      Current.settings&.delete(key)
      value
    end

    def forget(key)
      where(key:).delete_all
      Current.settings&.delete(key)
    end

    # When the value last changed, for a job that must know whether it was queued before that.
    # Uncached: its one caller is a background scan, never a page.
    def changed_at(key) = where(key:).pick(:updated_at)

    def reset_cache! = Current.settings = nil
  end
end
