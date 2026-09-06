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
      send_data Maker::BomCsv.render(pub.bom_lines, pub),
                type: "text/csv", disposition: "attachment",
                filename: "#{pub.project.slug}-bom.csv"
    end
  end
end
