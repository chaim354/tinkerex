# The Home page (stage 2, S2-1): the current project, then what changed recently, then what
# needs attention. EVERY READ HERE IS BOUNDED AND ORDERED BY A COLUMN THAT ALREADY EXISTS — there
# is no activity table and no counter, and page_query_budget_test.rb asserts the count is constant
# in N.
class HomeController < ApplicationController
  # The hero's upload control (`projects/upload_control`) branches on `capabilities.port_writable?`
  # exactly as the project page and the Files page do — the `capabilities` helper method comes from
  # here, not from ApplicationController.
  include LibraryCapabilities

  # "Edit in <Addon>" for the recent-files row, the same right-click menu entry FilesController and
  # ProjectsController give their own file tiles.
  include AddonOrigins

  RECENT_PROJECTS = 6
  RECENT_FILES = 8
  RECENT_PRINTS = 5
  HERO_TASKS = 5
  ATTENTION_WINDOW = 30.days

  def index
    @project = current_project
    if @project
      tasks = @project.tasks.order(:position, :created_at).to_a
      @hero_tasks = tasks.reject { |t| t.status == "done" }.first(HERO_TASKS)
      @hero_stats = {
        files: @project.file_attachments.count,
        tasks_done: tasks.count { |t| t.status == "done" },
        tasks_total: tasks.size,
        entries: @project.build_log_entries.count,
        sheets: @project.sheets.count
      }
      @hero_entry = @project.build_log_entries.includes(:rich_text_body).reorder(logged_at: :desc).first
      @upload_parent_node_id = current_project_folder_node_id
    end

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
    @recent_prints = current_user.maker_print_runs.includes(:model)
                                 .order(printed_on: :desc, id: :desc).limit(RECENT_PRINTS).to_a
    @failed_prints = current_user.maker_print_runs.includes(:model)
                                 .where(outcome: "failed")
                                 .where("printed_on >= ?", ATTENTION_WINDOW.ago.to_date)
                                 .order(printed_on: :desc, id: :desc).limit(RECENT_PRINTS).to_a
    @covers = Maker::Previews::ThumbnailMap.for(
      current_user, @recent_projects.filter_map(&:cover_node_id) + @recent_files.map(&:node_id)
    )
    @addon_origins = addon_origins_for(@recent_files.map(&:node_id))
  end
end
