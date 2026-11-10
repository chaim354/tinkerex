module Maker
  # ONE WAY TO START A PROJECT FROM A FORM (onboarding wizard, 2026-11-09): save it, make its
  # `Projects/<slug>` folder, and say what happened in the maker's terms. ProjectsController#create
  # and WelcomeController#create_project both call it (§14d: a verb more than one controller
  # performs gets a named service), so the two doors cannot drift on the folder or the sentences.
  # The MCP server's create_project keeps its own copy on purpose: its sentences are written for an
  # assistant and it lets every error but the two port failures propagate.
  #
  # The caller BUILDS the project, so a door can refuse it before anything is saved
  # (ProjectsController#demo_may_publish?) and re-render the same object with its errors.
  #
  # A FOLDER FAILURE IS NOT A CREATE FAILURE (stage 4, S4-6; story 1.2). The project is saved first
  # and stays saved; the folder is best-effort, and `alert` says WHICH problem it hit —
  # FileLayer::FetchError (try again) or anything else (FileLayer::UnsupportedOperation never
  # succeeds on retry) — as a sentence, never the class name, which a maker cannot act on (UX audit
  # C10). The class and message go to the log, where an operator reads. "The next time you open the
  # project" is literal: ProjectsController#show re-ensures the folder on every render.
  class CreateProject
    UNREACHABLE = "The library could not be reached, so the project folder was not created yet. It is made " \
                  "the next time you open the project while the library is available.".freeze
    REFUSED = "The project folder could not be made in the library; a file or folder there may already " \
              "have its name. It is tried again each time you open the project.".freeze

    Result = Data.define(:project, :failure) do
      def created? = project.persisted?

      # THE FOLDER IS NAMED FROM THE SLUG, NOT LOOKED UP, and that is exact here: a project made
      # through this service always reaches ensure_library_folder!'s minting branch (a brand-new
      # project has no folder_node_id), and that branch builds [ROOT, slug] literally.
      #
      # THE FAILURE IS AN ALERT BESIDE THE NOTICE, never folded into it (2026-11-02): the project WAS
      # created, which is news, and its folder was not, which is a problem — and a problem in a
      # `flash-notice` is drawn under the word "Done".
      def notice
        return "Created #{project.name}." if failure

        "Created #{project.name}. Its folder is #{Maker::ProjectFolders::ROOT}/#{project.slug}."
      end

      def alert
        return if failure.nil?

        failure == :unreachable ? UNREACHABLE : REFUSED
      end
    end

    def self.call(user, project)
      return Result.new(project:, failure: nil) unless project.save

      Result.new(project:, failure: ensure_folder(user, project))
    end

    def self.ensure_folder(user, project)
      project.ensure_library_folder!(user)
      nil
    rescue FileLayer::FetchError => e
      log_failure(project, e)
      :unreachable
    rescue StandardError => e
      log_failure(project, e)
      :refused
    end

    def self.log_failure(project, error)
      Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{error.class} #{error.message}")
    end
    private_class_method :ensure_folder, :log_failure
  end
end
