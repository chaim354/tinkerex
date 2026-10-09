module Projects
  # A FAILED FIRST ENTRY KEEPS ITS PANEL OPEN (structural redesign slice 6). An empty on-demand panel is
  # absent from the project page unless the request opens it with ?add= (ProjectsController#show, design-
  # system.md rule 14), so a create that fails on an otherwise empty project and redirects to the plain
  # page would take away the very form the maker was using — the alert would name a panel no longer on
  # the page. A failure redirect comes back through here instead: the page with that panel opened, at
  # its anchor. A success needs nothing: the panel now has a row and renders on its own.
  module PanelReturn
    private

    def project_panel_path(project, key) =
      project_path(project, add: key, anchor: ProjectsHelper::PANEL_ANCHORS.fetch(key))
  end
end
