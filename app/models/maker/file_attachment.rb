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
      "vector"         => "Vector",
      "cad_source"     => "CAD source",
      "gcode"          => "G-code",
      "source_archive" => "Archives",
      "other"          => "Other"
    }.freeze

    ROLES = ROLE_LABELS.keys.freeze

    ROLE_BY_EXT = {
      "stl" => "model", "3mf" => "model", "obj" => "model", "step" => "model", "stp" => "model",
      "png" => "image", "jpg" => "image", "jpeg" => "image", "gif" => "image", "webp" => "image", "bmp" => "image",
      "pdf" => "instructions", "gcode" => "gcode", "gco" => "gcode", "zip" => "source_archive",
      # Laser / 2D vector work. Without these a laser-heavy project is mostly "Other".
      "svg" => "vector", "dxf" => "vector", "lbrn2" => "vector",
      # Editable CAD sources, as opposed to the exported meshes above. SolidWorks sits with Fusion
      # here because CLAUDE.md §1 and docs/research-format-processing.md treat them as one category
      # — proprietary, no FOSS parser, you open them in the tool that made them.
      "scad" => "cad_source", "f3d" => "cad_source", "fcstd" => "cad_source",
      "sldprt" => "cad_source", "sldasm" => "cad_source"
    }.freeze

    # Best-effort role from a filename's extension; unknown -> "other".
    def self.role_for(name)
      ROLE_BY_EXT.fetch(File.extname(name.to_s).downcase.delete("."), "other")
    end

    validates :node_id, presence: true
    validates :role, inclusion: { in: ROLES }
  end
end
