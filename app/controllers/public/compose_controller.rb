module Public
  # THE COMPOSE GENERATOR (/install/compose, 2026-10-21; plan
  # docs/superpowers/plans/2026-10-21-compose-generator.md). A prospective self-hoster fills in their
  # folder or network share, port, user and mail, and the browser builds their docker-compose.yml.
  #
  # IN THE PUBLIC NAMESPACE FOR TWO REASONS. It must render for a visitor with no account on every
  # deployment, and most of all on the public demo's box, where the landing links to it; and the
  # namespace's guard (architecture_invariants_test.rb) is what proves it never reads the session.
  # Signed in or not, everyone gets the visitor's shell, the same page.
  #
  # THIS ACTION SENDS THE TEMPLATE AND RECEIVES NOTHING. Tinkerex::ComposeTemplate reads
  # docker-compose.yml on each render, so the generator offers the file this image was built from;
  # the visitor's values never come back here (the page has no form, and compose_controller.js
  # fetches nothing).
  class ComposeController < BaseController
    def show
      @template = Tinkerex::ComposeTemplate.new
    end
  end
end
