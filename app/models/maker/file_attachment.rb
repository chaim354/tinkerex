module Maker
  class FileAttachment < ApplicationRecord
    self.table_name = "maker_file_attachments"

    belongs_to :user
    belongs_to :attachable, polymorphic: true

    # Display order AND the source of truth for the vocabulary — the Files panel renders one
    # section per key, in this order, using these labels. ROLES derives from the keys so a
    # heading can never name a role the validation would reject.
    ROLE_LABELS = {
      "model"          => "Models",
      "image"          => "Images",
      "instructions"   => "Instructions",
      "document"       => "Documents",
      "vector"         => "Vector",
      "laser"          => "Laser",
      "cad_source"     => "CAD source",
      "gcode"          => "G-code",
      "source_archive" => "Archives",
      "other"          => "Other"
    }.freeze

    ROLES = ROLE_LABELS.keys.freeze

    # EVERY EXTENSION HERE MUST SATISFY `FilesController::EXT_RE` (/\A[a-z0-9]{1,8}\z/), because
    # FilesHelper::EXT_FAMILIES now derives the Files-page filter chips from this hash. An extension
    # the controller then drops renders a chip that links and silently does nothing. The warning
    # lives HERE, at the edit site, rather than beside EXT_FAMILIES where it used to: extensions are
    # added in this file, and whoever adds one has no reason to go looking two files away.
    # `markdown` is the current bound at exactly 8 characters. Pinned by files_helper_test.rb.
    ROLE_BY_EXT = {
      "stl" => "model", "3mf" => "model", "obj" => "model", "step" => "model", "stp" => "model",
      "png" => "image", "jpg" => "image", "jpeg" => "image", "gif" => "image", "webp" => "image", "bmp" => "image",
      "pdf" => "instructions", "zip" => "source_archive",
      # CNC. `nc`/`tap`/`ngc` are the router/mill dialects; without them a CNC-heavy project is
      # entirely "Other". They join `gcode` rather than getting a role of their own because they
      # ARE g-code — the folder split (cnc vs laser) is Maker::ProjectFolders' job, not a reason to
      # fragment the vocabulary.
      "gcode" => "gcode", "gco" => "gcode", "nc" => "gcode", "tap" => "gcode", "ngc" => "gcode",
      # Laser / 2D vector work. `lbrn2` is LASER, not vector: a LightBurn document is a machine
      # program, while svg/dxf are drawings you might cut on anything. That distinction is what
      # lets Maker::ProjectFolders put them in different folders — and the ONE vocabulary is where
      # it has to live, or the panel headings and the folders disagree.
      "svg" => "vector", "dxf" => "vector", "lbrn2" => "laser",
      # Editable CAD sources, as opposed to the exported meshes above. SolidWorks sits with Fusion
      # here because CLAUDE.md §1 and docs/research-format-processing.md treat them as one category
      # — proprietary, no FOSS parser, you open them in the tool that made them.
      "scad" => "cad_source", "f3d" => "cad_source", "fcstd" => "cad_source",
      "sldprt" => "cad_source", "sldasm" => "cad_source",
      # Text formats. DERIVED, not chosen here: Maker::Previews::Registry already routes
      # txt/md/markdown/json to TextThumb, and FilesHelper::EXT_FAMILIES already grouped txt/md/csv
      # as "Documents" — this is the union of the two sets the app already had.
      #
      # `pdf` is NOT here on purpose: it stays `instructions` because
      # Models::AttachmentsController dispatches ExtractPdfMetadataJob on that exact value.
      "txt" => "document", "md" => "document", "markdown" => "document",
      "json" => "document", "csv" => "document"
    }.freeze

    # Best-effort role from a filename's extension; unknown -> "other".
    def self.role_for(name)
      ROLE_BY_EXT.fetch(File.extname(name.to_s).downcase.delete("."), "other")
    end

    validates :node_id, presence: true
    validates :role, inclusion: { in: ROLES }
  end
end
