require "test_helper"

module Web
  # A RENDERED PAGE MUST NEVER CONTAIN ERB DELIMITERS, AND THE TEMPLATES MUST BALANCE.
  #
  # THIS EXISTS BECAUSE IT HAPPENED, and because nothing else in the suite could see it. An ERB
  # comment ends at its FIRST `%>`, so a comment that quotes a snippet containing one terminates
  # early and prints its own remaining prose into the document. The page still parses, every
  # `assert_select` in the suite still passes — they ask about ELEMENTS, and this defect produces a
  # TEXT NODE — and the only symptom is three lines of a code comment sitting in the middle of the
  # user's Files page. Caught by opening the page in a browser, which is the argument for probing
  # over reasoning in one screenshot.
  #
  # THERE ARE TWO GUARDS HERE BECAUSE THE DEFECT HAS TWO SHAPES, AND EACH GUARD IS BLIND TO THE
  # OTHER'S. Both were reproduced against real Erubi before this file was written:
  #
  #   ONE quoted snippet  — `<%# … as <%= raw(svg) %> because … %>`
  #     renders  " because\n    scripts in the document would then run. … %>"
  #     The trailing `%>` LEAKS, so the RENDERED-OUTPUT check below catches it.
  #     The source still counts 2 openers and 2 closers, so the BALANCE check does not.
  #
  #   TWO quoted snippets — `<%# … write <%= a %> rather than … the <%= b %>`
  #     renders  " rather than … the BBB"
  #     The second opener swallows the comment's own terminator, so the output contains NO
  #     delimiter at all and the rendered-output check is GREEN. The source counts 3 openers
  #     against 2 closers, so only the BALANCE check catches it.
  #
  # THE BALANCE CHECK IS NOT THE STATIC SCAN THIS FILE ONCE REJECTED. That one had to guess whether
  # the text after a comment's terminator was meant to be markup or prose, which is why asserting on
  # the rendered output replaced it. This one guesses nothing: it counts two literal tokens and
  # compares the totals. It is also the only guard here that reaches a template no request renders.
  #
  # A DERIVED-NEEDLE SCAN WAS PROPOSED AND IS UNSOUND — do not build it. Extracting the body of a
  # `<%# … %>` and searching the response for it can never match, in EITHER shape above: the
  # extracted body is the material ERB CONSUMED, and the leak is the material AFTER it. Probed both
  # ways; the needle was absent from the output every time. A needle set with zero true positives
  # has zero false positives, which is what makes that measurement look good.
  #
  # BACKEND-NEUTRAL: the fixtures carry BOTH `current_version_id` (chunk's content_token) and
  # `content_hash` (share's and S3's), so every page here renders the same branches on all three
  # legs. Verified by running the three `LIBRARY_BACKEND` legs and comparing counts.
  class TemplateHygieneTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Directories the request sweep is not expected to reach, each for a stated reason. This is the
    # ONLY escape from the coverage assertion below, and it is deliberately coarse and few:
    # everything outside it must be swept or the test fails.
    #
    #   users/          — Devise's own pages, rendered LOGGED OUT; this sweep is a signed-in session.
    #   pwa/            — a manifest, not HTML; it has no ERB comments and no prose to leak.
    #   active_storage/ — an engine template we neither own nor edit.
    #
    # `layouts/` WAS EXCUSED HERE AND DELIBERATELY IS NOT ANY MORE — do not add it back by reflex.
    # The excuse only ever covered the two MAILER layouts, and those were applied to nothing
    # (`Devise::Mailer._layout` measured nil, because nothing set `config.parent_mailer`) and have
    # been deleted. Both layouts that remain are swept: `layouts/application`, which every page
    # below wraps in, and `layouts/action_text/contents/_content`, which the project detail page's
    # build-log entry renders. Keeping the prefix would have excused a directory the sweep does
    # reach — an escape hatch covering nothing, which is the vacuous shape this file exists to
    # refuse. All 3 remaining excused `<%#` sites are Devise's, and every template on disk is still
    # counted by the balance check above, which needs no request at all.
    UNSWEPT_DIRS = %w[users/ pwa/ active_storage/].freeze

    # ONE TEMPLATE, NOT A DIRECTORY, AND FOR A REASON THIS SWEEP CANNOT ENGINEER AROUND. Every page
    # in `pages` is reachable from bare `nodes.create!` rows on whatever backend is ambient. The
    # commit box is not: RepoCommitsController#load_repo redirects unless the node is a real git
    # working tree ON DISK and the backend answers `local_worktree?`, which is share alone. So on
    # the s3 and chunk_remote legs the page cannot render at all, and on the share leg it would
    # need a rugged fixture this backend-neutral class has no business owning.
    #
    # WHAT IS AND IS NOT GIVEN UP. The balance check above still counts this template on disk, so
    # the two-snippet leak shape is covered; what is not is the one-snippet trailing-delimiter
    # shape, which only a rendered page can catch. That was checked BY HAND when the template
    # landed -- the real page was driven and its body contains no `%` + `>`, no section marks and
    # no comment prose (tinkerex#178) -- and a hand check is exactly the thing that goes stale, so
    # this is a debt, not a dismissal. The way to clear it is to give this class a real-repo
    # fixture and add the page to `pages` under a `local_worktree?` guard, at which point this
    # constant should go back to being empty.
    #
    # `repo_histories/show.html.erb` IS HERE FOR THE IDENTICAL REASON AND ITS DEBT IS ALREADY PAID.
    # RepoHistoriesController#load_repo is RepoCommitsController#load_repo, so the repository-wide
    # history page is unreachable on the s3 and chunk_remote legs and needs a rugged fixture on the
    # share one. What is different is that its rendered output IS swept, by a test that already has
    # that fixture: RepoHistoryFlowTest#"the repository page lists commits and is reachable from the
    # file page" drives the real page and asserts its body carries neither ERB delimiter. That is
    # the standing check the paragraph above calls for and repo_commits still owes — ENTRIES, NOT A
    # `repo_` PREFIX or a directory: an escape hatch wide enough to cover a template nobody checked
    # is the vacuous shape this file exists to refuse.
    #
    # `files/inspector_gone.html.erb` IS THE THIRD, FOR A DIFFERENT REASON AND WITH ITS DEBT PAID
    # THE SAME WAY. It is reachable on every leg, but only as a 404 (FilesController#inspector's
    # answer for a node that is not a live file), and every sweep below asserts :success. Its
    # rendered output is checked by InspectorTest#"a folder, a tombstone or another user's file
    # answers a gone frame, not a page", which asserts its body carries neither ERB delimiter.
    #
    # `landings/show.html.erb` IS THE FOURTH, EXCUSED FOR THE REASON `users/` IS AND WITH ITS DEBT
    # PAID THE SAME WAY AS THE TWO ABOVE. The marketing landing (2026-10-16) renders only SIGNED OUT
    # and only in demo mode (config/routes.rb), and this sweep is a signed-in session in which `/` is
    # Recent. Its rendered output is checked by LandingTest#"demo mode on, / is the landing: …", which
    # asserts its body carries neither ERB delimiter.
    UNSWEPT_TEMPLATES = %w[
      repo_commits/show.html.erb repo_histories/show.html.erb files/inspector_gone.html.erb
      landings/show.html.erb
    ].freeze

    setup do
      # HERMETIC BY FIXTURE (§14c): the addon pages below read `test/fixtures/addons`, never the
      # sibling `tinkerex-addons` checkout a fresh clone does not have.
      @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s

      # STAGE 3, S3-4: THE HANDLE COMES FIRST AND CANNOT BE ADDED LATER IN THIS SETUP. A project
      # refuses to leave `private` while its maker has none, and once one is published the handle
      # itself locks (Maker::Project's own validation, User#handle_locked?) — so the order below is
      # the only one that works, not a preference.
      #
      # AN ADMIN, so Settings → Users renders (2026-10-21), with a second account for its per-account
      # page: the signed-in account's own is the Account page, never one under /settings/users.
      @user = User.create!(email: "hygiene-#{SecureRandom.hex(4)}@example.com", handle: "hygiene",
                           password: PASSWORD, confirmed_at: Time.current, admin: true)
      @other_account = User.create!(email: "hygiene-other-#{SecureRandom.hex(4)}@example.com",
                                    confirmed_at: Time.current, omniauth_signup: true)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir")
      @user.nodes.create!(node_id: "d-empty", name: "empty", kind: "dir")
      file!("n-stl", "bracket.stl")
      file!("n-bak", "sign_backup.lbrn2", parent_node_id: "d-laser")
      file!("n-mill", "panel.mage", parent_node_id: "d-laser")
      # THE :text BRANCH, WHICH THIS SWEEP DID NOT REACH UNTIL THE CODE VIEWER LANDED. Its ERB
      # comment was one line; it is now seven, and a leak from it would print into the page of
      # every source file in the library. The balance check below covers the two-snippet shape
      # on disk, but only a rendered page can catch the one-snippet shape's trailing delimiter.
      file!("n-src", "firmware.cpp")
      # tag_list: "laser" (stage 2, S2-5) also gives "tags/show" below a non-empty group to render
      # shared/_result_group through -- otherwise that template would need its own fixture.
      # "lamp" AS WELL (tinkerex#286): the TAG arm of shared/_result_group renders only for a tag the
      # sweep's own query matches, and "laser" is not one. The other four arms that query reaches
      # get their fixtures below, beside the model and the inventory item.
      @project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser, lamp")
      @project.file_attachments.create!(user: @user, node_id: "n-stl", role: "model", position: 0)
      @project.file_attachments.create!(user: @user, node_id: "n-bak", role: "laser", position: 1)
      @project.file_attachments.create!(user: @user, node_id: "gone", role: "model",
                                        label: "ghost.stl", position: 2)
      # ONE REPOSITORY INSIDE THE PROJECT'S FOLDER, so a repo SECTION renders (S3-1: a working tree
      # is a section of the tree, projects/_file_tree_section, not a group of its own). A dir with a
      # `.git` marker child under the folder is what marks it — the same argument the `d-laser`
      # comment two attachments up makes for models/_file_tree.
      folder = project_folder_rows!(@user, @project)
      firmware = @user.nodes.create!(node_id: "d-firmware", name: "firmware", kind: "dir",
                                     parent_node_id: folder.node_id)
      @user.nodes.create!(node_id: "d-firmware-git", name: Library::RepoMetadata::DIR_NAME,
                          kind: "dir", parent_node_id: firmware.node_id)
      # STAGE 3, S3-2: A README.md NODE, OR projects/_repo_card's readme branch never renders —
      # without one, `card.readme_note` and `card.readme_html` are both nil and the whole `readme`
      # `<details>`/note paragraph is skipped, same as the file's own comment two lines up argues
      # for _generated_group. This node has no real storage_path behind it (like every other one
      # this fixture seeds), so it renders the "README unavailable" line rather than rendered
      # markdown — still the branch that needs sweeping, and still real coverage: the card itself,
      # its facts line and its refusal/no-tag wording are exercised by `firmware` having no real
      # git repository behind it either.
      @user.nodes.create!(node_id: "n-firmware-readme", name: "README.md", kind: "file",
                          parent_node_id: firmware.node_id)
      # STAGE 4, S4-1: A README AT THE FOLDER'S OWN ROOT, or `projects/_readme_card` never renders.
      # The folder is a PLAIN folder (only `firmware` carries a `.git` marker), so the private page
      # takes the `@readme` branch rather than the root-repository card. Like every other node this
      # fixture seeds it has no bytes behind it, so Maker::Readme fails closed to its note and the
      # partial's NOTE branch is what gets swept — the same argument the firmware README two lines
      # up makes for the repo card's.
      file!("n-readme", "README.md", parent_node_id: folder.node_id)
      # STAGE 3, S3-2 (Task B): ONE .kicad_sch FILE, OR projects/_schematics's POPULATED branch
      # never runs. Its own doc comment says the partial "renders nothing when the folder holds
      # none" — and show.html.erb calls render UNCONDITIONALLY (the partial decides), so the FILE
      # already counted as "covered" without this node; what was missing is the list/badge/
      # kicanvas-embed markup inside the `if kicad_rows.any?` branch, which is exactly where a
      # leaked ERB comment would show up and exactly what the empty-folder case cannot exercise. A
      # plain node with no real bytes is enough for a server-rendered request test: the partial
      # only links to the file and mounts a `data-controller="kicanvas"` div, and the bytes are
      # fetched CLIENT-SIDE, which this test never runs (test/system/kicanvas_test.rb is where a
      # real KiCad file matters — test/support/kicad_fixture.rb, Task B's).
      @user.nodes.create!(node_id: "n-schematic", name: "driver.kicad_sch", kind: "file",
                          parent_node_id: folder.node_id, mtime: 1_000_000_000, size: 5,
                          content_hash: "h-schematic", current_version_id: "v-schematic")
      # A GERBER SET IN ITS OWN SUBFOLDER, so the project pages render a subfolder of pcb-role rows
      # through the ordinary tree section — there is no Fabrication panel since 2026-09-06, and the
      # only Gerber-specific markup left is the FILE page's viewer, which gerber_preview_test.rb
      # drives with real bytes on share. NO `.gbrjob`: FilesController#gerber_layers_for would READ
      # it through the port, and every node this fixture seeds has no bytes behind it, which is
      # exactly the backend-dependence this class's header rules out.
      pcb = @user.nodes.create!(node_id: "d-pcb", name: "pcb", kind: "dir",
                                parent_node_id: folder.node_id)
      %w[driver.gtl driver.gbl driver.drl].each_with_index do |name, i|
        @user.nodes.create!(node_id: "n-pcb-#{i}", name:, kind: "file", parent_node_id: pcb.node_id,
                            mtime: 1_000_000_000, size: 5,
                            content_hash: "h-pcb-#{i}", current_version_id: "v-pcb-#{i}")
      end
      # A FOLDER INSIDE A FOLDER, OR projects/_file_tree_section IS RENDERED BY NO PAGE HERE
      # (2026-09-08, folder panels). Every DEPTH-ONE subfolder is a PANEL now, so that partial is
      # reached ONLY from a panel's `children` and from its own recursion — with `d-firmware` and
      # `d-pcb` both at depth one and nothing below them, this fixture nested nothing and the
      # coverage assertion named the file. `d-pcb` stays at its TILES default, so what is swept is
      # the section's tiles arm; its list arm is `d-models` below.
      gerber_rev = @user.nodes.create!(node_id: "d-pcb-rev-b", name: "rev-b", kind: "dir",
                                       parent_node_id: pcb.node_id)
      @user.nodes.create!(node_id: "n-pcb-rev", name: "driver-rev-b.gtl", kind: "file",
                          parent_node_id: gerber_rev.node_id, mtime: 1_000_000_000, size: 5,
                          content_hash: "h-pcb-rev", current_version_id: "v-pcb-rev")
      # A THIRD DEPTH-ONE FOLDER, HELD AT THE `list` VIEW, AND IT IS WHAT SWEEPS TWO PARTIALS' LIST
      # ARMS AT ONCE. A folder panel has three views and this fixture has to render all of them from
      # one page, because the view is stored on the project ROW now — there is no `?view=` a second
      # entry in `pages` could ask for (see the retired "project detail (list)" entry below). The
      # defaults cover two: `d-firmware` is a working tree and opens in the BROWSER, `d-pcb` is
      # plain and opens in TILES. Only an override reaches the third, and it is the arm that renders
      # projects/_file_rows — swept by no page at all once the page-wide view cookie retired. The
      # visitor's public/projects/_folder_panel takes the same three keys and splits them two ways
      # (`browser` reads as `list` there), so this one override covers its list arm too while
      # `d-pcb` covers its tiles arm.
      #
      # `views` HIDES NOTHING, which is what keeps it compatible with the `kind: "other"` rule
      # stated further down: Maker::ProjectKind.layout_for reads `order` and `hidden` off the
      # overrides and neither is set here, so every panel this sweep needs still renders.
      models_dir = @user.nodes.create!(node_id: "d-models", name: "models", kind: "dir",
                                       parent_node_id: folder.node_id)
      file!("n-models-base", "base.stl", parent_node_id: models_dir.node_id)
      @project.update!(panels: { "views" => { "folder:d-models" => "list" } })
      # ONE GENERATED FILE IN THE FOLDER, OR projects/_generated_group IS NEVER RENDERED: a file with
      # a Maker::AddonState behind it, keyed to the `fixture` addon the sweep's ADDON_SOURCE_PATH
      # already serves (link_for answers nil for a key the source does not know, and the concern
      # drops it). The list view of the same page sweeps _file_rows.
      generated = @user.nodes.create!(node_id: "n-generated", name: "shelf-box.svg", kind: "file",
                                      parent_node_id: folder.node_id)
      state = @user.maker_addon_states.create!(addon_key: "fixture", name: "shelf box", data: {}, revision: 2)
      state.files.create!(node_id: generated.node_id, role: "output", position: 0)
      @project.tasks.create!(user: @user, title: "Cut the base", status: "todo", position: 0)
      # STAGE 3, S3-4: AN IMAGE IN THE FOLDER *AND* ONE ATTACHED TO THE ENTRY, because the public
      # page reads the two through different code (`public/projects/_photos` unions the folder's
      # image-role rows with the entries' live attachments, and `public/projects/_build_log`
      # renders the entry's own). `.png`, not the `.svg` two blocks up: `role_for` answers "vector"
      # for svg and only an "image" role reaches the photos panel.
      photo = file!("n-photo", "shot.png", parent_node_id: folder.node_id)
      # STAGE 4, S4-5: TWO MORE FILE PAGES, because eight viewer branches that used to be inline in
      # files/show.html.erb are now eight TEMPLATES — and the coverage assertion below counts
      # templates, not branches. `n-photo` directly above already reaches files/viewers/_image and
      # `n-pcb-0` already exists for _gerber; these two are the ones with no node behind them. The
      # `.bin` is in no ROLE_BY_EXT entry and no renderer Registry, so its page takes _static's
      # `else` arm — measured with `FilesController.new.send(:preview_kind, "telemetry.bin")`, which
      # answers `:other`; pick another extension if a later slice claims this one.
      file!("n-pdf", "manual.pdf", parent_node_id: folder.node_id)
      file!("n-other", "telemetry.bin", parent_node_id: folder.node_id)
      entry = @project.build_log_entries.create!(user: @user, body: "Cut the base tonight.",
                                                 logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: photo, role: "image", position: 0)
      # STAGE 4, S4-1: THE SAME IMAGE ATTACHED TO THE PROJECT, which makes it the DERIVED cover
      # (Maker::Project#derived_cover_node_id prefers an image) and so drives `projects/_hero`'s
      # IMAGE branch — the one that renders the picture itself rather than a poll cell. It is
      # already a folder image, so `projects/_photos` renders it either way.
      @project.file_attachments.create!(user: @user, node_id: photo, role: "image", position: 3)
      # 2026-09-09, CONTENT BLOCKS: ONE BLOCK OF EACH KIND, or five templates are rendered by no
      # page here — projects/_block_panel and public/projects/_block_panel on the two detail pages,
      # projects/_block_editor, _block_templates and _page_intro on the edit-mode entry. The IMAGE
      # block names `n-photo`, which is already a live file inside the folder, so it renders the
      # picture on the maker's page and passes `Maker::PublicProject#permits?` on the visitor's —
      # an image block whose node is not live renders NOTHING at all, which would leave that
      # partial's populated arm unswept while the coverage assertion still counted the file.
      @project.blocks.create!(user: @user, kind: "text", heading: "Why a printed shade",
                              body: "A paper shade **yellows**.")
      @project.blocks.create!(user: @user, kind: "link", heading: "Printables page",
                              url: "https://www.printables.com/model/1", line: "Sliced files.")
      @project.blocks.create!(user: @user, kind: "image", node_id: photo, caption: "Side on.")
      @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                       data: Maker::Sheet.blank_data)
      # FOLDERLESS ON PURPOSE. Every model renders its own page since 2026-10-21 (`/models/:id` no
      # longer redirects a model with a live folder into the Library), so the page itself needs no
      # folder to be swept. @model stays folderless so "model detail" below sweeps the
      # attachment-list fallback of ModelsController#file_tree_for_model — a one-file model, an
      # import whose folder was never made. The Library's model strip is swept by "model folder",
      # over its own fixture further down.
      @model = @user.maker_models.create!(title: "Bracket", slug: "bracket", cover_node_id: "n-stl")
      # THE MODEL ARM AND THE FILE ARM OF THE SEARCH PAGE (tinkerex#286): a model and a file whose
      # names carry the sweep's query, or shared/_result_group's :model and :file branches are
      # rendered by no page in `pages` — measured by S4-8's Task E, which found only :project,
      # :folder and :note reached. Named so nothing else in this fixture is asserted about them.
      @user.maker_models.create!(title: "Lamp shade", slug: "lamp-shade")
      file!("n-lamp", "lamp-base.stl")
      @model.file_attachments.create!(user: @user, node_id: "n-stl", role: "model", position: 0)
      # `models/_file_tree` RENDERS FROM THESE ATTACHMENTS: a folderless model's Files panel lists
      # its own LIVE attachments (ModelsController#file_tree_for_model's fallback, §14k). With none
      # live the panel says "No files yet", the partial is never rendered, and the coverage assertion
      # below reports it -- the guard that went red when the panel first changed (2026-09-02).
      @model.file_attachments.create!(user: @user, node_id: "n-bak", role: "laser", position: 1)
      # THE MODEL STRIP (structural redesign §5.4, slice 5), or `files/_model_strip` is rendered by
      # no page here. ITS OWN FOLDER AND MODEL, so @model above stays folderless. Every arm the strip
      # has that the coverage assertion cannot tell apart is populated: a live cover (the derived one,
      # its mesh), designer, licence and an http source, print settings, notes, and one logged print
      # so the shared print log renders a row inside it.
      @user.nodes.create!(node_id: "d-wall-bracket", name: "wall-bracket", kind: "dir")
      file!("n-wall-bracket", "wall-bracket.stl", parent_node_id: "d-wall-bracket")
      strip_model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-wall-bracket",
                                               designer: "Ada", license: "CC-BY",
                                               source_url: "https://example.com/wall-bracket",
                                               print_settings: { "layer_height" => "0.2mm" },
                                               notes: "Print it on its back.")
      strip_model.file_attachments.create!(user: @user, node_id: "n-wall-bracket", role: "model", position: 0)
      strip_model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success", printer: "MK4")
      # THE RECIPE PANELS ARE ONLY REACHABLE THROUGH A THUMBNAIL ROW CARRYING METADATA, and they
      # branch on the KEY, not the extension (`operations` → MillMage, else LightBurn). Without
      # both rows, `files/_lbrn_settings` and `files/_mage_settings` are unreachable from any
      # request and would have to be excluded from the coverage assertion instead of covered.
      recipe!("n-bak", "layers" => [ { "name" => "Score", "color" => "#ff0000", "speed" => 100 } ])
      recipe!("n-mill", "operations" => [ { "name" => "Pocket", "tool" => "3mm flat" } ])
      # STAGE 2, S2-3: one item with a posted ledger row, so the show page's composer AND its
      # ledger table both render (an item with no transactions would leave `table.ledger`'s tbody
      # empty and the balance-walk untouched).
      @inventory_item = @user.maker_inventory_items.create!(name: "M3 bolt", unit: "each", min_quantity: 5)
      # THE INVENTORY ARM of the search page (tinkerex#286) — see the model and file fixtures above.
      @user.maker_inventory_items.create!(name: "Lamp cord", unit: "m", min_quantity: 0)
      Maker::InventoryTransaction.apply!(item: @inventory_item, user: @user, delta: 3, reason: "initial")
      # STAGE 2, S2-4: a BOM with a line of EACH kind, so both projects/_bom (the panel, on
      # "project detail") and projects/_bom_lines (the shared table + composer, on "projects/boms"
      # too) render every branch -- an empty BOM would skip the table and the badge partials
      # entirely.
      bom = @project.boms.create!(user: @user)
      bom.lines.create!(user: @user, inventory_item: @inventory_item, quantity: 2, unit: "each", position: 0)
      bom.lines.create!(user: @user, node_id: "n-stl", quantity: 1, unit: "each", position: 1)
      bom.lines.create!(user: @user, part_name: "22 AWG wire", quantity: 3, unit: "m", position: 2)
      # STAGE 3, S3-3: ONE CONNECTION, OR projects/_wiring's POPULATED branch never renders -- same
      # argument as the BOM lines three lines up: an empty table would skip the row markup (and the
      # per-row form-wiring) entirely.
      @project.connections.create!(user: @user, from_label: "Driver board", to_label: "Stepper motor",
                                   wire: "22 AWG", position: 0)
      # 2026-10-21: TWO SAVED CALCULATIONS, one at each display, or projects/_calculation_rows' list
      # never renders and the inch-fraction arm of CalculationsHelper#calculation_result_text with it.
      @project.calculations.create!(user: @user, label: "Shelf depth", expression: "12.5mm + 1/4in",
                                    result: 18.85, unit: "mm")
      @project.calculations.create!(user: @user, label: "Leg", expression: "3 3/16in", result: 3.1875,
                                    unit: "in", inch_fraction: 16)
      # STAGE 3, S3-5: ONE RELEASE CARRYING EVERY BRANCH ITS TWO PANELS HAVE -- a verified tag (the
      # badge plus a short oid), a BOM revision, a changelog, a file still current (which renders a
      # Download), one whose content has moved on since ("changed"), and one that has left the
      # library ("gone", no link). Without the last two the state column and both no-link branches
      # are unreachable from any page here, which is the same argument the BOM lines three blocks up
      # make for seeding one line of each kind.
      #
      # ROWS RATHER THAN Maker::ReleaseSnapshot, deliberately: the snapshot reads the folder through
      # the port and these fixtures have no bytes behind them, so it would capture nothing on the
      # s3 and chunk_remote legs and this sweep must render the same markup on all three.
      # `token_for` keeps the CURRENT file's row unchanged on every backend (§14a: the token is the
      # content hash on share/s3 and the sync server's version id on chunk_remote).
      release = @project.releases.create!(user: @user, version: "v1.0.0", git_tag: "v1.0.0",
                                          git_oid: "0" * 40, repo_node_id: "d-firmware",
                                          bom:, bom_revision: bom.revision,
                                          published_at: Time.current, notes: "<div>First cut.</div>")
      release.files.create!(user: @user, node_id: "n-schematic", name: "driver.kicad_sch",
                            path: "driver.kicad_sch", content_token: token_for("n-schematic"), size: 5)
      release.files.create!(user: @user, node_id: "n-photo", name: "shot.png", path: "shot.png",
                            content_token: "t-stale", size: 5)
      release.files.create!(user: @user, node_id: "n-vanished", name: "old.stl",
                            path: "models/old.stl", content_token: "t-old", size: 5)
      # STAGE 4, S4-7: `kind` STAYS `other` ON BOTH PROJECTS THIS FILE CREATES — @project here and
      # @unlisted below — because `other`'s preset hides nothing and reorders nothing, which is
      # what keeps this sweep rendering every panel partial through the loop in
      # projects/show.html.erb. A kind (or a `panels` override) hides panels from the only sweep
      # that can see a leaked comment in them, and the coverage assertion below then reports them
      # as rendered by no page rather than as hidden.
      #
      # BOTH, NOT EITHER, AND THAT IS MEASURED RATHER THAN REASONED: `pages` visits two project
      # detail pages, so setting `kind: "laser"` on @project ALONE left every panel partial still
      # covered by @unlisted's page and this sweep stayed GREEN. With it on both, the assertion
      # goes red naming projects/_bom, _wiring, _releases and _sheets — and public/projects/_bom
      # and _releases with them, because the visitor's page reads the SAME layout off the project
      # (Maker::PublicProject#visible_panels), which is the other half of this fixture's coverage.
      # projects/_panel_slot and _panel_strip render on a project detail page whatever the kind —
      # the slot wraps every panel, and the strip is on every slot of the edit-mode entry below —
      # so both are covered either way.
      #
      # STAGE 3, S3-4: PUBLISHED LAST, once every panel above has something to render — the public
      # page shows the SAME fixtures through ten new templates, so nothing here is seeded twice.
      # `license:` renders the head's licence badge, one of the two branches that badge has.
      @project.update!(visibility: "public", license: "CERN-OHL-P-2.0")
      # THE UNLISTED SIBLING RENDERS ONE BRANCH NO PUBLIC PROJECT CAN: the `noindex` meta and the
      # "Unlisted link" badge, reached only with `k` (the token IS the credential). It needs no
      # fixtures of its own — its panels are all empty, which is the OTHER half of a partial that
      # renders nothing when its collection is empty. SINCE SLICE 6 its page leaves the six empty
      # on-demand panels out and carries "+ Add panel" instead (the one page here that sweeps that
      # menu), so their quiet arm is swept by its edit-mode entry in `pages`, where every panel shows.
      @unlisted = @user.maker_projects.create!(name: "Hidden Rig", visibility: "unlisted")
      # STAGE 4, S4-4: A FOLDER WITH NO README, or projects/_readme_editor's "Write a README" branch
      # (the template in the textarea, the enabled controls) is rendered by no page here — @project's
      # folder holds a README, so its editor takes the other arm. Coverage is per TEMPLATE, so the
      # sweep stayed green over the gap; a comment terminator leaked into that branch would have been
      # invisible. `project_folder_rows!` is rows only, no mkdir (§ test_helper), so the listing is
      # available on every leg and the project page renders the card with its editor.
      project_folder_rows!(@user, @unlisted)
      # STAGE 4, S4-2: OR projects/_attachments' sweep-note NEVER RENDERS — the populated branch
      # needs both a count and a timestamp. `update_columns`, matching ProjectIntake#record_sweep!:
      # no `updated_at` bump, so nothing above re-orders. The autofile-off branch is the other arm
      # of the same `if`, and this sweep's coverage is per TEMPLATE, not per branch — the two
      # request tests in project_attachments_test.rb are what cover both.
      @project.update_columns(last_swept_at: 1.hour.ago, last_sweep_moves: 2)
      # STAGE 4, S4-8: THE CONNECTED PANEL'S FOUR POPULATED BRANCHES, or `files/_connections`
      # renders only its two doors and none of the four lists' markup is ever swept. The partial
      # itself is rendered unconditionally by files/show, so the coverage assertion below was
      # already satisfied by the EMPTY panel — which is exactly the gap these rows close, the same
      # argument projects/_schematics' fixture makes for a partial that "renders nothing when the
      # folder holds none".
      #
      # `n-stl` is the page `pages` visits as "file detail (3d)", and it sits at BOTH ends of a
      # derived_from plus the far end of a photo_of, so its page renders three of the four:
      # "This came from" (to n-bak), "Made from this" (from n-generated) and "Photos of this file"
      # (from n-photo). The FOURTH, "This is a photo of", renders on the PHOTO's own page — which
      # `pages` already visits as "file detail (image)" (S4-5), so no page is added here.
      @user.maker_file_links.create!(from_node_id: "n-stl", to_node_id: "n-bak", kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: "n-generated", to_node_id: "n-stl", kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: "n-photo", to_node_id: "n-stl", kind: "photo_of")
      # A NOTE MATCHING THE SWEEP'S OWN SEARCH QUERY ("lamp"), so the search page renders the NOTE
      # arm of shared/_result_group. Coverage here is per TEMPLATE, so that partial already counted
      # as swept — but a leaked comment lives in ONE `case` arm, and counting which of the seven
      # this sweep actually reaches says: `:project` (the search page's Desk Lamp and the tag
      # page's one group) and, with these two rows, `:folder` and `:note`. `:file`, `:model`,
      # `:inventory_item` and `:tag` are still reached by no page here — a pre-existing gap this
      # slice neither widens nor closes, recorded so the next reader does not have to re-derive it.
      #
      # THE FOLDER ARM NEEDS NO FIXTURE OF ITS OWN: `project_folder_rows!` above minted a dir named
      # after @project's slug, `desk-lamp`, which the same query matches and `visible_entries(false)`
      # keeps (it is neither a dot-dir, the `.git` marker, nor a Library::BuildOutput name).
      # Verified by a rendered assertion when this landed, not by reading the slug.
      @user.maker_notes.create!(node_id: "n-stl", body: "<div>Cut on the lamp jig.</div>")

      # THE SHELVES PAGE'S TWO GROUP BRANCHES (2026-10-20): a group holding one shelf renders its
      # cards under its heading, and an empty one renders the "No shelves in this group yet" line.
      # The page makes every other shelf itself on the visit (Maker::Shelves.ensure!), ungrouped.
      fabrication = @user.maker_shelf_groups.create!(name: "Fabrication", position: 0)
      @user.maker_shelf_groups.create!(name: "Paperwork", position: 1)
      @user.maker_shelves.create!(name: "laser", shelf_group: fabrication)
    end

    teardown do
      ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
    end

    # A file shaped like one in a real library. THE CONTENT TOKEN IS LOAD-BEARING, not decoration:
    # `files/show.html.erb` opens its preview tree with `if @info.content_token.nil?` → "No content
    # yet.", so a bare `nodes` row short-circuits the whole tree. With the fixtures this file used
    # to carry, the sweep visited the file page and entered NONE of its branches — not :image, not
    # :text, not :model3d, not :measure, not :thumbnail — and none of the three partials behind
    # them. BOTH columns, because `content_token` is `current_version_id` on chunk and
    # `content_hash` on share/s3 (§14a).
    def file!(node_id, name, **extra)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1_000_000_000, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}", **extra)
      node_id
    end

    def token_for(node_id) = FileLayer.current.stat(@user, node_id:).content_token

    # `renderer_revision` is DERIVED, not the literal 1 this first shipped as — the same rule the
    # coverage assertion below states for the template set. `.lbrn2`'s live thumbnail revision is
    # 4, so a hardcoded 1 makes `FilesController#current_thumbnail`'s `find_by(… renderer_revision:)`
    # MISS and fall through to `Enqueue.call`. The page still rendered, but only because §14h's "A
    # CONTENT REPOINT BLANKS THE ARTIFACT; A RENDERER REBUILD DOES NOT" preserved `status` and
    # `metadata` while repointing 1 → 4 — i.e. it worked by way of an invariant this file is not
    # about. It would have failed LOUD if that ever changed, which is the right direction, but the
    # message would have been "no page renders these templates", sending the reader to add a page
    # when the fix is a fixture number. Deriving it also drops the spurious enqueue (2 → 1).
    def recipe!(node_id, metadata)
      name = FileLayer.current.stat(@user, node_id:).name
      @user.maker_previews.create!(node_id:, version_id: token_for(node_id), kind: "thumbnail",
                                   status: "ready", metadata:,
                                   renderer_revision: Maker::Previews::Enqueue.revision_for_name(name, "thumbnail"))
    end

    # EVERY PAGE THIS SWEEP CAN REACH, and the coverage assertion below is what keeps that true —
    # this list stopped being "every page touched by one branch" the moment a template could be
    # added without anything noticing. The filtered and grid variants are listed separately because
    # they render DIFFERENT partials — the leak that prompted this file was in `files/_ext_filter`,
    # which the grid renders and the file page does not.
    # FRAME REQUESTS (2026-10-21), `name => [path, frame id]`. Two templates render only when Turbo asks
    # for a frame by name — this app's layouts/turbo_rails/frame and the model page's models/pane — and
    # a plain `get` never does, so they are swept with the header Turbo sends. The two sweeps that read
    # rendered prose and ERB delimiters cover these; the page-head and fileopen sweeps do not, because
    # a frame carries no page head and its file links are the pane's own `.btn`s.
    def frame_pages
      { "model detail (pane, frame request)" => [ model_path(@model, file: "n-stl"), "model_stage" ] }
    end

    def pages
      {
        "home" => root_path,
        "files (list)" => files_path(view: "list"),
        "files (grid)" => files_path(view: "grid"),
        "files (filtered)" => files_path(ext: "stl"),
        "files (in a folder)" => files_path(folder: "d-laser"),
        # F onboarding (2026-10-13): an EMPTY folder, the one page here that renders
        # shared/_where_files_come_from. Every other page that does (Recent's getting-started
        # panel, the Library root and Projects' empty states) needs an account with no files or no
        # projects, and this fixture deliberately has both.
        "files (an empty folder)" => files_path(folder: "d-empty"),
        # Slice 5: a catalogued model's folder, the one page that renders files/_model_strip.
        "model folder" => files_path(folder: "d-wall-bracket"),
        "file detail (3d)" => file_path("n-stl"),
        "file detail (measure, lbrn)" => file_path("n-bak"),
        "file detail (measure, mage)" => file_path("n-mill"),
        "file detail (text)" => file_path("n-src"),
        "file detail (kicanvas)" => file_path("n-schematic"),
        # Stage 4, S4-5: one page per viewer partial. The three above already reach
        # files/viewers/_model3d, _measure and _code; these four are the rest of the eight.
        "file detail (image)" => file_path("n-photo"),
        "file detail (pdf)" => file_path("n-pdf"),
        "file detail (gerber)" => file_path("n-pcb-0"),
        "file detail (other)" => file_path("n-other"),
        # Structural redesign slice 3: the Library's inspector frame, a fragment swept like a page
        # so a comment leak in it would show. `n-stl` is attached to @project and renderable, so
        # the frame reaches the attach chips and the thumbnail cell. Its 404 sibling,
        # files/inspector_gone, is in UNSWEPT_TEMPLATES — this sweep asserts :success.
        "file inspector" => inspector_file_path("n-stl"),
        # 2026-09-10: the "New text file" door's own form (Files::TextFilesController#new). Its
        # comment quotes `f.text_field` and `fields_for`, which is the §14d shape this file exists
        # for, and no other page renders it.
        "text file new" => new_files_text_file_path,
        "projects index" => projects_path,
        # ONE ENTRY, NOT TWO. `project detail (list)` used to sit here as
        # `project_path(@project, view: "list")` and was the only page that swept
        # projects/_file_rows. The folder panels retired the page-wide `?view=`/cookie pair
        # (2026-09-08, spec decision 6): the view is stored per PANEL on the project row, so that
        # URL now renders byte for byte what the line above renders and the two entries were the
        # same page visited twice. `_file_rows` is swept by `d-models`' stored `list` view in setup
        # instead — which is a stronger claim, since it is the arm a real maker's page takes.
        "project detail" => project_path(@project),
        # THE PAGE EDITOR'S OWN RENDER (2026-09-09): the same action with `editing` on, and the ONLY
        # page that reaches projects/_panel_strip, _layout_bar and _layout_drawer. It earns its
        # entry rather than merely filling the coverage assertion: the strip's comment quotes ERB,
        # which is exactly the shape section 14d records, and the sweep caught one such leak in
        # projects/_panel_slot while these three sat unswept.
        "project detail (edit mode)" => edit_layout_project_path(@project),
        "project detail (no README)" => project_path(@unlisted),
        "project detail (edit mode, empty panels)" => edit_layout_project_path(@unlisted),
        # Stage 4, S4-4: the owner's preview of their public page, the ONE page that reaches
        # projects/preview and projects/_preview_banner. @user has a handle (setup above), so this
        # renders the page rather than the no-handle redirect.
        "project preview" => preview_project_path(@project),
        "project new" => new_project_path,
        "project edit" => edit_project_path(@project),
        "project attachment new" => new_project_attachment_path(@project),
        # 2026-10-21: the Add-model picker. @model ("Bracket") is catalogued, so the results arm
        # renders, not the empty one.
        "project model new" => new_project_model_path(@project),
        "project sheet" => sheet_path(@sheet),
        "projects/boms" => project_bom_path(@project),
        # Stage 2, S2-5. @project wears "laser" (setup above), so this renders shared/_result_group
        # (Task A's own partial, also rendered by Task B's search page) at least once.
        "tags/show" => tag_path("laser"),
        # Slice 5: the old Models index as the Library's 3D models view, files/models/index.
        "3D models" => files_models_path,
        "model detail" => model_path(@model),
        # 2026-10-21: the model page's pane with a FILE in it, the one page that renders
        # models/_stage's file arm (its head, Download and "Open file page").
        "model detail (file pane)" => model_path(@model, file: "n-stl"),
        "model new" => new_model_path,
        "model edit" => edit_model_path(@model),
        # The Shelves page (2026-10-20; it was Filing). It makes its own shelves on the visit, and
        # setup's two groups -- one holding `laser`, one empty -- reach both arms of a group section
        # and the card partial inside and outside one.
        "shelves" => settings_shelves_path,
        # Stage 2, S2-3.
        "inventory index" => inventory_items_path,
        "inventory item" => inventory_item_path(@inventory_item),
        "inventory new" => new_inventory_item_path,
        "inventory edit" => edit_inventory_item_path(@inventory_item),
        # Stage 2, S2-3 (Task B): renders fine over zero rows, so no fixture is needed here.
        "suppliers" => suppliers_path,
        "locations" => locations_path,
        "tools gallery" => tools_path,
        # The New ▾ menu's lazy tool list (slice 2): a fragment, swept like a page so a comment
        # leak in it would show. The sweep's ADDON_SOURCE_PATH points at the fixtures, so it lists.
        "new menu tools" => tools_new_menu_path,
        # 2026-10-21: the calculator modal's Save to project form, its lazy frame's fragment.
        "calculator save form" => new_calculation_path(project_id: @project.id),
        "tools addon" => tools_addon_path("fixture"),
        "trash" => trash_index_path,
        "search" => search_path(q: "lamp"),
        # Stage 2, S2-6. @project wears "laser" (setup above), so this renders a non-empty list --
        # the settings hub itself needs no fixture, it only counts what setup already created.
        "settings" => settings_path,
        "settings/tags" => settings_tags_path,
        # K (2026-10-20): the library folder page. One template for its states; the fixture confirms
        # the library, so the chosen state renders here (and the no-folder state on s3/chunk_remote).
        "settings/library" => settings_library_path,
        # Accounts (2026-10-21): the list with its add form, and one other account's page.
        "settings/users" => settings_users_path,
        "settings/users edit" => edit_settings_user_path(@other_account),
        # Onboarding (2026-10-13): the Help page needs no fixture. Its three backend arms are
        # rendered by help_page_test.rb, which swaps the capabilities the page reads.
        "help" => help_path,
        # STAGE 3, S3-4: THE PUBLIC SURFACE, five pages over ten templates. Signed in, which is
        # neither a mistake nor a weakening: Public::BaseController stands on
        # ActionController::Base and never reads the session (the seam guard in
        # test/architecture_invariants_test.rb), so these render the visitor's page either way —
        # and a separate signed-out sweep would be a second `pages` map to keep in step.
        "public project" => public_project_path(@user.handle, @project.slug),
        "public project (unlisted)" => public_project_path(@unlisted.user.handle, @unlisted.slug,
                                                           k: @unlisted.unlisted_token),
        "public user" => public_user_path(@user.handle),
        # STAGE 4, S4-5: the visitor's file page, and the MEASURE branch of it — the one viewer whose
        # public render differs from the private one at all (`save: false` drops the two library
        # saves). `n-stl` and `n-bak` sit OUTSIDE the project folder in this fixture, so they are
        # permitted only through the attachment arm of `Maker::PublicProject#permits?` — and they
        # are, by the two `@project.file_attachments.create!` rows in setup.
        "public file (3d)" => public_file_view_path(@user.handle, @project.slug, "n-stl"),
        "public file (measure)" => public_file_view_path(@user.handle, @project.slug, "n-bak"),
        "explore" => public_explore_path,
        # The tag chip's own destination, which is the filtered branch of the same page — its
        # "All" chip renders only when a filter is on.
        "explore (tag)" => public_explore_path(tag: "laser"),
        # The compose generator (2026-10-21): public/compose/show and its one partial, _text_field,
        # whose ERB comments name a <form> -- prose, never `%>`.
        "compose generator" => public_compose_path
      }
    end

    # KEEP ONE GUARD PER TEST METHOD (this read "exactly three" until the .page-head and fileopen
    # sweeps made it five — the count was never the point). Minitest abandons a method at its first
    # failure, so a mutation that breaks independent guards can only report each failure if the
    # guards live in their own methods. Collapsing them costs that signal — which is why the seven-arm check
    # below is a method of its own and not a line inside the page loop (found in review).

    # EVERY ARM OF shared/_result_group, ON THE ONE PAGE THAT RENDERS THEM ALL (tinkerex#286). The
    # coverage assertion in the sweep below is per TEMPLATE, so a partial with seven `case` arms
    # counts as swept the moment one arm renders; S4-8's Task E measured that only :project,
    # :folder and :note ever did. The fixtures in `setup` give the search query a hit of every
    # kind, and this is what says so — a fixture that quietly stops matching drops an arm out of the
    # sweep with nothing else going red. Its own method for the reason the comment above gives: a
    # prose leak on a page ordered before `search` must not abort this check unseen.
    test "the search page renders every arm of the shared result group" do
      get search_path(q: "lamp")
      assert_response :success
      %w[file folder project model note inventory_item tag].each do |kind|
        assert_select ".result-group--#{kind}", { minimum: 1 },
                      "the search page rendered no #{kind} group — its fixture stopped matching " \
                      "the sweep's query, so that arm of shared/_result_group is no longer swept"
      end
    end

    # `.page-head` IS `display: flex; justify-content: space-between`, WHICH LAYS OUT EXACTLY TWO
    # SLOTS. With two children that reads title-left / actions-right, which is what fourteen of the
    # sixteen pages do. A THIRD child does not overflow or wrap — `space-between` puts it in the
    # CENTRE of the page, which is a plausible-looking layout and therefore invisible in review:
    # /models (now /files/models) floated its primary action "Import model" mid-page with "Shelves"
    # hard right, and the public project page centred its byline between the name and the download
    # button. One mechanism, two pages, and an unwritten contract nothing enforced.
    #
    # THIS RIDES THE `pages` SWEEP RATHER THAN NAMING ROUTES, so a page added to that list is
    # covered here with no edit — and the sweep already carries a coverage assertion tying it to the
    # templates on disk. It asserts the RENDERED DOM: the two defects were structural in ERB whose
    # `.page-head` class was correct on every one of them, so nothing short of the built tree could
    # tell a compliant head from a broken one.
    #
    # MUTATION-CHECKED (§15), both directions:
    #   - Unwrapping the two links in models/index.html.erb (files/models/index since slice 5) back
    #       to bare children:
    #       models index: .page-head passes 3 slots, not 2 — [h1 "Models", a.btn.primary
    #       "Import model", a.btn "Shelves"]. `.page-head` is space-between: the MIDDLE one lands
    #       in the centre of the page.
    #   - Setting the non-vacuity floor to `> 500` (a count no sweep reaches) reddens it at the
    #       floor instead, confirming `seen` really is counting: "only 50 .page-head elements were
    #       examined across 50 pages" — one head per page, which is itself worth knowing.
    test "every .page-head passes exactly the two slots it lays out" do
      seen = 0
      offenders = []
      pages.each do |name, path|
        get path
        assert_response :success, "#{name} (#{path}) did not render"
        css_select(".page-head").each do |head|
          seen += 1
          kids = head.element_children
          next if kids.size <= 2
          shape = kids.map { |k| [ k.name, k["class"] ].compact.join(".") }
          offenders << "#{name}: .page-head passes #{kids.size} slots, not 2 — #{shape.inspect}"
        end
      end

      # NON-VACUITY FIRST (§14e). A sweep that rendered nothing, or a `.page-head` that lost its
      # class everywhere, would produce zero elements to examine and satisfy `assert_empty` over
      # nothing at all — the shape that let two architecture guards pass for weeks after the
      # directory they scanned was moved. The floor is deliberately well below the real count
      # rather than equal to it, so adding a page does not red this line.
      assert_operator seen, :>, 30,
                      "only #{seen} .page-head elements were examined across #{pages.size} pages — " \
                      "the sweep is not reaching the heads it claims to check"
      assert_empty offenders, offenders.join("\n")
    end

    # A CLICK OPENS A FILE AND A DOUBLE-CLICK OPENS IT IN A NEW TAB, ON EVERY FILE LINK (2026-10-21,
    # docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md). RIDES THE `pages` SWEEP
    # for the reason the .page-head test gives: a page added there is covered with no edit, so a new
    # surface that links a file page without FilesHelper#file_open_data goes red here instead of
    # opening on the first half of a double-click. Two exclusions and no list: rendered Markdown (a
    # README, a text block) is prose, and a `.btn` is an action. A file page link is `/files/<a node
    # id of this fixture>` exactly — no query, no fragment, no second segment (a blob or notes URL).
    # An href URI cannot parse is not a file page link, so it is skipped rather than raised on.
    #
    # MUTATION-CHECKED (§15): dropping file_open_data from files/_connections' first group reds it
    # naming "file detail (3d)"; a `> 10_000` floor reds it at the floor ("only 88 file-page links");
    # dropping the `.btn` exclusion names the inspector's Open and the model pane's "Open file page".
    # Dropping the `.markdown` exclusion stays GREEN: no fixture here has bytes, so no swept page
    # renders a Markdown link to a file. That exclusion is the spec's rule, not yet exercised here.
    test "every link to a file page opens through fileopen" do
      node_ids = @user.nodes.pluck(:node_id).to_set
      seen = 0
      offenders = []
      pages.each do |name, path|
        get path
        assert_response :success, "#{name} (#{path}) did not render"
        css_select("a[href]").each do |a|
          uri = begin
            URI.parse(a["href"])
          rescue URI::InvalidURIError
            next
          end
          next unless uri.host.nil? && uri.query.nil? && uri.fragment.nil?
          id = uri.path.to_s[%r{\A/files/([^/]+)\z}, 1]
          next unless id && node_ids.include?(id)
          next if a.ancestors(".markdown").any? || a.classes.include?("btn")
          seen += 1
          next if a["data-action"].to_s.include?("click->fileopen#click")
          offenders << "#{name}: #{a.to_html.first(140)}"
        end
      end
      # NON-VACUITY FIRST (§14e): a sweep that matched no file link would pass over nothing. The
      # floor is about half the 88 measured when this landed — a non-vacuity check, not a pin.
      assert_operator seen, :>, 40, "only #{seen} file-page links were examined across #{pages.size} pages"
      assert_empty offenders, offenders.uniq.join("\n")
    end

    test "no page renders an ERB delimiter into its output" do
      # STATIC AND FIRST, because it needs no fixtures, covers every template on disk including the
      # ones no request renders, and is the only thing here that sees the two-snippet shape. It
      # masks nothing: a leak that this check would miss leaves the counts balanced, so the sweep
      # below still runs and still reports it.
      erb_templates.each do |rel, src|
        assert_equal src.scan("<%").size, src.scan("%>").size,
                     "#{rel} has unbalanced ERB delimiters. The usual cause is an opener inside a " \
                     "`<%# … %>` comment swallowing its terminator, which leaks the comment's prose " \
                     "into the page — but this check counts TOKENS and has not established that. It " \
                     "also fires on a Ruby string literal containing `<%` inside a tag, which leaks " \
                     "nothing (probed). Read the count, then find out which"
      end

      pages.each do |name, path|
        get path
        assert_response :success, "#{name} (#{path}) did not render"
        # `<%` and `%>` BOTH, because a comment that terminates early leaks the CLOSER of the
        # snippet it quoted, not an opener — checking only for `<%` would have missed this exact bug.
        assert_not_includes response.body, "<%", "#{name} leaked an ERB opener into the page"
        assert_not_includes response.body, "%>", "#{name} leaked an ERB closer into the page"
      end

      frame_pages.each do |name, (path, frame)|
        get path, headers: { "Turbo-Frame" => frame }
        assert_response :success, "#{name} (#{path}) did not render"
        assert_not_includes response.body, "<%", "#{name} leaked an ERB opener into the frame"
        assert_not_includes response.body, "%>", "#{name} leaked an ERB closer into the frame"
      end
    end

    # THE OTHER HALF OF THE SAME FAILURE, and the one a delimiter check alone would miss: a comment
    # can leak prose that happens to contain no delimiter at all. These are phrases that appear ONLY
    # in the code comments of templates this sweep renders, so finding one in a response means a
    # comment is being rendered.
    #
    # EVERY ENTRY MUST BE A LIVE PHRASE, and the `refute_empty` below is what enforces it. Three of
    # the five this list shipped with — "BOOLEAN attribute", "NOT AN OVERSIGHT", "mutation-check" —
    # matched NO template at all, so they were incapable of ever firing while the comment above them
    # claimed they were drawn from the templates. A needle nothing contains is not a lenient guard,
    # it is an absent one, and deleting it reds nothing.
    LEAKED_PROSE = [
      "§14",
      "§15",
      "ONE BUTTON, TWO FLOWS",
      "TWO CONTROLS, ONE JOB EACH",
      "WHERE THE USER CAME FROM",
      "BACKUPS COME OUT FIRST",
      "NO HARDCODED CARDS"
    ].freeze

    test "no page renders the prose of its own code comments" do
      templates = erb_templates
      LEAKED_PROSE.each do |phrase|
        refute_empty templates.select { |_rel, src| src.include?(phrase) },
                     "#{phrase.inspect} is in no template, so this needle can never fire — " \
                     "reword it to a phrase a live comment actually contains, or drop it"
      end

      rendered = Set.new
      sub = ActiveSupport::Notifications.subscribe(/render_(template|partial)\.action_view/) do |*args|
        id = args.last[:identifier].to_s
        rendered << id.delete_prefix(views_root) if id.start_with?(views_root)
      end

      begin
        pages.each do |name, path|
          get path
          LEAKED_PROSE.each do |phrase|
            assert_not_includes response.body, phrase,
                                "#{name} rendered a code comment into the page (found #{phrase.inspect})"
          end
        end
        frame_pages.each do |name, (path, frame)|
          get path, headers: { "Turbo-Frame" => frame }
          assert_response :success, "#{name} (#{path}) did not render"
          LEAKED_PROSE.each do |phrase|
            assert_not_includes response.body, phrase,
                                "#{name} rendered a code comment into the frame (found #{phrase.inspect})"
          end
        end
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      # DERIVED FROM THE TREE, NOT A LIST TO KEEP IN STEP — the same shape that fixed
      # `deploy_hygiene_test.rb` (§14e). Every guard above only sees a template some page in `pages`
      # actually renders, so without this a new template is unguarded from the day it is added and
      # nothing says so: `models/show.html.erb` was grown to five comment sites by a commit on this
      # very branch while this file could not see it. A new template must be swept or explicitly
      # excused.
      uncovered = templates.keys.reject { |rel| rendered.include?(rel) || excused?(rel) }
      assert_empty uncovered,
                   "no page in `pages` renders these templates, so nothing here can see a leaked " \
                   "comment in them — add a page that renders each, or add its directory to " \
                   "UNSWEPT_DIRS with a reason"
    end

    private

    def views_root = @views_root ||= "#{Rails.root.join('app/views')}/"

    # `encoding: "UTF-8"` is required, not tidiness: these templates contain §, ⌀, ✕ and …, and a
    # bare read leaves the string tagged US-ASCII, where `String#scan` raises on the first one.
    def erb_templates
      @erb_templates ||= Dir.glob(Rails.root.join("app/views/**/*.erb")).sort.to_h do |abs|
        [ abs.delete_prefix(views_root), File.read(abs, encoding: "UTF-8") ]
      end
    end

    def excused?(rel)
      UNSWEPT_DIRS.any? { |dir| rel.start_with?(dir) } || UNSWEPT_TEMPLATES.include?(rel)
    end
  end
end
