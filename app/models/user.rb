class User < ApplicationRecord
  has_many :devices, dependent: :destroy
  has_many :nodes, dependent: :destroy
  has_many :versions, dependent: :destroy
  has_many :chunks, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :pending_commits, dependent: :destroy
  has_many :device_pairings, dependent: :destroy
  has_many :conflicts, dependent: :destroy

  validates :email, presence: true, uniqueness: true

  # Assign the next per-user changelog sequence. MUST be called inside a
  # transaction: locks the user row so concurrent commits from multiple devices
  # get distinct, ordered seqs. Portable — FOR UPDATE on Postgres; SQLite
  # serializes writes globally so correctness holds either way.
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
