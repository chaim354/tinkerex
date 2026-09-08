require "test_helper"

module Web
  # The file page's head and notes (spec §8, PR 2): the format sits beside the name as a badge,
  # and the notes composer is closed until asked for — the same form, the same Lexxy editor, the
  # same field, inside a <details>. The page's actions keep Back as the only ghost button
  # (back_link_test reads it by that selector).
  class FilePageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "fp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @node = @user.nodes.create!(node_id: "n-coaster", name: "coaster.lbrn2", kind: "file",
                                  mtime: 1_000_000_000, size: 2_400)
    end

    test "the head shows the format as a badge beside the name" do
      get file_path(@node.node_id)
      assert_response :success
      assert_select ".page-head h1", text: "coaster.lbrn2"
      assert_select ".page-head .badge.file-badge", text: "LBRN2"
      assert_select ".page-actions a.btn.ghost", count: 1, text: "Back"
    end

    test "the notes composer is a closed details that still holds the whole form" do
      get file_path(@node.node_id)
      assert_select ".notes-panel details.composer:not([open]) > summary", text: "Add a note"
      assert_select ".notes-panel details.composer form.note-form[action=?] lexxy-editor[attachments='false']",
                    file_notes_path(@node.node_id)
      assert_select ".notes-panel details.composer form.note-form input[type='submit'][value='Add note']"
      assert_select ".notes-panel", text: /No notes yet\./
    end

    test "a file with no extension gets no badge" do
      bare = @user.nodes.create!(node_id: "n-license", name: "LICENSE", kind: "file", mtime: 1_000_000_000, size: 10)
      get file_path(bare.node_id)
      assert_select ".page-head .file-badge", count: 0
    end

    # WHERE THE FILE IS ON THE SHARE — story 2.10's whole complaint. The page showed Name, Size,
    # Type and Modified and never once said where the thing lives, so the way back to LightBurn was
    # to remember the folder. Root-relative and NOT a URL: this app cannot know the mount's name on
    # the maker's own machine, and inventing an smb:// would be a guess dressed as a fact.
    #
    # THE CONTROLLER AND THE VALUE SIT ON THE `dd` ITSELF, so both selectors below are ATTRIBUTE
    # QUALIFIERS (`dd[...]`) and not descendant combinators (`dd [...]`). A space there asks for a
    # child carrying the attribute, which nothing does — it is the shape that passes vacuously in
    # the other direction, so it is written tightly on purpose.
    test "the meta list carries the file's library path, with a copy button over it" do
      cad = @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir",
                                mtime: 1_000_000_000, size: 0)
      deep = @user.nodes.create!(node_id: "d-lids", name: "lids", kind: "dir",
                                 parent_node_id: cad.node_id, mtime: 1_000_000_000, size: 0)
      node = @user.nodes.create!(node_id: "n-lid", name: "lid.lbrn2", kind: "file",
                                 parent_node_id: deep.node_id, mtime: 1_000_000_000, size: 12)

      get file_path(node.node_id)

      assert_response :success
      assert_select "dl.meta dt", text: "Path"
      assert_select "dl.meta dd .file-path-value", text: "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd[data-controller~=?]", "copy"
      assert_select "dl.meta dd[data-copy-text-value=?]", "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd button[data-action=?]", "copy#copy", text: "Copy"
    end

    test "a file at the library root is its own path" do
      get file_path(@node.node_id)
      assert_select "dl.meta dd .file-path-value", text: "coaster.lbrn2"
    end

    # A BROKEN ANCESTOR CHAIN IS "WE DO NOT KNOW", NOT A ROOT-LEVEL FILE. Maker::LibraryTree
    # #path_for answers nil for a tombstoned or missing ancestor; rendering the bare name there
    # would say the file sits at the top of the library, which is a confident lie about where to
    # find it. No row at all is the honest answer.
    test "a file whose folder chain is broken shows no path rather than a wrong one" do
      orphan = @user.nodes.create!(node_id: "n-orphan", name: "stray.svg", kind: "file",
                                   parent_node_id: "d-gone", mtime: 1_000_000_000, size: 1)
      get file_path(orphan.node_id)
      assert_select "dl.meta dt", text: "Path", count: 0
    end

    # ---- END OF S4-3 TASK C's ADDITIONS -------------------------------------------------------
    # Task D (Save to library) appends BELOW this line, so the two tasks' tests never interleave.

    # THE SAVE TWINS, AND THE ASSERTION BRANCHES ON THE DEPLOYMENT (§14a). `port_writable` names
    # WHICH DOOR the bytes go in, not whether uploads are possible: share and s3 POST them to
    # FilesController#create, chunk_remote drives begin_upload/finalize_upload. A form-shaped
    # assertion here would be red on the chunk_remote leg alone, which is the memory
    # `upload-form-assertions-must-branch-on-port-writable` records twice.
    #
    # THE NODE CARRIES BOTH CONTENT COLUMNS, and a bare `nodes.create!` would not do. `@node` above
    # has a nil `content_token`, which short-circuits the whole preview tree at show.html.erb's
    # `@info.content_token.nil?` arm — so no measure branch renders at all and every selector below
    # would be vacuously absent. The idiom is template_hygiene_test.rb:266-276's.
    test "the Measure bar offers Save to library beside each download, wired to this deployment's door" do
      node = @user.nodes.create!(node_id: "n-plate", name: "plate.lbrn2", kind: "file",
                                 mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-plate", current_version_id: "v-plate")

      get file_path(node.node_id)

      assert_response :success
      assert_select ".measure-actions button[data-action=?]", "measure#saveSvg", text: "Save SVG"
      assert_select ".measure-actions button[data-action=?]", "measure#savePrint", text: "Save sheet"
      # The SOURCE's own parent — a save lands beside the file it came from, never at the root.
      assert_select ".measure-view[data-measure-parent-node-id-value=?]", ""
      # `capabilities` is a controller helper_method, so it is NOT in scope in an integration test:
      # ask the port directly, which is the same object the view's helper resolves to.
      if FileLayer.current.capabilities.port_writable?
        assert_select ".measure-view[data-measure-port-writable-value=?]", "true"
        assert_select ".measure-view[data-measure-create-url-value=?]", files_path
      else
        assert_select ".measure-view[data-measure-port-writable-value=?]", "false"
        assert_select ".measure-view[data-measure-begin-url-value=?]", begin_upload_files_path
        assert_select ".measure-view[data-measure-finalize-url-value=?]", finalize_upload_files_path
      end
    end

    test "the save target is the source file's own folder" do
      dir = @user.nodes.create!(node_id: "d-design", name: "design", kind: "dir",
                                mtime: 1_000_000_000, size: 0)
      node = @user.nodes.create!(node_id: "n-lid2", name: "lid.lbrn2", kind: "file",
                                 parent_node_id: dir.node_id, mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-lid2", current_version_id: "v-lid2")

      get file_path(node.node_id)

      assert_select ".measure-view[data-measure-parent-node-id-value=?]", "d-design"
    end

    # ---- the Connected panel (stage 4, S4-8) --------------------------------------------
    # Task B appends BELOW this line. @node above is a bare row with a nil content_token, which
    # short-circuits the preview tree — these cases never reach it, so it is the right fixture here.

    def link_file!(id, name)
      @user.nodes.create!(node_id: id, name:, kind: "file", mtime: 1_000_000_000, size: 10)
    end

    def link!(from, to, kind)
      @user.maker_file_links.create!(from_node_id: from, to_node_id: to, kind:)
    end

    test "with no links the panel still renders, carrying both hand doors and no rows" do
      get file_path(@node.node_id)
      assert_response :success
      assert_select "section.connections-panel", count: 1
      assert_select ".connections-panel .connection-row", count: 0
      # THE DOORS ARE THE POINT OF AN EMPTY PANEL. A file with no lineage is exactly the file whose
      # page has to offer "This came from …"; hiding the panel until a link exists would make the
      # first link unreachable from the app.
      assert_select ".connections-panel details.composer > summary", text: "This came from…"
      assert_select ".connections-panel details.composer > summary", text: "Add a photo of this"
    end

    test "both directions of derived_from render, each naming the other file" do
      source = link_file!("n-src-lbrn", "coaster.lbrn2")
      export = link_file!("n-out-svg", "coaster-parts.svg")
      link!(export.node_id, source.node_id, "derived_from")

      get file_path(export.node_id)
      assert_select ".connections-derived-from a[href=?]", file_path(source.node_id), text: "coaster.lbrn2"

      get file_path(source.node_id)
      assert_select ".connections-derived a[href=?]", file_path(export.node_id), text: "coaster-parts.svg"
    end

    test "a photo renders on the file it shows, and the file renders on the photo" do
      subject = link_file!("n-lid", "lid.stl")
      photo = link_file!("n-shot", "cut.png")
      link!(photo.node_id, subject.node_id, "photo_of")

      get file_path(subject.node_id)
      assert_select ".connections-photos a[href=?]", file_path(photo.node_id)
      assert_select ".connections-photos [data-thumbs-target='cell'][data-node-id=?]", photo.node_id

      get file_path(photo.node_id)
      assert_select ".connections-depicts a[href=?]", file_path(subject.node_id), text: "lid.stl"
    end

    # LIVENESS IS THE READER'S QUESTION (§14a). The row survives until Maker::AttachmentReaper's
    # window closes; the page must stop showing it the moment the file is gone.
    test "a link whose other end is a tombstone or absent is dropped from the render" do
      subject = link_file!("n-live", "live.stl")
      dead = @user.nodes.create!(node_id: "n-tomb", name: "gone.stl", kind: "file",
                                 mtime: 1_000_000_000, size: 1, deleted: true)
      link!(subject.node_id, dead.node_id, "derived_from")
      link!(subject.node_id, "never-existed", "derived_from")

      get file_path(subject.node_id)
      assert_select ".connections-panel .connection-row", count: 0
      assert_equal 2, @user.maker_file_links.count, "the rows survive; only the render drops them"
    end

    # §14d: a form_with with no model:/scope: has a blank object_name. These fields are FLAT and
    # must stay flat — Files::LinksController reads params[:kind] and params[:other_node_id], and a
    # nested-hash test could not see the difference. Assert the RENDERED field name.
    test "the hand doors post flat field names to this file's links endpoint" do
      get file_path(@node.node_id)
      assert_select "form.link-form[action=?]", file_links_path(@node.node_id), count: 2
      # THE NAME ONLY. Which door writes which VALUE is the next test's subject, and it has to be
      # asked inside a door: a page-wide pair of value assertions is satisfied by two doors that
      # have SWAPPED their kinds, which is a live bug rather than a cosmetic one.
      assert_select "form.link-form input[type=hidden][name='kind']", count: 2
      assert_select "form.link-form input[type=hidden][name='other_node_id']", count: 2
    end

    # The picker is the EXISTING chooser in file mode (shared/_folder_field), filtered for the
    # photo door from ROLE_BY_EXT and not from a second list.
    test "the photo door's picker is filtered to the image vocabulary" do
      get file_path(@node.node_id)
      assert_select ".folder-field[data-filechooser-mode-value='file']", count: 2
      assert_select ".folder-field[data-filechooser-extensions-value=?]",
                    Maker::FileAttachment::IMAGE_EXTS.to_json, count: 1
    end

    # WHICH DOOR WRITES WHICH KIND, ASKED INSIDE THE DOOR. Asserting each value "somewhere on the
    # page" cannot fail for the reason it exists: SWAP the two hidden kinds in _connections.html.erb
    # and both values are still present, still one each, still in a form.link-form — green. The swap
    # is not cosmetic. It points the UNFILTERED source picker at `photo_of`, so every non-image
    # source is refused by Files::LinksController with "Only an image can be a photo of a file.",
    # and the image-filtered picker at `derived_from`, which silently records the wrong lineage.
    #
    # Nokogiri's CSS has no `:contains`, so the doors are told apart by walking `details.composer`
    # and reading each summary — the label the user actually clicked. Each door is then asserted to
    # carry exactly ONE kind, so it cannot pass by gaining a second hidden input beside the wrong
    # one, and each is pinned to its own picker (the photo door is the filtered one, §14a's
    # convenience-not-a-refusal filter) so the two halves cannot drift apart either.
    test "each hand door writes its own kind, asserted inside that door" do
      get file_path(@node.node_id)

      doors = css_select(".connections-panel details.composer")
              .index_by { |door| door.at_css("summary").text.strip }
      assert_equal [ "Add a photo of this", "This came from…" ], doors.keys.sort

      source_door = doors.fetch("This came from…")
      assert_select source_door, "form.link-form input[type=hidden][name='kind']", { count: 1 },
                    "the 'This came from…' door must carry exactly one kind"
      assert_select source_door, "form.link-form input[type=hidden][name='kind'][value=?]",
                    "derived_from", { count: 1 },
                    "the 'This came from…' door must write derived_from"
      assert_select source_door, ".folder-field[data-filechooser-extensions-value]", { count: 0 },
                    "the 'This came from…' door's picker offers every file, unfiltered"

      photo_door = doors.fetch("Add a photo of this")
      assert_select photo_door, "form.link-form input[type=hidden][name='kind']", { count: 1 },
                    "the 'Add a photo of this' door must carry exactly one kind"
      assert_select photo_door, "form.link-form input[type=hidden][name='kind'][value=?]",
                    "photo_of", { count: 1 },
                    "the 'Add a photo of this' door must write photo_of"
      assert_select photo_door, ".folder-field[data-filechooser-extensions-value=?]",
                    Maker::FileAttachment::IMAGE_EXTS.to_json, { count: 1 },
                    "the 'Add a photo of this' door is the image-filtered picker"
    end

    # THE REMOVE CONTROL, ASSERTED WHERE IT RENDERS. `method: :delete` is a HIDDEN INPUT inside the
    # form, never an attribute on it — a button_to form is a POST either way — so dropping it from
    # the four button_to calls changes nothing a row-shaped assertion can see: the × still renders,
    # still carries its confirm and its label, and every Remove button POSTs /file_links/:id, which
    # no route answers. One row per list, each asserted against its OWN link id, because a
    # page-wide "there is a delete form somewhere" is satisfied by one working button out of four.
    test "each Remove control is a DELETE form naming its own link and this page" do
      source   = link!(@node.node_id, link_file!("n-src", "source.lbrn2").node_id, "derived_from")
      output   = link!(link_file!("n-out", "output.svg").node_id, @node.node_id, "derived_from")
      photo    = link!(link_file!("n-photo", "shot.png").node_id, @node.node_id, "photo_of")
      depicted = link!(@node.node_id, link_file!("n-dep", "lid.stl").node_id, "photo_of")

      get file_path(@node.node_id)
      assert_select ".connections-panel .connection-row", { count: 4 },
                    "all four lists must render, or this test covers fewer than it claims"

      { ".connections-derived-from" => [ source,   "Unlink source.lbrn2?", "Unlink source.lbrn2" ],
        ".connections-derived"      => [ output,   "Unlink output.svg?", "Unlink output.svg" ],
        ".connections-photos"       => [ photo, "Remove this photo link?", "Remove the link to shot.png" ],
        ".connections-depicts"      => [ depicted, "Unlink lid.stl?", "Unlink lid.stl" ]
      }.each do |group, (link, confirm, label)|
        assert_select "#{group} .connection-row form[action=?][data-turbo-confirm=?]",
                      file_link_path(link), confirm, { count: 1 },
                      "#{group} must render one remove form, for its own link, with its confirm" do
          assert_select "input[type=hidden][name='_method'][value='delete']", { count: 1 },
                        "#{group}'s remove control must be a DELETE, not a bare POST"
          # `from` IS THE PAGE THE BUTTON WAS ON. Either end of a pair renders the row, and
          # Files::LinksController#destroy falls back to link.from_node_id without it — which sends
          # the user to the OTHER file for three of these four lists.
          assert_select "input[type=hidden][name='from'][value=?]", @node.node_id, { count: 1 },
                        "#{group}'s remove control must carry this page's node as `from`"
          assert_select "button[type='submit'][aria-label=?]", label, { count: 1 },
                        "#{group}'s remove control must name the file it unlinks"
        end
      end
    end

    # ---- the Measure save's own lineage (stage 4, S4-8, Task C) --------------------------
    #
    # THE REQUEST-LEVEL CLAIM ABOUT AN ATTRIBUTE THE BROWSER TEST CANNOT PIN. measure_export_test
    # drives the real save and reads the row back, so it passes whether or not the ATTRIBUTE is
    # present — it would simply record no link and fail one assertion later, on a different
    # subject. This asserts the two values reach the DOM, which is what the writer reads.
    #
    # `__ID__` IS A TEMPLATE THE SERVER WRITES: the new node's id does not exist until the upload
    # answers, and the Stimulus controller must not learn a route (the viewer partials take every
    # URL as a strict local — architecture_invariants_test.rb scans that directory).
    test "the Measure view carries the source node and the links endpoint for its save" do
      node = @user.nodes.create!(node_id: "n-plate2", name: "plate.lbrn2", kind: "file",
                                 mtime: 1_000_000_000, size: 90,
                                 content_hash: "h-plate2", current_version_id: "v-plate2")
      get file_path(node.node_id)
      assert_select ".measure-view[data-measure-source-node-id-value=?]", node.node_id
      assert_select ".measure-view[data-measure-link-url-value=?]", file_links_path("__ID__")
    end
  end
end
