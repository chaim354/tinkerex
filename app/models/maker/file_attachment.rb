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
      "code"           => "Code",
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
      # Laser / 2D vector work. `lbrn2` is LASER, not vector: `.lbrn2` is a LightBurn project —
      # vector shapes plus per-layer laser settings — while svg/dxf are drawings you might cut on
      # anything. That distinction is what lets Maker::ProjectFolders put them in different
      # folders — and the ONE vocabulary is where it has to live, or the panel headings and the
      # folders disagree.
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
      "json" => "document", "csv" => "document",
      # Source code, config and build files — the "firmware + software" half of a project (§1),
      # which until now was filed entirely as `other`. Three groupings are decisions rather than
      # observations. `h`/`hpp` sit with c/cpp because a firmware tree is headers and sources
      # together, and splitting them would put one project's files in two folders. The config and
      # build formats (`toml ini cfg conf yml yaml cmake`) are here rather than under `document`
      # because they belong beside the code they configure — Maker::ProjectFolders is what that
      # choice actually decides, and `document` means `docs/`, where the READMEs go. `log` is here
      # for the same reason: a build or serial log is an artefact of running the code, not a
      # document someone wrote.
      "c" => "code", "h" => "code", "cpp" => "code", "cc" => "code", "hpp" => "code",
      "ino" => "code", "py" => "code", "rb" => "code", "js" => "code", "ts" => "code",
      "rs" => "code", "go" => "code", "sh" => "code", "lua" => "code", "sql" => "code",
      "html" => "code", "css" => "code", "xml" => "code", "log" => "code",
      "toml" => "code", "ini" => "code", "cfg" => "code", "conf" => "code",
      "yml" => "code", "yaml" => "code", "cmake" => "code"
    }.freeze

    # Roles whose files are TEXT a browser can display as source. Consulted by
    # FilesController#preview_kind, which carried its own inline list of 26 extensions until
    # 2026-08-25 — a second vocabulary beside this one, and exactly the drift
    # FilesHelper::EXT_FAMILIES was rewritten to end (2026-07-29, after two lists disagreed about
    # `.svg` for months; §14d). Five of that list's entries — xml log ini cfg conf — were in no
    # ROLE_BY_EXT entry at all, which is how a second table drifts: silently, in the direction of
    # the list nobody is looking at.
    #
    # `instructions` is deliberately ABSENT. A pdf is text-ish only in the sense of not being an
    # image, and the detail page embeds the browser's own viewer for it. The guard for that is
    # asserted on this CONSTANT (file_attachment_test.rb) rather than through preview_kind:
    # measured, adding `instructions` here leaves `preview_kind("manual.pdf") == :pdf` green — the
    # `:pdf` branch returns first — and reaches the derived sweep only as a contradiction that
    # reports pdf failing to be text, which is not the rule anyone broke.
    TEXT_ROLES = %w[document code gcode].freeze

    # Extensions whose files are TEXT even though their ROLE is not a text role — because ROLE and
    # CONTENT TYPE are two different questions and one file can answer them differently.
    #
    # `scad` is the case that forced this, and it is not a loophole in §14d's one-vocabulary rule.
    # That rule forbids a second TABLE in a second PLACE (FilesController carried its own inline
    # list of 26 extensions until 2026-08-25, and it had already drifted). This constant lives here,
    # beside ROLE_BY_EXT and TEXT_ROLES, in the one file that owns the vocabulary — and it exists
    # because OpenSCAD source is genuinely BOTH: it is `cad_source` for FILING (it belongs in
    # `cad/` beside the `.f3d` it sits next to, which is what Maker::ProjectFolders
    # decides) and it is plain source code for VIEWING. The two other candidate fixes are both
    # worse and both were rejected: adding `cad_source` to TEXT_ROLES would render `.f3d`,
    # `.sldprt` and `.sldasm` — binary formats — as text, a visible bug on the main deployment; and
    # a per-extension branch inside `preview_kind` would rebuild the second vocabulary in the very
    # method that collapsed it.
    #
    # STARTS AT ONE ENTRY AND SHOULD STAY SMALL. Every addition is a claim that some role's files
    # are mostly NOT text while this extension's are, which is a narrow thing to be true. If this
    # list grows past a handful, the role table is the thing that is wrong.
    TEXT_EXTS = %w[scad].freeze

    # Best-effort role from a filename's extension; unknown -> "other".
    def self.role_for(name)
      ROLE_BY_EXT.fetch(File.extname(name.to_s).downcase.delete("."), "other")
    end

    # LightBurn and MillMage (same vendor, same convention) write a rescue copy of a project beside
    # it as `<stem>_backup.<ext>` — `traymammon-1_backup.lbrn2`, `metal test 1_backup.lbrn2`. They
    # are real files in the library and stay there; what they are not is something a project's Files
    # panel should put at eye level next to the design they shadow.
    #
    # BOTH HALVES ARE REQUIRED, and the extension half is what keeps this narrow: a user's own
    # `battery_backup.stl` or `db_backup.zip` is not a LightBurn rescue copy and must not be filed
    # as one. The cost of the remaining false positive — someone who genuinely names a LightBurn
    # file `..._backup.lbrn2` — is that it renders one section lower, in a group they can open.
    #
    # `.lbrn` (v1) is included alongside `.lbrn2` even though only `.lbrn2` is in ROLE_BY_EXT: the
    # question here is "did LightBurn write this as a backup", which the older extension answers the
    # same way, and getting it wrong costs a stray tile rather than a misfiled role.
    BACKUP_EXTS = %w[lbrn lbrn2 mage].freeze
    BACKUP_SUFFIX = "_backup".freeze

    def self.backup?(name)
      base = File.basename(name.to_s).downcase
      ext = File.extname(base).delete(".")
      return false unless BACKUP_EXTS.include?(ext)

      File.basename(base, ".#{ext}").end_with?(BACKUP_SUFFIX)
    end

    validates :node_id, presence: true
    validates :role, inclusion: { in: ROLES }
  end
end
