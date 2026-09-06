module Projects
  # The releases panel's two write doors (stage 3, S3-5). Session-authed, like every Projects::*
  # controller. Plain forms + redirects, no turbo_stream -- Projects::BomLinesController's own
  # reasoning applies here too: a release is cut far less often than a task is toggled, so there is
  # no full-panel repaint worth avoiding.
  #
  # THERE IS NO `update`. A release is a record of a moment (spec §2.3), so it is removed and remade
  # rather than edited -- an editable version or changelog would describe a snapshot that was never
  # taken. `Maker::ReleaseSnapshot` is the ONE door that writes one, here and everywhere.
  class ReleasesController < ApplicationController
    # THE PICKER SENDS ONE FIELD FOR TWO FACTS, AND THIS IS WHERE THEY COME APART. A project folder
    # may hold several repositories, so a tag is meaningless without the one it came from -- but a
    # <select> cannot set a second field without JS, so its option values are `"<repo node_id>:<tag>"`
    # (projects/_releases.html.erb builds them). Splitting on the FIRST colon is unambiguous in both
    # halves: a node_id is a UUID on every backend (`SecureRandom.uuid`, all three adapters), and a
    # git ref name CANNOT contain a colon at all (git-check-ref-format rule 4), so nothing a maker
    # could legitimately type into the free-text field parses as an encoded value by accident.
    #
    # AN EXPLICIT `release[repo_node_id]` STILL WINS, and the field stays permitted for it: this
    # encoding is the PICKER's convenience, not the endpoint's shape, and a caller posting the pair
    # separately is asking a clearer question than one posting a string to be taken apart.
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      attrs = params.require(:release).permit(:version, :git_tag, :repo_node_id, :notes)
      git_tag, repo_node_id = split_tag(attrs[:git_tag], attrs[:repo_node_id])
      result = Maker::ReleaseSnapshot.call(user: current_user, project:, version: attrs[:version],
                                           notes: attrs[:notes], git_tag:, repo_node_id:)
      redirect_to project_path(project), notice: created_notice(result, git_tag)
    rescue ActiveRecord::RecordInvalid => e
      # The version's uniqueness and format live on Maker::Release, so this is where the maker is
      # told "v1.0.0 is already a release of this project" rather than at a 500.
      redirect_to project_path(project), alert: "Release not created: #{e.record.errors.full_messages.to_sentence}."
    rescue Maker::ReleaseSnapshot::TagNotFound => e
      # A REFUSED TAG LEAVES NOTHING BEHIND: the snapshot resolves the tag before it opens its
      # transaction, so there is no half-written release to clean up here.
      redirect_to project_path(project), alert: "Release not created: #{e.message}."
    end

    # SCOPED TO THIS USER'S OWN RELEASES, not a bare Maker::Release.find -- a foreign id 404s rather
    # than letting one tenant delete another's row (CLAUDE.md §8).
    #
    # NO BYTES ARE TOUCHED, which is the whole point of a release recording references: destroying
    # one drops the rows that remembered a moment and leaves every file exactly where it is.
    def destroy
      release = current_user.maker_releases.find(params[:id])
      project = release.project
      version = release.version
      release.destroy!
      redirect_to project_path(project), notice: "Removed release #{version}."
    end

    private

    def split_tag(git_tag, repo_node_id)
      return [ git_tag.presence, repo_node_id.presence ] if repo_node_id.present?

      id, colon, tag = git_tag.to_s.partition(":")
      return [ git_tag.presence, nil ] if colon.empty?

      [ tag.presence, id.presence ]
    end

    # NAMES THE FILE COUNT, because that is the fact a maker cannot see from the panel's summary
    # until it renders -- and says so when a tag was RECORDED rather than VERIFIED, since those two
    # look identical on the page except for the missing commit id (§14a: a library that is not a
    # local folder has no repository this process can read).
    def created_notice(result, git_tag)
      unverified = git_tag.present? && !result.tag_verified
      "Released #{result.release.version} with #{result.file_count} #{'file'.pluralize(result.file_count)}" \
        "#{' (tag recorded, not verified)' if unverified}."
    end
  end
end
