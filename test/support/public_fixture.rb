require "support/kicad_fixture"

# THE PUBLISHABLE PROJECT, seeded once and shared by the four S3-4 suites (stage 3, S3-4). Every
# shape the public page or the public file route has to answer for lives here, so a suite asserts
# about a fixture it did not have to build and the four cannot drift about what "a published
# project" contains.
#
# IT PINS SHARE, AND THE SUITES THAT INCLUDE IT MUST CALL `use_fresh_share_library!` FIRST. These
# tests read REAL BYTES through the port — a README, a download, a KiCanvas fetch — and a fixture
# built with `create_node!` has an object behind it only on share: on s3 the stub bucket holds
# nothing and on chunk_remote there is no version, so every byte assertion would fail for a reason
# that has nothing to do with publishing. readme_test.rb and project_repo_card_test.rb pin the same
# way for the same reason, and their headers record it.
#
# NEVER `ensure_library_folder!`: that is a real mkdir through the port, which is a Forbidden
# against the s3 stub and a library provisioning against a sync server (§14a, and the house rule in
# memory). `project_folder_rows!` writes the two dir ROWS; this module adds the storage_path and
# the directory those rows claim to be, exactly as readme_test.rb's `project_folder!` does.
module PublicFixture
  include KicadFixture

  PASSWORD = "correct horse battery staple".freeze

  # A README exercising all three link shapes Maker::Readme has to resolve: a relative link to a
  # file in a SUBFOLDER, a relative inline IMAGE, and an ABSOLUTE image (which Task B turns into
  # its own alt text rather than a request to another origin).
  README_BODY = <<~MD.freeze
    # Desk Lamp

    A lamp that sits on a desk.

    See [base](models/base.stl) for the printed part.

    ![pic](photos/pic.png)

    ![ext](https://x.example/p.gif)
  MD

  PNG_BYTES = "\x89PNG\r\n\x1a\n".b.freeze

  def make_owner!(handle:, email: nil)
    User.create!(email: email || "#{handle}-#{SecureRandom.hex(4)}@example.com",
                 password: PASSWORD, confirmed_at: Time.current, handle:)
  end

  def sign_in_as(user)
    post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
  end

  # Rows PLUS the directory they claim to be — see this module's header for why it is not
  # `ensure_library_folder!`.
  def make_project_folder!(user, project)
    folder = project_folder_rows!(user, project)
    user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    folder
  end

  def make_dir!(user, name, parent)
    create_node!(user, node_id: SecureRandom.uuid, name:, kind: "dir",
                 parent_node_id: parent.node_id, mtime: 1, size: 0)
  end

  # `create_node!` writes a literal "x" placeholder through the port's own path arithmetic; the
  # real body is written over it at the storage_path the catalog ended up holding, so the two can
  # never disagree about where the file is (readme_test.rb's `file!` does exactly this).
  def make_file!(user, name, parent, body: "x")
    node = create_node!(user, node_id: SecureRandom.uuid, name:, kind: "file",
                        parent_node_id: parent.node_id, mtime: 1, size: body.bytesize)
    @root.join(node.storage_path).binwrite(body)
    node
  end

  # EVERYTHING A PUBLIC PAGE CAN SHOW, in one project. Returns a Hash of the node/record handles the
  # suites assert about. `@user` must already be `owner` when this runs — KicadFixture's
  # `write_kicad_schematic!` reads that ivar.
  #
  # THE ENTRY PHOTO DELIBERATELY LIVES OUTSIDE THE FOLDER (at the library root), because that is
  # what makes the ATTACHMENT arm of `Maker::PublicProject#permits?` reachable at all: everything
  # inside the folder is already permitted by ancestry, so a photo seeded in the folder would leave
  # the attachment branch untested and the "drop attached_ids" mutation green.
  def seed_public_project!(owner, name: "Desk Lamp", visibility: "public", tags: "lamp, laser")
    project = owner.maker_projects.create!(name:, description: "A lamp that sits on a desk.",
                                           visibility:, license: "CERN-OHL-P-2.0", tag_list: tags)
    folder = make_project_folder!(owner, project)

    models  = make_dir!(owner, "models", folder)
    deep    = make_dir!(owner, "deep", models)
    photos  = make_dir!(owner, "photos", folder)
    firmware = make_dir!(owner, "firmware", folder)
    # The `.git` MARKER is what makes `firmware` a working tree (§14b: the marker keeps its entry;
    # only its contents are dropped). There is no real repository behind it, so Maker::RepoCard
    # answers a refusal rather than git facts — which is the branch the public card has to render
    # without linking anywhere private, and is what page_query_budget_test.rb's own seed does too.
    make_dir!(owner, Library::RepoMetadata::DIR_NAME, firmware)

    out = {
      project:, folder:, models:, deep:, photos:, firmware:,
      readme:    make_file!(owner, "README.md", folder, body: README_BODY),
      dotfile:   make_file!(owner, ".env", folder, body: "SECRET=1\n"),
      base:      make_file!(owner, "base.stl", models, body: "solid base"),
      deep_file: make_file!(owner, "x.stl", deep, body: "solid deep"),
      pic:       make_file!(owner, "pic.png", photos, body: PNG_BYTES),
      repo_readme: make_file!(owner, "README.md", firmware, body: "# Firmware\n"),
      # A SIBLING OF THE FOLDER, unattached: the negative case the permission matrix needs.
      outsider:  make_file!(owner, "elsewhere.stl", owner.nodes.find_by!(node_id: folder.parent_node_id),
                            body: "solid outside"),
      kicad:     write_kicad_schematic!(name: "driver.kicad_sch", parent_node_id: folder.node_id)
    }

    # The entry photo, at the library ROOT — outside the folder, so only the attachment arm can
    # permit it.
    root_photo = create_node!(owner, node_id: SecureRandom.uuid, name: "shot.png", kind: "file",
                              mtime: 1, size: PNG_BYTES.bytesize)
    @root.join(root_photo.storage_path).binwrite(PNG_BYTES)
    entry = project.build_log_entries.create!(user: owner, body: "Cut the base tonight.",
                                              logged_at: Time.zone.local(2026, 5, 1, 12, 0, 0))
    entry.file_attachments.create!(user: owner, node_id: root_photo.node_id, role: "image", position: 0)
    out[:entry] = entry
    out[:entry_photo] = root_photo

    # A BOM with one line of EACH target kind. The item carries 7 on hand and a supplier precisely
    # so the public table can be asserted NOT to show either.
    supplier = owner.maker_suppliers.create!(name: "Acme Supply")
    item = owner.maker_inventory_items.create!(name: "M3 bolt", unit: "each", min_quantity: 5)
    Maker::InventoryTransaction.apply!(item:, user: owner, delta: 7, reason: "initial")
    bom = project.boms.create!(user: owner)
    bom.lines.create!(user: owner, inventory_item: item, supplier:, quantity: 2, unit: "each",
                      reference: "B1", position: 0)
    bom.lines.create!(user: owner, node_id: out[:base].node_id, quantity: 1, unit: "each",
                      reference: "F1", position: 1)
    bom.lines.create!(user: owner, part_name: "22 AWG wire", quantity: 3, unit: "m",
                      reference: "T1", position: 2)
    out.merge!(bom:, item:, supplier:)

    project.connections.create!(user: owner, from_label: "Driver board", to_label: "Stepper motor",
                                wire: "22 AWG", position: 0)
    project.connections.create!(user: owner, from_label: "Stepper motor", to_label: "Frame",
                                wire: "M3", position: 1)
    out
  end
end
