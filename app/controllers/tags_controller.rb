# One page per tag (stage 2, S2-5): everything wearing it, grouped by kind. Read-only,
# session-authed (CLAUDE.md §14d) -- no action here writes anything.
class TagsController < ApplicationController
  # Each group's fetch is capped here; a tag with more than this many rows of one kind still shows
  # a total (the count-when-capped query below) and a "See all" link into that kind's own,
  # already tag-filterable index (ProjectsController/Files::ModelsController/InventoryItemsController
  # each answer `?tag=`) rather than growing this page without bound.
  GROUP_CAP = 100

  def show
    @tag = current_user.maker_tags.find_by!(name: params[:name].to_s.strip.downcase)
    @groups = [
      capped_group("Projects", :project, current_user.maker_projects.tagged_with(@tag.name).order(:name),
                   projects_path(tag: @tag.name)),
      capped_group("Models", :model, current_user.maker_models.tagged_with(@tag.name).order(:title),
                   files_models_path(tag: @tag.name)),
      # The desktop client's Maker::Item rows carry tags too (their own taggings, not this
      # concern's), but the web has no item page to link a result row to, so they are not listed
      # here -- this page shows only what the web itself can navigate to.
      capped_group("Inventory", :inventory_item, current_user.maker_inventory_items.tagged_with(@tag.name).order(:name),
                   inventory_items_path(tag: @tag.name))
    ]
  end

  private

  # Fetches up to GROUP_CAP records; the exact total costs a second query ONLY when the fetch hit
  # the cap (i.e. there might be more) -- an untagged-heavy account pays three queries for this
  # page, same as always, and only a tag with more than 100 things of one kind pays a fourth.
  def capped_group(title, kind, scope, more_path)
    records = scope.limit(GROUP_CAP).to_a
    total = records.size == GROUP_CAP ? scope.count : records.size
    { title:, kind:, records:, total:, more_path: }
  end
end
