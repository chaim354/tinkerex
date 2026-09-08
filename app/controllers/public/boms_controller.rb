module Public
  # GET /u/:handle/:slug/bom(.csv) — the published bill of materials as a spreadsheet (stage 3,
  # S3-6). The bundle button adds the same bytes to the zip as `bom.csv`; a visitor who only wants
  # the parts list can fetch this on its own.
  #
  # THE OMISSIONS ARE THE PUBLIC PARTIAL'S AND ARE ENFORCED IN Maker::BomCsv, not here — stock,
  # supplier and notes are the maker's business (public/projects/_bom's own header says why), and a
  # CSV that quietly carried them would publish the owner's inventory levels to anyone with the URL.
  class BomsController < BaseController
    def show
      pub = public_project!
      # A HIDDEN BOM PANEL HAS NO CSV AT ALL (hardening, 2026-09-08; tinkerex#283). 404, not a
      # header-only document: a maker who hid the panel hid the parts list, and this URL is one
      # guess away from the page that hides it — an empty CSV would say "no parts", which is a
      # different and untrue answer. RAISED, NOT `head :not_found`, so it is the SAME 404 a missing
      # project gets — the rendered page through one handler. `head` was measured in review to
      # answer an empty text/csv body where `public_project!`'s refusal answers the HTML page, which
      # told a stranger with a guessed URL "this project exists and hid its BOM" (a near-nil leak on a
      # public project, but a comment here had claimed the two were indistinguishable, and it was
      # wrong). An unlisted project without its token still refuses at `public_project!` first.
      raise ActiveRecord::RecordNotFound unless pub.panel_visible?("bom")

      send_data Maker::BomCsv.render(pub.bom_lines, pub),
                type: "text/csv", disposition: "attachment",
                filename: "#{pub.project.slug}-bom.csv"
    end
  end
end
