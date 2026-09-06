module Public
  # GET /u/:handle/:slug/bundle(.json) — the MANIFEST a visitor's browser zips from (stage 3, S3-6).
  #
  # RAILS NEVER ZIPS BYTES, AND THIS ENDPOINT IS WHAT MAKES THAT POSSIBLE. A server-side bundle
  # would have to READ every file — on s3 that is a full billed download into the app just to
  # re-upload it to the visitor, and on chunk_remote it is a WAN stream per file through Puma — for
  # a request any visitor can issue. §15 says bytes stay out of Rails, so the answer here is a list
  # of the same public download URLs the page already links, and `bundle_controller.js` fetches
  # them from the browser and builds the zip there.
  #
  # NO VIEW FILE. The document is four scalars and a list; a jbuilder template would put the shape
  # somewhere the controller's own test cannot read it.
  class BundlesController < BaseController
    def show
      pub = public_project!
      project = pub.project

      render json: {
        name: project.name,
        handle: pub.handle,
        slug: project.slug,
        generated_at: Time.current.iso8601,
        # THE LISTING'S CAP, REPORTED RATHER THAN HIDDEN — see Maker::PublicProject#bundle_files.
        truncated: pub.listing.truncated?,
        readme_path: pub.readme_row&.node&.name,
        bom_csv_url: public_bom_path(pub.handle, project.slug, **pub.link_params),
        files: pub.bundle_files.map { |f| { path: f.path, size: f.size, url: f.url } }
      }
    end
  end
end
