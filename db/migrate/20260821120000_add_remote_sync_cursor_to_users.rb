# frozen_string_literal: true

# THE chunk_remote CURSOR: the highest changelog seq this app has applied from a REMOTE sync server.
#
# NOT `users.head_seq`, THOUGH THE TEMPTATION IS REAL AND THE NUMBERS LOOK ALIKE. head_seq means
# "the highest seq this app has ISSUED" -- it is the engine's own counter, bumped by User#next_seq!
# inside every commit. This means "the highest seq this app has RECEIVED". They coincide only
# because a chunk deployment is both sides of the protocol at once.
#
# The hazard that decided it: a deployment migrating from chunk to chunk_remote would carry a stale
# LOCAL head_seq -- a number issued by an engine that is no longer the source of truth -- and the
# apply loop would read it as a cursor and silently skip every entry below it. One column answering
# two questions is CLAUDE.md §14a's recorded failure shape, and this is the version of it where the
# symptom is a library that is quietly missing files.
#
# It ships on every backend because migrations are not conditional (§14j: db/migrate/ is never
# rewritten for a deployment's shape). A bigint defaulting to 0 is the cheapest thing this could be.
class AddRemoteSyncCursorToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :remote_sync_cursor, :bigint, default: 0, null: false
  end
end
