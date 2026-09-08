class AddDiscoveryMarksToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    # WHO MADE THIS PROJECT, AND HAS ITS OWNER LOOKED AT IT YET (stage 4, S4-6; stories 1.1, 4.4).
    #
    # `discovered_at` is stamped by Maker::ProjectDiscovery and by nothing else — not by the web
    # form, not by Projects::AdoptionsController, not by the v1 API — so `discovered_at.present?`
    # IS the definition of "the app made this, I did not". It is a TIMESTAMP rather than a boolean
    # because the sweep already knows when it ran and the value costs the same either way; §12's
    # own history says a boolean that turns out to want a moment is a second migration.
    #
    # `opened_at` is stamped once, by ProjectsController#show, the first time the owner opens the
    # page. Together they are the "New" badge: discovered and not yet looked at. It is also the
    # first half of story 4.4's per-project "new since", which is why it is a moment and not a
    # `seen` flag.
    #
    # NEITHER COLUMN IS INDEXED, DELIBERATELY. Neither is ever a WHERE predicate: the badge is
    # evaluated in Ruby over rows the index and Home have ALREADY loaded, and #show reads the row
    # it just found by slug. An index here would be a btree write on every project save buying no
    # seek — and `architecture_invariants_test.rb:1135` would then want an argument for why
    # `(user_id, discovered_at)` is not a redundant prefix of something. No index, no argument.
    #
    # NULLABLE, NO DEFAULT: every existing project reads "I made this, and it is not new", which
    # is what a migration alone must mean (spec §4).
    add_column :maker_projects, :discovered_at, :datetime
    add_column :maker_projects, :opened_at,     :datetime
  end
end
