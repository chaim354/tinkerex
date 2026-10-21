module Maker
  # ONE USER'S SHELVES (2026-10-20). Three reads, and only the settings page's may write.
  module Shelves
    # Where an extension with no rule files (Maker::ProjectFolders.folder_for). No seeded rule
    # names it -- no extension carries the `other` role -- so it is added here by name.
    FALLBACK = "other".freeze

    # What a project page needs to know about one folder name.
    Entry = Data.define(:view, :group, :group_position)

    module_function

    # THE SETTINGS PAGE'S READ: a shelf row for every folder a filing rule names, plus `other`,
    # made on the way in. That is what keeps shelves and rules from drifting apart -- a rule moved
    # to a new folder by FilingRulesController#update, or written by an older version of this app,
    # simply gains its shelf here -- and it is why there is no second seed list: the filing rules'
    # own seed (Maker::FilingRules.seed!) is the seed. Positions follow the seed's folder order so a
    # new user's page reads in the order it always has; a custom folder lands after.
    def ensure!(user)
      Maker::FilingRules.seed!(user)
      wanted = (user.maker_filing_rules.distinct.pluck(:folder) + [ FALLBACK ]).uniq
      missing = wanted - user.maker_shelves.pluck(:name)
      return if missing.empty?

      seed_order = Maker::ProjectFolders::ROLE_FOLDERS.values.uniq
      start = (user.maker_shelves.maximum(:position) || -1) + 1
      now = Time.current
      rows = missing.sort_by { |n| [ seed_order.index(n) || seed_order.size, n ] }
                    .each_with_index.map do |name, i|
        { user_id: user.id, name:, position: start + i, created_at: now, updated_at: now }
      end
      # ON CONFLICT DO NOTHING: two first visits at once both land the same names.
      Maker::Shelf.insert_all(rows)
    end

    # THE SETTINGS HUB'S COUNT, WITHOUT WRITING: how many cards the Shelves page will show. The rows
    # are made on that page's first visit (#ensure!), so a count of rows alone read "0 shelves" for
    # every existing user until they opened it (found in review). It is #ensure!'s own arithmetic
    # over the same two columns, read rather than written; two plucks, constant in the row count.
    def count_for(user)
      names = user.maker_shelves.pluck(:name) | user.maker_filing_rules.distinct.pluck(:folder)
      # Nothing at all: the first visit seeds the default set, which is one shelf per seed folder.
      return Maker::ProjectFolders::ROLE_FOLDERS.values.uniq.size if names.empty?

      (names | [ FALLBACK ]).size
    end

    # THE PROJECT PAGE'S READ: folder name => Entry, ONE query, and NO write -- a GET of a project
    # must not mint rows. A folder with no shelf row is simply automatic.
    def by_name(user)
      user.maker_shelves.left_joins(:shelf_group)
          .pluck("maker_shelves.name", "maker_shelves.default_view",
                 "maker_shelf_groups.name", "maker_shelf_groups.position")
          .to_h { |name, view, group, pos| [ name, Entry.new(view:, group:, group_position: pos) ] }
    end
  end
end
