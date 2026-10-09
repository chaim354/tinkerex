module Public
  # THE SESSIONLESS BASE. ActionController::Base, not ApplicationController: a public page never
  # reads the session (spec §6), so it must not inherit `authenticate_user!` or anything that
  # would let a template branch on who is looking. The architecture guard asserts
  # this superclass and greps app/controllers/public and app/views/public for session words.
  class BaseController < ActionController::Base
    layout "application"
    helper_method :public_surface?
    # AN UNMOUNTED OR UNREACHABLE LIBRARY IS A 503 ON EVERY PUBLIC PAGE, MAPPED ONCE HERE — the
    # answer §14a gives for FetchError (retryable, never "gone") and the one FilesController makes
    # once for the maker's pages. Without it a public byte route or file page answered a bare 500
    # (stage 4, S4-5, found in review). Nothing about the visitor is read; the status is the port's.
    rescue_from FileLayer::FetchError do
      head :service_unavailable
    end

    # The layout renders the anonymous shell for a public page EVEN FOR A SIGNED-IN OWNER, because
    # "what a visitor sees" is the honest preview of a public page.
    def public_surface? = true

    private

    def owner!
      User.find_by!(handle: params[:handle].to_s.downcase)
    end

    # A private project is a 404 to EVERYONE, including its owner in another tab: the page does not
    # consult the session, so it cannot know. An unlisted one needs its token, compared in constant
    # time; a public one needs nothing.
    #
    # THE `blank?` REFUSAL IS LOAD-BEARING, not belt-and-braces. `secure_compare("", "")` is TRUE
    # (`a.bytesize == b.bytesize && fixed_length_secure_compare(a, b)`, and both arms hold for the
    # empty string — read, not assumed), so a project whose `unlisted_token` is NULL would be
    # readable by anyone who omits `k` entirely. `mint_unlisted_token` fills the column on any
    # ordinary save, but an `update_column`/`update_all` that flips visibility bypasses it, and
    # that row must fail closed.
    def public_project!
      owner = owner!
      project = owner.maker_projects.published.find_by!(slug: params[:slug])
      raise ActiveRecord::RecordNotFound if project.unlisted? && !unlisted_token_ok?(project)

      Maker::PublicProject.new(project)
    end

    def unlisted_token_ok?(project)
      expected = project.unlisted_token.to_s
      given = params[:k].to_s
      return false if expected.blank? || given.blank?

      ActiveSupport::SecurityUtils.secure_compare(expected, given)
    end
  end
end
