module Settings
  # Shelf groups (2026-10-20): a heading on a project page over the panels of its shelves'
  # folders. Create, rename, remove; removing leaves the shelves ungrouped (Maker::ShelfGroup).
  # A refused name re-renders the Shelves page with the error in the form it came from and the
  # typed name kept (UX audit B3; Settings::ShelvesPage).
  class ShelfGroupsController < ApplicationController
    include Settings::ShelvesPage

    def create
      group = current_user.maker_shelf_groups.new(name: group_name, position: next_position)
      if group.save
        redirect_to settings_shelves_path, notice: "Added the group #{group.name}."
      else
        @new_group = group
        render_shelves_refusal
      end
    end

    def update
      group = current_user.maker_shelf_groups.find(params[:id])
      if group.update(name: group_name)
        redirect_to settings_shelves_path, notice: "Renamed the group to #{group.name}."
      else
        @failed_group = group
        render_shelves_refusal
      end
    end

    def destroy
      group = current_user.maker_shelf_groups.find(params[:id])
      group.destroy!
      redirect_to settings_shelves_path, notice: "Removed the group #{group.name}. Its shelves are ungrouped."
    end

    private

    def group_name = params.require(:shelf_group).permit(:name)[:name]
    def next_position = (current_user.maker_shelf_groups.maximum(:position) || -1) + 1
  end
end
