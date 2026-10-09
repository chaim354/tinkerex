# RECENT (structural redesign spec §7, slice 6; the app's front door at `/`): the files you changed
# lately, your active projects, and what needs attention — the last two only when they hold anything.
# EVERY LIST HERE IS BOUNDED AND ORDERED BY A COLUMN THAT ALREADY EXISTS — there is no activity table
# and no counter, and page_query_budget_test.rb asserts the count is constant in N.
class HomeController < ApplicationController
  # "Edit in <Addon>" for the recent-files tiles, the same right-click menu entry FilesController and
  # ProjectsController give their own file tiles.
  include AddonOrigins

  RECENT_PROJECTS = 6
  RECENT_FILES = 16
  # Only the failed-prints limit now: Recent has no prints section of its own (slice 6) — a failed
  # print is the one kind that still reaches this page, through "Needs attention".
  ATTENTION_PRINTS = 5
  ATTENTION_WINDOW = 30.days
  # Stage 2, S2-3: how many low-stock inventory items land in "Needs attention" — the same
  # bounded-list shape as RECENT_PROJECTS/RECENT_FILES/ATTENTION_PRINTS above, not a second pattern.
  ATTENTION_STOCK = 5

  def index
    # `.includes(:file_attachments)` is load-bearing, not decoration: `cover_node_id` falls back to
    # `derived_cover_node_id`, which reads the `file_attachments` association -- without the eager
    # load that is a query PER PROJECT, bounded only by RECENT_PROJECTS (6), which is constant
    # either way but stops being the SAME constant once the seeded project count crosses the limit
    # (page_query_budget_test.rb's small seed sits under it, the large one over it). Mirrors
    # ProjectsController#index, which eager-loads the same association for the same reason.
    @recent_projects = current_user.maker_projects.where.not(status: "archived")
                                   .includes(:file_attachments)
                                   .order(updated_at: :desc).limit(RECENT_PROJECTS).to_a
    @recent_files = current_user.nodes.present.where(kind: "file").visible_entries(false)
                                .order(updated_at: :desc).limit(RECENT_FILES).to_a
    @failed_prints = current_user.maker_print_runs.includes(:model)
                                 .where(outcome: "failed")
                                 .where("printed_on >= ?", ATTENTION_WINDOW.ago.to_date)
                                 .order(printed_on: :desc, id: :desc).limit(ATTENTION_PRINTS).to_a
    # A SECOND attention source, alongside failed prints — low stock is the `<=` scope from
    # Maker::InventoryItem (min_quantity itself counts as low), bounded and ordered by name the
    # same way every other list on this page is bounded (this class's own header).
    @low_stock = current_user.maker_inventory_items.low_stock.order(:name).limit(ATTENTION_STOCK).to_a
    @covers = Maker::Previews::ThumbnailMap.for(
      current_user, @recent_projects.filter_map(&:cover_node_id) + @recent_files.map(&:node_id)
    )
    @addon_origins = addon_origins_for(@recent_files.map(&:node_id))
    # Recent shows no folder, so Upload asks with the chooser — but it is this page's one action
    # (spec §4.2).
    upload_primary!
  end
end
