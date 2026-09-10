class AddCurrentProjectToUsers < ActiveRecord::Migration[8.1]
  # THE CURRENT PROJECT MOVES OFF THE SESSION (slice 0, 2026-09-10). The rail card promises
  # "Uploads and tool output land here" and the creation flash says the same, but the whole of the
  # storage was `session[:current_project_id]` — so signing out, or opening the app on the workshop
  # tablet, silently reverted it to None and the next upload landed at the library root instead.
  # The promise outlived its storage.
  #
  # NO FOREIGN KEY, DELIBERATELY. The read is already `current_user.maker_projects...find_by(id:)`,
  # so a dangling or foreign id resolves to nil and the app falls back to "no current project" —
  # the exact behaviour a nullifying FK would produce, without a constraint that would have to be
  # taught about the archived filter too. §14d's rule about a dangling id locking a row does not
  # bite here: nothing validates this column, so a stale value can never make a User unsaveable.
  def change
    add_column :users, :current_project_id, :bigint
    add_column :users, :remember_current_project, :boolean, default: true, null: false
  end
end
