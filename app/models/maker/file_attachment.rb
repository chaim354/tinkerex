module Maker
  class FileAttachment < ApplicationRecord
    self.table_name = "maker_file_attachments"

    belongs_to :user
    belongs_to :attachable, polymorphic: true

    # Display order AND the source of truth for the vocabulary: the Files page's type filter reads
    # it, and it seeds the per-user filing rules (S3-1); the project panel groups by the folder's
    # real subfolders since stage 3, not by these keys. ROLES derives from the keys so a
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
      # `rst`/`tex` join `md` as prose someone WROTE, and `tsv` joins `csv` as tabular data —
      # all four file into `docs/` for the same reason those already do.
      "txt" => "document", "md" => "document", "markdown" => "document",
      "json" => "document", "csv" => "document", "tsv" => "document",
      "rst" => "document", "tex" => "document",
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
      "yml" => "code", "yaml" => "code", "cmake" => "code",
      # ADDED 2026-08-26, when the previews arc found these were text the app did not KNOW was
      # text: `role_for` answered "other", so they got no source viewer, no thumbnail and no
      # filing. Each is here on the same argument the block above already makes, so the folder
      # decision is inherited rather than new — they belong beside the code they are part of.
      # Languages: `java`/`kt` (and `kt` covers Kotlin build scripts), `swift`, `cs`, `php`,
      # `pl`, `jl`, `r`. Web source: `jsx`/`tsx`/`vue`/`svelte`. Windows shell, siblings of `sh`:
      # `bat`, `ps1`. Build, siblings of `cmake`: `mk`, `gradle`. Firmware and HDL, which is the
      # "hardware + firmware" half of §1 and the reason a maker app carries them at all: `asm`,
      # `s`, `v`, `vhd`. And `diff`/`patch`, which are artefacts of EDITING code exactly as `log`
      # is an artefact of RUNNING it — the argument that entry already carries.
      #
      # DELIBERATELY ABSENT, each for a reason that is not "we forgot":
      #   `m`  — genuinely ambiguous (Objective-C, MATLAB, Mathematica). Text either way, but the
      #          role table is read as a claim about what a file IS, and this one cannot make it.
      #   `properties`, `editorconfig`, `gitignore`, `dockerfile`, `kicad_pcb`, `kicad_sch` —
      #          they FAIL `FilesController::EXT_RE` (/\A[a-z0-9]{1,8}\z/): too long, or an
      #          underscore. The warning at the top of this hash is not decoration; an entry that
      #          fails it renders a filter chip that links and silently does nothing.
      #   `.env`, `Makefile`, `Dockerfile`, `LICENSE` — these have NO EXTENSION at all
      #          (`File.extname(".env")` is `""`), so no entry in an extension table can ever
      #          reach them. Covering them needs a basename rule, which is a different mechanism.
      "java" => "code", "kt" => "code", "swift" => "code", "cs" => "code",
      "php" => "code", "pl" => "code", "jl" => "code", "r" => "code",
      "jsx" => "code", "tsx" => "code", "vue" => "code", "svelte" => "code",
      "bat" => "code", "ps1" => "code", "mk" => "code", "gradle" => "code",
      "asm" => "code", "s" => "code", "v" => "code", "vhd" => "code",
      "diff" => "code", "patch" => "code"
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

    # TEXT FILES THAT HAVE NO EXTENSION AT ALL, matched on the WHOLE basename, downcased.
    #
    # `File.extname("LICENSE")` is `""` and `File.extname(".gitignore")` is `""` too (a leading dot
    # with no second dot is not an extension) — probed, not assumed — so NO entry in an extension
    # table can ever reach these files. They answered `role_for -> "other"` and `preview_kind ->
    # :other`, which rendered "No inline preview for this file type." over a plain text file. On the
    # deployed share library that is `LICENSE` x6, `Makefile`/`makefile` x7 and `README` x3, plus
    # the dotfile configs.
    #
    # A SEPARATE AXIS FROM `TEXT_EXTS`, NOT A SECOND COPY OF IT. `TEXT_EXTS` answers "this role is
    # not text but this extension is" (`.scad`). This answers "there is no extension to ask about".
    # Both live here, beside `ROLE_BY_EXT`, which is what §14d's one-vocabulary rule actually
    # requires — one PLACE, not one shape.
    #
    # BOTH CASES OF `Makefile` ARE REACHED BY DOWNCASING, not by listing two spellings: the live
    # library really does contain both `Makefile` and `makefile`.
    #
    # THIS DOES NOT GIVE THEM A ROLE, AND THAT IS DELIBERATE — the same split `.scad` already
    # carries. `role_for("LICENSE")` stays `"other"`, so `Maker::ProjectFolders` keeps filing it
    # where it files it today. Making `LICENSE` a `document` would MOVE it into `docs/` on the
    # user's NAS, which is a change to their files, not to a preview, and nobody asked for it.
    TEXT_BASENAMES = %w[
      license licence copying notice patents authors contributors credits maintainers owners
      readme changelog changes history news todo install usage manifest version
      makefile gnumakefile dockerfile containerfile rakefile gemfile guardfile procfile
      justfile vagrantfile brewfile capfile
      .gitignore .gitattributes .gitmodules .gitkeep .dockerignore .editorconfig .clang-format
      .clang-tidy .npmrc .nvmrc .ruby-version .node-version .prettierrc .eslintrc .babelrc
    ].freeze

    # EVERY EXTENSION THIS APP CONSIDERS TEXT — the union of the text roles' extensions and the
    # role-mismatched ones above, DERIVED so the two members can never disagree about it.
    #
    # IT EXISTS BECAUSE THE PREDICATE HAD TWO READERS AND ONLY ONE OF THEM EVER GOT WRITTEN.
    # `FilesController#preview_kind` was collapsed onto TEXT_ROLES/TEXT_EXTS on 2026-08-25, but
    # `Maker::Previews::Registry` went on routing a HAND-WRITTEN four entries (txt md markdown
    # json) to TextThumb — so 33 of the 37 extensions the vocabulary called text got the source
    # viewer on the detail page and a BLANK CELL in the grid. Measured, not estimated: `.rb`,
    # `.py`, `.gcode`, `.yml`, `.csv`, `.scad`, every `.c` and `.h`. That is the same second-table
    # drift §14d exists to stop, one layer down from where it was fixed, and it survived because
    # the two tables answer questions that SOUND different ("what does the page render?" vs "what
    # can we make a picture of?") while being the same question about the same files.
    #
    # `Maker::Previews::TextThumb::EXTENSIONS` IS THIS CONSTANT, which is what makes
    # `renderer_contract_test.rb` pin the derivation for free: it already asserts every renderer's
    # own EXTENSIONS resolve back through `Registry.for`, so a format renderer that ever claims a
    # text extension turns that test red instead of silently shadowing the thumbnail.
    TEXT_EXTENSIONS = (ROLE_BY_EXT.select { |_ext, role| TEXT_ROLES.include?(role) }.keys + TEXT_EXTS)
                      .uniq.sort.freeze

    # Is this filename's content TEXT? THE ONE definition — `preview_kind`'s `:text` branch and the
    # TextThumb registration are the same question asked by two layers, and they used to answer it
    # with two different tables.
    #
    # EXTENSION FIRST, THEN BASENAME, and the order costs nothing because a name cannot satisfy
    # both: anything in `TEXT_BASENAMES` has no extension to look up (`README.md` has one and is
    # covered by the extension arm, which is why `readme` being in the basename list is not a
    # duplicate of `md` being in the extension list — they match different files).
    #
    # A name that is in NEITHER is still false, which is the honest answer rather than a guess: an
    # extensionless binary exists and rendering it as text is mojibake, the same argument that keeps
    # `.f3d` out of `TEXT_EXTS`.
    def self.text?(name)
      TEXT_EXTENSIONS.include?(File.extname(name.to_s).downcase.delete(".")) ||
        TEXT_BASENAMES.include?(File.basename(name.to_s).downcase)
    end

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
