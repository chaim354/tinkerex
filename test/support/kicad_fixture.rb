# A REAL, MINIMAL KiCad 8 schematic KiCanvas can actually parse — shared between
# test/system/kicanvas_test.rb (which asserts the viewer renders) and test/system/shell_test.rb's
# phone-width sweep (which needs the :kicanvas branch's real markup on the page, not the
# "No content yet." fallback, and needs KiCanvas not to error on garbage bytes and trip
# assert_no_console_errors for a reason that has nothing to do with layout).
#
# test/system/README.md's own house rule for this suite: a Selenium page fetches the blob URL for
# real, so — same as test/system/file_menu_test.rb's local create_file! and
# test/system/code_theme_test.rb's Scanner-based setup — test_helper.rb's shared `create_node!`
# will not do here. That helper always writes a literal "x" placeholder for a file node
# (deliberately: most fixtures never read the bytes back), which KiCanvas would receive as
# unparseable garbage.
module KicadFixture
  # TODO(kicanvas fixture): set by test/system/kicanvas_test.rb's own probing — see that file's
  # header comment for what KiCanvas actually needed.
  MINIMAL_KICAD_SCH = <<~SCH
    (kicad_sch (version 20211123) (generator eeschema)
      (uuid c0326988-8693-490b-a3fb-e69d8c3ef544)
      (paper "A4")
      (lib_symbols
      )
      (sheet_instances
        (path "/" (page "1"))
      )
    )
  SCH

  # A REAL FILE ON DISK, node row content_hash MATCHING IT — mirrors
  # test/system/file_menu_test.rb's local create_file! exactly, and for the identical reason its
  # own comment gives: `nodes.create!`, NOT test_helper's create_node!, because that helper
  # materialises its own "x" placeholder and would overwrite real bytes immediately after writing
  # them.
  def write_kicad_schematic!(name:, parent_node_id: nil, body: MINIMAL_KICAD_SCH)
    parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
    rel = parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
    path = @root.join(rel)
    path.dirname.mkpath
    path.binwrite(body)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id:,
                        size: body.bytesize, storage_path: rel, mtime: 1_000_000_000,
                        content_hash: Digest::SHA256.hexdigest(body))
  end
end
