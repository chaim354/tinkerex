module Settings
  # Shelf groups (2026-10-20): a heading on a project page over the panels of its shelves'
  # folders. Create, rename, delete; deleting leaves the shelves ungrouped (Maker::ShelfGroup).
  class ShelfGroupsController < ApplicationController
    def create
      group = current_user.maker_shelf_groups.new(name: group_name, position: next_position)
      if group.save
        redirect_to settings_shelves_path, notice: "Group #{group.name} added."
      else
        redirect_to settings_shelves_path, alert: group.errors.full_messages.to_sentence
      end
    end

    def update
      group = current_user.maker_shelf_groups.find(params[:id])
      if group.update(name: group_name)
        redirect_to settings_shelves_path, notice: "Group renamed to #{group.name}."
      else
        redirect_to settings_shelves_path, alert: group.errors.full_messages.to_sentence
      end
    end

    def destroy
      group = current_user.maker_shelf_groups.find(params[:id])
      group.destroy!
      redirect_to settings_shelves_path, notice: "Group #{group.name} removed. Its shelves are ungrouped."
    end

    private

    def group_name = params.require(:shelf_group).permit(:name)[:name]
    def next_position = (current_user.maker_shelf_groups.maximum(:position) || -1) + 1
  end
end
