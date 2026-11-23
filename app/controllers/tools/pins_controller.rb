module Tools
  # PINNING A TOOL TO THE SIDEBAR (2026-10-22). Any tool on the Tools page — the built-in calculator
  # or an addon — is pinned or unpinned by a right click on its card or on its pinned link in the
  # rail (toolmenu_controller.js posts here). The card's visible Pin toggle that also posted here
  # (2026-11-02) was removed on 2026-11-23, the owner's call. The list lives on the user (Maker::ToolPins), so it
  # follows the maker to every device; the rail's collapse state is a per-browser cookie because it
  # is about the screen, not the person. It began as the calculator's alone (2026-10-21), at this
  # same URL with `calculator` as the key.
  #
  # NOT A Tools::BaseController: that base exists for the addon doors that write into the library,
  # and this writes one column on the user.
  class PinsController < ApplicationController
    # PINNING ASKS THE REGISTRY WHETHER THE TOOL IS REAL AND RUNS HERE, and copies its title, because
    # the rail may not ask later (Maker::ToolPins). A greyed-out addon is refused: its pinned link
    # would open a tool that cannot work on this server. A built-in tool (Maker::ToolPins::BUILT_IN)
    # asks nothing.
    def create
      key = params[:key].to_s
      title = pinnable_title(key)
      return redirect_back_or_to(tools_path, alert: "That tool can't be pinned here.") if title.nil?

      current_user.tool_pins.pin!(key, title: Maker::ToolPins::BUILT_IN.key?(key) ? nil : title)
      redirect_back_or_to tools_path, notice: "Pinned #{title} to the sidebar."
    end

    # UNPINNING NEVER READS THE REGISTRY, so a pin whose addon the source has stopped serving (or
    # whose source is down) can still be taken out of the rail. Unpinning what is not pinned is a
    # no-op that says the same thing, as a second click from a stale page would expect.
    def destroy
      key = params[:key].to_s
      label = current_user.tool_pins.find(key)&.label || "the tool"
      current_user.tool_pins.unpin!(key)
      redirect_back_or_to tools_path, notice: "Unpinned #{label} from the sidebar."
    end

    private

    def pinnable_title(key)
      return Maker::ToolPins::BUILT_IN[key] if Maker::ToolPins::BUILT_IN.key?(key)

      addon = Maker::Addons::Registry.find(key)
      addon.title if addon&.available?
    end
  end
end
