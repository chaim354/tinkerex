# WHICH VIEWER A FILE'S PAGE GETS, and the Gerber layer list that one of them needs — shared by
# FilesController#show (the maker's own file page) and Public::FilesController#view (a visitor's,
# stage 4, S4-5). ONE ANSWER: a public page that decided for itself which viewer a .gbrjob gets
# would be the one-condition-two-answers divergence §14a forbids, one surface at a time.
#
# IT IS A CONCERN RATHER THAN A SHARED SUPERCLASS FOR `FileDelivery`'S REASON, WHICH IS THE SAME
# REASON: FilesController descends from ApplicationController (session, `authenticate_user!`) and
# Public::FilesController from ActionController::Base, deliberately (§14d). A module is the only
# shape that reaches both.
#
# THE THREE EXTENSION CONSTANTS LIVE HERE AND FilesController RE-EXPOSES THEM, and that is not a
# style choice: constant lookup inside a module method is LEXICAL, so `MEASURABLE_EXTS` in
# #preview_kind below resolves to FilePreview::MEASURABLE_EXTS and nothing else. Left on the
# controller they would raise NameError the first time a .lbrn2 page rendered. The alias assignments
# on FilesController are the SAME frozen objects, never a second literal — `SAFE_INLINE_TYPES`
# three lines from them makes the identical move for the identical reason, and
# architecture_invariants_test.rb asserts object IDENTITY so a re-literal cannot pass.
module FilePreview
  extend ActiveSupport::Concern

  # Extensions whose detail page offers the interactive Measure view (measure_controller.js).
  #
  # THE SET IS THE FORMATS A GEOMETRY PAYLOAD CAN BE BUILT FOR, and it is written out rather than
  # derived from `Registry` — a renderer being registered says only that it makes a THUMBNAIL, and
  # ten of them do exactly that. Asking `payload_revision` instead would be no better: every
  # renderer answers it (via `Enqueue.revision_for`'s fallback), so the question it answers is not
  # the one being asked. Pinned by a test that drives the real `render(..., kind: "geometry")` for
  # each entry, so the list cannot claim a format the renderers do not actually measure.
  MEASURABLE_EXTS = %w[lbrn lbrn2 mage dxf svg].freeze

  # KiCad schematics and boards, rendered client-side by KiCanvas (stage 3, S3-2; the vendored
  # module in vendor/javascript/kicanvas.js, kicanvas_controller.js). WRITTEN OUT, exactly like
  # MEASURABLE_EXTS above, rather than added to `Maker::FileAttachment::ROLE_BY_EXT` — and that is
  # not an oversight, it is the one option that was never available: both extensions carry an
  # underscore and "kicad_sch" is 9 characters, so either one FAILS `EXT_RE`
  # (/\A[a-z0-9]{1,8}\z/) and an entry there would render a filter chip that links and silently
  # does nothing (files-preview.md's own warning; that file already lists these two by name among
  # the deliberate absences). Living outside ROLE_BY_EXT also means Registry.for/text? have never
  # heard of them, so they fall out of the thumbnail-poll cell and the type-filter chip row for
  # free — no second exclusion list to keep in step (§14d).
  KICANVAS_EXTS = %w[kicad_sch kicad_pcb].freeze

  # Gerber layers, Excellon drill files and the `.gbrjob` manifest, rendered client-side by
  # tracespace (the vendored module in vendor/javascript/tracespace.js, gerber_controller.js).
  #
  # DERIVED FROM `ROLE_BY_EXT`, NOT WRITTEN OUT — the OPPOSITE of KICANVAS_EXTS directly above, and
  # the difference is not style. Those two extensions CANNOT earn a `ROLE_BY_EXT` entry (an
  # underscore, nine characters — they fail `EXT_RE`), so a hand list there is the only option
  # available. Every extension in the `pcb` role PASSES `EXT_RE`, so it lives in the one vocabulary
  # and this constant reads it. A second literal list here would be exactly the drift §14d exists
  # to stop — and it would be worse than usual, because the filing rules, the type-filter chips and
  # this branch would then disagree about what a board's files even are.
  #
  # `.freeze` ON THE RESULT, NOT ON `ROLE_BY_EXT.select` ALONE: `select` on a frozen Hash returns a
  # NEW, unfrozen Hash, and `keys` a new Array — nothing here is frozen unless it is said.
  #
  # `Maker::GerberArchive` READS THIS TOO, to decide which MEMBERS of a zip are layers — so an
  # extension added to the `pcb` role starts counting inside an archive at the same moment it starts
  # counting loose in a folder, which is the point of there being one list.
  GERBER_EXTS = Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, role| role == "pcb" }.keys.freeze

  private

  # WHAT gerber_controller.js FETCHES on a file page: `[{ name:, url: }]`, name-ordered.
  #
  # AN ORDINARY LAYER IS ITSELF, AND THAT IS THE WHOLE PAGE. A `.gtl` file page shows the `.gtl`,
  # even when its folder holds the rest of the board — a page that quietly rendered the neighbours
  # would be showing something other than the file it is named for. The board's own pages are the
  # `.gbrjob`'s and a zipped export's (since 2026-09-06 there is no project-page panel rendering
  # a folder as a board; a loose set with no job file is one layer per page).
  #
  # A `.gbrjob` IS THE ONE EXCEPTION, because it is not a layer at all: it is JSON naming the set,
  # so the only honest render of it IS the board. Its layers are the siblings it names — resolved
  # through `Maker::GerberSets.job_layer_names`, its one caller — falling back to every pcb-role
  # sibling when the job names nothing this folder holds (see that method for why every failure
  # collapses to nil).
  # The manifest itself is never in the list: tracespace's Gerber parser would turn JSON into a junk
  # layer rather than an error.
  #
  # A JOB FILE'S SIBLINGS ARE RESOLVED IN THE OWNER'S NAME AND THE URL IS THE CALLER'S (stage 4,
  # S4-5). `user` is the node's OWNER, which on the public side is not the person making the
  # request — FileDelivery's own rule, and a visitor has no library to resolve a node_id against.
  # `url` builds the layer's fetch URL, because the private page's is /files/:id/blob/:name and a
  # visitor's is /u/:handle/:slug/files/:id/:name: the two cannot be one literal, and a public page
  # must additionally DROP a sibling the project does not permit. The lambda takes the NODE, not an
  # id, because both callers need its name for the trailing extension — tracespace decides what a
  # layer IS from that name (gerber_controller.js's header) and a download from the same URL should
  # arrive named correctly.
  #
  # ONE QUERY, AND ONLY FOR A `.gbrjob`.
  def gerber_job?(name) = File.extname(name).downcase.delete(".") == "gbrjob"

  def gerber_layers_for(user:, node:, url:)
    # `.compact` FOR THE SAME REASON THE JOB ARM `filter_map`s: `url` may refuse this node (the
    # public side's `permits?` arm answers nil), and `[nil]` is not empty — the viewer would draw
    # the board chrome around a null layer instead of saying there are none (found in review).
    return [ gerber_layer_for(node, url) ].compact unless gerber_job?(node.name)

    listed = Maker::GerberSets.job_layer_names(user:, node:)
    # BOUNDED, like every directory read on the file controller (FLAT_LIMIT): a job file sitting
    # loose in a very large folder must not load the whole folder into memory to find its layers.
    #
    # READ THROUGH `FilesController::` IN THE METHOD BODY, NOT ALIASED AT LOAD TIME LIKE THE THREE
    # LISTS ABOVE, AND THE DIFFERENCE IS LOAD ORDER RATHER THAN TASTE. `FLAT_LIMIT` is declared far
    # BELOW `include FilePreview` in that class, so a module-level `FLAT_LIMIT =
    # FilesController::FLAT_LIMIT` here runs while the class body is still executing and raises
    # `NameError: uninitialized constant FilesController::FLAT_LIMIT` whenever the controller is
    # the file autoloaded first — measured, not reasoned. The three lists go the other way (they
    # are declared here and aliased there) because they are this module's own vocabulary; the flat
    # listing's bound is the controller's, and there must be exactly one `2000`.
    siblings = user.nodes.present.where(parent_node_id: node.parent_node_id, kind: "file")
                   .order(:name).limit(FilesController::FLAT_LIMIT).to_a
                   .select { |n| GERBER_EXTS.include?(File.extname(n.name).downcase.delete(".")) }
                   .reject { |n| gerber_job?(n.name) }
    named = listed ? siblings.select { |n| listed.include?(n.name) } : siblings
    named = siblings if named.empty?
    named.sort_by(&:name).filter_map { |n| gerber_layer_for(n, url) }
  end

  # nil when the caller's `url` refuses this node — the public side's `permits?` arm. The private
  # side's lambda never answers nil, so the `filter_map` above is a no-op there.
  def gerber_layer_for(node, url)
    href = url.call(node)
    href && { name: node.name, url: href }
  end

  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    # BEFORE the :image branch, which .svg would otherwise take. An SVG is still shown as an image
    # at rest — the Measure branch uses it as its own poster (see files/viewers/_measure.html.erb)
    # — so this reorders which branch OWNS the page, not what the page displays when nothing is
    # clicked.
    #
    # Measure SUPERSEDES the static preview the way :model3d does for meshes, and for the same
    # reason: it is a button, not a replacement. The resting picture stays whatever the format's
    # own render is (LightBurn's and MillMage's are in colour; ours are outlines).
    return :measure if MEASURABLE_EXTS.include?(ext)

    # THE BROWSER'S LIST, NOT THE ROLE (tinkerex#285): a `.heic` is an image by role and falls
    # through to :thumbnail here, because Chrome cannot show its bytes and libvips can thumbnail them.
    return :image if Maker::FileAttachment.inline_image?(name)
    # PDF before the :thumbnail branch: the detail view EMBEDS the whole PDF for the browser's own
    # viewer (a full, scrollable preview), while pdf is ALSO in Registry for a page-1 grid thumbnail.
    return :pdf   if ext == "pdf"
    # BEFORE the :text branch, matching the comment on :measure/:image/:pdf above — though for a
    # different reason: these two can never reach that branch anyway (they are outside ROLE_BY_EXT,
    # so Maker::FileAttachment.text? has never heard of them). The early return is here so the
    # branch order reads the same way every other special-cased format's does, not because order
    # is load-bearing for THIS pair.
    return :kicanvas if KICANVAS_EXTS.include?(ext)
    # BEFORE :text, AND THAT ORDER IS LOAD-BEARING HERE IN A WAY THE :kicanvas LINE ABOVE'S IS NOT.
    # A Gerber layer is plain ASCII and `.gbrjob` is JSON, so both would read as source in a code
    # viewer — correct about the bytes and useless about the board. The RENDER is the page. (What
    # keeps them out of the text branch is only this early return: the `pcb` role is deliberately
    # not in TEXT_ROLES, so `Maker::FileAttachment.text?` answers false for them anyway — belt and
    # braces, with the role table as the real guard and this line as the one that reads.)
    return :gerber if GERBER_EXTS.include?(ext)
    # DERIVED FROM THE ONE VOCABULARY (§14d), not a second list beside it. This was an inline set
    # of 26 extensions sitting next to Maker::FileAttachment::ROLE_BY_EXT, and it had already
    # drifted: five of its entries (xml log ini cfg conf) were in no ROLE_BY_EXT entry at all, so
    # the two tables disagreed about what those files even were. Adding an extension is now a
    # one-line edit to ROLE_BY_EXT and nothing here has to hear about it.
    #
    # ORDER IS LOAD-BEARING and this line must stay below the three branches above: an .svg is a
    # text file too, and the measure/image/pdf branches own those pages on purpose.
    # ONE CALL, NOT AN OR OF TWO CONSTANTS. This spelled out `TEXT_ROLES.include?(role_for(name))
    # || TEXT_EXTS.include?(ext)` until 2026-08-26 — correct, but it made THIS the only place the
    # predicate existed, so `Maker::Previews::Registry` could not reuse it and hand-listed four
    # extensions instead (§14d drift, one layer down). `Maker::FileAttachment.text?` is now the
    # one definition and the Registry derives from the same constant behind it.
    return :text  if Maker::FileAttachment.text?(name)
    # Formats the browser can parse itself -> the interactive client-side 3D viewer
    # (modelviewer_controller.js), which supersedes the static thumbnail on the detail page. The
    # thumbnail is still generated (Registry has most of these) and serves as the viewer's fallback
    # poster — the same "a poster, not a replacement" relationship the Registry comment describes.
    #
    # DERIVED FROM THE ONE VOCABULARY, not a list beside it — the same collapse the `:text` branch
    # above got on 2026-08-25, and for the same reason: ModelsController#show offers the SAME
    # viewer for a model's files off the SAME constant, so a second literal here would let the file
    # page and the model page disagree about which formats are viewable.
    #
    # THIS BRANCH NOW TAKES step/stp/iges/igs FROM `:thumbnail` BELOW, which is the visible change:
    # a CAD file's page was a static PNG and is now that PNG with a "View in 3D" button over it.
    return :model3d if Maker::FileAttachment::VIEWABLE_3D_EXTS.include?(ext)
    # A file we can render a server-side thumbnail for (step, stp, iges, igs, ...) but
    # that the browser can't display raw. The :thumbnail branch in files/viewers/_static.html.erb
    # reads the strict local `thumbnail`.
    return :thumbnail if Maker::Previews::Registry.for(ext)
    :other
  end
end
