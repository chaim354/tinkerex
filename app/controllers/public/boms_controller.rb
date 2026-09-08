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
      # different and untrue answer. The same door the visibility rule uses, so the two refusals are
      # indistinguishable from outside and neither discloses which one fired.
      return head :not_found unless pub.panel_visible?("bom")

      send_data Maker::BomCsv.render(pub.bom_lines, pub),
                type: "text/csv", disposition: "attachment",
                filename: "#{pub.project.slug}-bom.csv"
    end
  end
end
