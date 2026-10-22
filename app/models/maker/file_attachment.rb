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
      # A WORKBOOK, AND ITS OWN ROLE RATHER THAN `document` (2026-10-21). `document` is a TEXT role
      # (TEXT_ROLES below), and every reader of that list — the file page's code viewer and the
      # TextThumb registration — would have treated an `.xlsx`, which is a zip, as source text. It
      # files into the same `docs/` folder as `document` (ProjectFolders), the way `instructions`
      # already does; what differs is only that its bytes are not text.
      "spreadsheet"    => "Spreadsheets",
      "vector"         => "Vector",
      "laser"          => "Laser",
      "cad_source"     => "CAD source",
      "code"           => "Code",
      "gcode"          => "G-code",
      # THE CNC PROJECT FILE, AS OPPOSED TO ITS OUTPUT (stage 4, S4-2). `.mage` is MillMage's
      # editable project — the CNC sibling of `.lbrn2` — and it files into the SAME folder as
      # g-code (`cnc/`) while keeping its own role, for the reason `vector`/`laser` are two roles
      # sharing nothing: a role is also what Maker::ModelIntake denies a model and what a panel
      # heading says. Folding it into `gcode` would make "G-code" the label on a file that is not
      # g-code; giving it its own folder would scatter one workbench across two directories.
      "cnc_design"     => "CNC design",
      # The fabrication outputs of a PCB — Gerber layers, the Excellon drill file, the `.gbrjob`
      # manifest. "PCB" rather than "Gerber" because the role holds the drill files too, and a
      # board's set is what a maker thinks of as one thing.
      "pcb"            => "PCB",
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
      # 3D MODELS — meshes and the exchange/CAD formats that arrive as finished geometry. The set
      # widened on 2026-09-06 with the Online3DViewer slice: what the browser can now SHOW and what
      # the F3D subprocess can now make a thumbnail of both grew, and a file the app can render is
      # a file it should file as a model rather than sweep into "Other".
      #
      # A ROLE IS WHERE A FILE FILES, NOT WHETHER IT RENDERS, which is why this list and
      # VIEWABLE_3D_EXTS below are two lists and not one. `fcstd` is VIEWABLE (the OpenCascade
      # importer reads it) and stays `cad_source`, because it is a FreeCAD project you go back and
      # edit — it belongs in `cad/` beside the `.f3d`, and moving it would move real files on the
      # user's NAS. `svg` is viewable too (the engine extrudes it) and stays `vector` for the same
      # reason plus a louder one: it is the Measure view's page.
      "stl" => "model", "3mf" => "model", "obj" => "model", "step" => "model", "stp" => "model",
      "gltf" => "model", "glb" => "model", "ply" => "model", "off" => "model", "dae" => "model",
      "wrl" => "model", "3ds" => "model", "fbx" => "model", "3dm" => "model", "amf" => "model",
      "iges" => "model", "igs" => "model", "brep" => "model",
      "png" => "image", "jpg" => "image", "jpeg" => "image", "gif" => "image", "webp" => "image", "bmp" => "image",
      # An iPhone original and a scanner's TIFF (2026-09-08, tinkerex#285): images by ROLE — they file
      # into images/, the photo door takes them, libvips thumbnails them — and NOT in
      # INLINE_IMAGE_EXTS below, because no browser this app targets renders either as <img> bytes.
      "heic" => "image", "heif" => "image", "tif" => "image", "tiff" => "image",
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
      # `.lbrn` IS LIGHTBURN v1 AND IS THE SAME KIND OF FILE AS `.lbrn2` (stage 4, S4-2). It has
      # had a THUMBNAIL and a Measure page since the Lbrn2 renderer landed (Registry claims both
      # extensions, and MEASURABLE_EXTS lists both) — the only thing it lacked was a role, so a
      # v1 file filed into `other/` while the v2 file beside it filed into `laser/`. `.ai` is
      # Illustrator: `vector` beside `.svg`/`.dxf`, because that is what it is and where a maker
      # keeps it (share, 2026-09-07: 25 files, every one of them in `other/`).
      "svg" => "vector", "dxf" => "vector", "ai" => "vector",
      "lbrn2" => "laser", "lbrn" => "laser",
      # MillMage. See ROLE_LABELS' own note for why this is not `gcode`.
      "mage" => "cnc_design",
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
      # An Excel workbook (2026-10-21): the file page shows it as a grid and saves basic edits back
      # (Files::SpreadsheetsController, Maker::Xlsx). `xlsm`/`xls`/`ods` are deliberately absent —
      # a macro workbook, the pre-2007 binary format and OpenDocument are three other formats the
      # editor does not read, and naming them here would promise a viewer they do not get.
      "xlsx" => "spreadsheet",
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
      "diff" => "code", "patch" => "code",
      # PCB FABRICATION OUTPUTS (the Gerber preview slice). Every one of these satisfies `EXT_RE`
      # (/\A[a-z0-9]{1,8}\z/) — all lowercase alphanumerics, the longest being `gbrjob` at six — so
      # unlike `kicad_sch`/`kicad_pcb` two paragraphs down they CAN live here, and they must: this
      # is where a file's role is decided, and a role is what files a board's layer set into one
      # folder (`pcb/`) instead of scattering it through `other`.
      #
      # THREE FAMILIES, ONE ROLE, and the grouping is the decision. The RS-274X layers are the
      # vendor extensions every CAM export uses — `gbr` (generic), the KiCad/Altium pairs
      # `gtl`/`gbl` (copper), `gts`/`gbs` (solder mask), `gto`/`gbo` (silkscreen), `gtp`/`gbp`
      # (solder paste), the outline `gko`, the mechanical/plane layers `gm1 gm2 gm3 gp1 gp2`, the
      # inner-copper `g1 g2 g3 g4`, and Altium's `gd1`/`gg1` (drill drawing and guide). The DRILL
      # files are Excellon: `drl` (KiCad, Altium) and `xln` (Eagle). The MANIFEST is `gbrjob`, the
      # Gerber job file — JSON naming the set, which is why it is `pcb` and not `document`: it is
      # part of the fabrication package a board house is handed, and filing it away from the layers
      # it names would split one deliverable in two.
      #
      # `gbrjob` IS ALSO WHY THIS ROLE IS NOT `TEXT_ROLES`-ADJACENT. A Gerber layer is plain ASCII
      # and so is the job file, but the page that matters for all of them is the RENDER, not the
      # source — `FilesController#preview_kind` returns `:gerber` before it reaches the text
      # branch, and adding `pcb` to TEXT_ROLES would put a source viewer where the board should be
      # and register a TextThumb renderer for a file whose thumbnail nobody wants.
      #
      # DELIBERATELY ABSENT: `.xnc` — it is a real Excellon extension (KiCad writes one) but it is
      # also the extension of nothing else, and tracespace identifies a drill layer from the
      # FILENAME, so adding it later is a one-line edit here: rows already attached as `other`
      # follow by `classify_unclassified!` below (F-S33-1). What it does not reach is an existing
      # user's FILING map: without the top-up migration every widening carries
      # (`SeedPcbFilingRules`' shape), a user seeded earlier files `.xnc` into `other/`. It is left
      # out only because no fixture or live library in this repo has produced one; add it the day
      # one does. `.gbp` above is the solder-paste layer, NOT the `.gbp` some backup tools write.
      "gbr" => "pcb", "gtl" => "pcb", "gbl" => "pcb", "gts" => "pcb", "gbs" => "pcb",
      "gto" => "pcb", "gbo" => "pcb", "gtp" => "pcb", "gbp" => "pcb", "gko" => "pcb",
      "gm1" => "pcb", "gm2" => "pcb", "gm3" => "pcb", "gp1" => "pcb", "gp2" => "pcb",
      "g1" => "pcb", "g2" => "pcb", "g3" => "pcb", "g4" => "pcb",
      "gd1" => "pcb", "gg1" => "pcb", "drl" => "pcb", "xln" => "pcb", "gbrjob" => "pcb"
    }.freeze

    # WHICH EXTENSIONS ARE PICTURES, DERIVED FROM THE ONE VOCABULARY (stage 4, S4-8). Read by the
    # `photo_of` door's file picker so a maker is offered pictures and not their whole library.
    # Derived rather than written out for the reason §14d gives about every extension list in this
    # app: a second copy is a second thing to forget when a format is added, and this one would
    # silently offer nothing new.
    #
    # THE PICKER'S FILTER IS A CONVENIENCE, NEVER THE REFUSAL — lib/file_chooser.js says so in as
    # many words. Files::LinksController asks `role_for` again on the server, through this same
    # hash, so a hand-posted node id is refused whatever the picker showed.
    IMAGE_EXTS = ROLE_BY_EXT.filter_map { |ext, role| ext if role == "image" }.freeze

    # WHAT THE TOP BAR'S UPLOAD CALLS A MODEL when it decides whether a zip unpacks (2026-10-21,
    # lib/zip_unpack.js) — DERIVED, like IMAGE_EXTS above, so a model extension added to ROLE_BY_EXT
    # makes a zip holding it unpack with no second edit. The importer's own five-entry MODEL_EXT
    # (importer_controller.js) is display-only and is not this.
    MODEL_EXTS = ROLE_BY_EXT.filter_map { |ext, role| ext if role == "model" }.freeze

    # WHAT A BROWSER CAN SHOW AS `<img>` BYTES — NOT THE `image` ROLE, and since 2026-09-08
    # (tinkerex#285) the two lists differ: `.heic`/`.heif`/`.tif`/`.tiff` are images by role and no
    # browser this app targets renders them inline, while `ico` renders inline and is nobody's image.
    # Every hero that embeds raw bytes and the file page's :image branch ask THIS predicate; a
    # role-keyed check there rendered a broken picture for a `.heic` cover, where the thumbnail
    # branch (libvips decodes both) shows it correctly.
    INLINE_IMAGE_EXTS = %w[png jpg jpeg gif webp bmp ico].freeze

    def self.inline_image?(name)
      INLINE_IMAGE_EXTS.include?(File.extname(name.to_s).downcase.delete("."))
    end

    # PHOTO_EXTS — the image formats a CAMERA writes. A tile of one is cropped to fill its stage
    # (`.thumb.photo`); PNG, GIF, WebP, BMP and TIFF keep `contain`, being more often screenshots,
    # renders or scans, where a crop cuts off the point. A DISPLAY choice only: the role stays
    # "image" for all ten (ROLE_BY_EXT), and this list must stay a subset of IMAGE_EXTS
    # (file_attachment_test.rb). Structural redesign slice 3; slice 1 styled `.thumb.photo`.
    # A LITERAL, NOT AN INTERSECTION: `IMAGE_EXTS & %w[...]` is a subset by construction, so the
    # subset test could never fail and a typo would vanish silently (found in review).
    PHOTO_EXTS = %w[jpg jpeg heic heif].freeze

    def self.photo?(name) = PHOTO_EXTS.include?(File.extname(name.to_s).delete(".").downcase)

    # EVERY EXTENSION THE 3D VIEWER CAN OPEN — the ONE list, read by BOTH doors that offer it
    # (`FilesController#preview_kind`'s `:model3d` branch and `ModelsController#show`'s hero
    # switcher). Each controller carried its own copy of `%w[stl 3mf obj]` until 2026-09-06, which
    # is the second-table shape §14d exists to stop: the file page and the model page would have
    # disagreed about which of a model's files are viewable, silently and in one direction only.
    #
    # IT IS THE SHIPPED IMPORTERS' OWN LIST, checked against online-3d-viewer 0.18.0's
    # `source/engine/import/importer.js` rather than its README — the engine registers importers for
    # `3dm 3ds 3mf amf bim brep brp dae fbx fcstd glb gltf ifc iges igs obj off ply step stl stp svg
    # wrl`, and this is that set minus four deliberate absences:
    #
    #   `ifc`  — its importer is web-ifc, MPL-2.0, which bin/build-o3dv does not ship (§9). Listing
    #            it would open a viewer that can only ever fail.
    #   `svg`  — viewable (the engine extrudes it), but `.svg` is the MEASURE view's page and
    #            `preview_kind` returns `:measure` for it several branches earlier. Listing it here
    #            would state a claim the ordering silently overrides.
    #   `bim`  — not a maker format; nothing in this app files one.
    #   `brp`  — upstream's alias for `brep`. One spelling per format: F3D's reader lists `brep`
    #            only, so a `.brp` would view in the browser and have no server thumbnail.
    #
    # THE CAD ENTRIES NEED THE WASM IMPORTER. `step`/`stp`/`iges`/`igs`/`brep`/`fcstd` go through
    # OpenCascade and `3dm` through rhino3dm — separate files under `public/o3dv/<version>/`, so a
    # deployment that lost that directory shows the thumbnail poster for those six rather than a
    # broken page (the controller's failure contract).
    VIEWABLE_3D_EXTS = %w[
      stl 3mf obj gltf glb ply off dae wrl 3ds fbx 3dm amf step stp iges igs brep fcstd
    ].freeze

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

    # STORED ROLES FOLLOW THIS VOCABULARY BY ONE RULE, AND THIS IS ITS ONE OWNER (F-S33-1). `role`
    # is written with the row, from `role_for` at the attach doors, so a row written before
    # ROLE_BY_EXT learned its extension says `other` until something rewrites it. For seven
    # widenings that was a hand-copied data migration (eight migrations rewrite stored roles; the
    # eighth is the one RE-classification, `lbrn2` vector -> laser); two widenings never got one
    # (`nc`/`tap`/`ngc`, and the Gerber layers, whose SeedPcbFilingRules seeds filing rules only),
    # so an electronics project showed a photo where its board should be. This re-reads ONE user's
    # `other` rows against TODAY's table and rewrites those it now names, which makes the row half
    # of a widening the table edit and nothing else. Maker::ClassifyAttachmentRolesJob runs it daily
    # for every user and `rake maker:classify_roles` runs it on demand. -> rows rewritten.
    #
    # `other` IS THE ONE VALUE IT TOUCHES, and it means "nothing classified this name when the row
    # was written". The schema keeps no chosen-versus-derived column, so every other value is a
    # decision and is never rewritten: the photo door's `image` on whatever node it is handed, a v1
    # client's posted role. A client that posts `other`, or omits the role and gets the column
    # default, is given the vocabulary's answer within a day, the same overwrite all seven
    # from-`other` migrations made. What it cannot reach, by construction: a RE-classification (the
    # `lbrn2` vector -> laser move) and an extension REMOVED from the table. Each still needs a
    # migration.
    #
    # The name is read off the row's OWN user's node (node_ids are unique per user, not globally),
    # and a row whose node is gone drops out of the join. One query per user plus one UPDATE per
    # role with work to do, so zero writes in steady state. `update_all` skips the inclusion
    # validation, which is safe only while every ROLE_BY_EXT value is one of ROLES; the
    # table-derived test in file_attachment_classify_test.rb asserts every row it rewrites still
    # validates.
    def self.classify_unclassified!(user)
      unclassified = user.maker_file_attachments.where(role: "other")
      names = unclassified.joins("JOIN nodes ON nodes.user_id = maker_file_attachments.user_id " \
                                 "AND nodes.node_id = maker_file_attachments.node_id")
                          .pluck("maker_file_attachments.id", "nodes.name")
      names.group_by { |_id, name| role_for(name) }.except("other")
           .sum { |role, rows| unclassified.where(id: rows.map(&:first)).update_all(role:) }
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
    # `.lbrn` (v1) sits here beside `.lbrn2` and `.mage`, and since stage 4, S4-2 all three are in
    # ROLE_BY_EXT too — this list predates that and was written when only `.lbrn2` was. It stays a
    # list of its own regardless: the question here is "did LightBurn/MillMage write this as a
    # rescue copy", which is about the vendor's naming convention, not about a role.
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
