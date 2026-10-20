# THE TRASH ENTRY MODEL, ON THE TWO ADAPTERS THAT KEEP ONE: share and s3. Never chunk_remote, whose
# trash is the sync server's and whose mirror records `deleted` and nothing else, so none of this is
# a property of the PORT. It is a property of the two adapters that move bytes into `.trash`
# themselves, and both must answer it identically, which is why it is written once.
#
# A TRASH ENTRY IS RECORDED, NOT INFERRED (F-S02-1, 2026-10-20). `nodes.trash_root_node_id` names the
# entry a tombstone went into: its own node_id when it was the thing deleted, its folder's when it
# travelled inside one, NULL on a live row and on a SCAN tombstone. Before it, a folder restore
# revived every walked row whose rebuilt path existed, so a file deleted on its own and replaced
# inside the folder came back over its replacement's bytes, or collided with it and 500ed.
#
# Include alongside FileLayerMutationContract, whose `make_file`/`make_dir` hooks it uses. Two more:
#
#   delete_file!(node_id)       -> the file removed OUT OF BAND (Finder, rclone, the console) and the
#                                  scan's tombstone after it: a SCAN tombstone, its path kept.
#   purge_trash_entry!(node_id) -> what Library::TrashPurgeJob does to an aged entry: every byte
#                                  under `.trash/<node_id>/` goes, and no row is touched.
module FileLayerTrashEntryContract
  # THE TWO SPELLINGS OF "TRASH TOMBSTONE" MUST AGREE ON EVERY ROW. A NULL `storage_path` on a deleted
  # row is what makes `Reconciler#create_or_revive!` unable to revive it by path (§14a's two kinds);
  # `trash_root_node_id` is what `undelete` reads to decide what comes back. A row with one and not
  # the other is a row the trash lists and cannot restore, or restores and the scan can steal.
  def assert_trash_spellings_agree(context)
    drift = @user.nodes.reload.reject do |n|
      n.trash_root_node_id.present? == (n.deleted? && n.storage_path.nil?)
    end
    assert_empty drift.map { |n| n.attributes.slice("name", "deleted", "storage_path", "trash_root_node_id") },
                 "#{context}: a row is a trash tombstone (deleted, path NULL) exactly when it names " \
                 "the trash entry it went into"
  end

  # Driven through every door that writes either spelling: a delete on its own, an out-of-band
  # removal, a folder delete holding both of those, and the three restores. The precise roots are
  # asserted at the two points that would otherwise let the guard pass over nothing.
  def test_trash_entry_contract_a_row_is_trash_exactly_when_it_names_its_entry
    dir_id = make_dir(name: "F")
    sub_id = adapter.mkdir(@user, parent_node_id: dir_id, name: "sub").node_id
    leaf_id = adapter.write(@user, parent_node_id: sub_id, name: "a.stl", io: StringIO.new("a")).node_id
    older_id = adapter.write(@user, parent_node_id: dir_id, name: "older.stl",
                             io: StringIO.new("older")).node_id
    gone_id = adapter.write(@user, parent_node_id: dir_id, name: "gone.stl", io: StringIO.new("gone")).node_id
    alone_id = make_file(name: "alone.stl", bytes: "alone")
    assert_trash_spellings_agree "a library with nothing deleted"

    adapter.delete(@user, node_id: alone_id)
    assert_equal alone_id, @user.nodes.find_by!(node_id: alone_id).trash_root_node_id,
                 "a file deleted on its own is the root of its own entry"
    assert_trash_spellings_agree "a file deleted on its own"

    delete_file!(gone_id)
    assert_trash_spellings_agree "a file removed out of band"

    adapter.delete(@user, node_id: older_id)
    adapter.delete(@user, node_id: dir_id)
    assert_equal [ dir_id ] * 3,
                 [ dir_id, sub_id, leaf_id ].map { |id| @user.nodes.find_by!(node_id: id).trash_root_node_id },
                 "the folder's entry is what its delete moved"
    assert_trash_spellings_agree "a folder delete over a scan tombstone and an older entry"

    adapter.undelete(@user, node_id: dir_id)
    assert_trash_spellings_agree "a folder restore"

    adapter.undelete(@user, node_id: older_id)
    adapter.undelete(@user, node_id: alone_id)
    assert_trash_spellings_agree "every restore"
  end

  # THE REPLACE WORKFLOW WITH THE EARLIER ENTRY PURGED: delete `x.stl`, upload a corrected `x.stl`,
  # delete the folder, and restore it once the purge has reclaimed the first delete's bytes. Nothing
  # on disk or in the bucket says the first `x.stl` was deleted on its own any more, so a restore
  # that infers membership from where bytes are reached both rows: the second revive hit the partial
  # unique index (a 500 mid-restore, the rows it had not reached left pathless for the next scan to
  # mint anew), or the old row came back over the corrected bytes. The column remembers.
  def test_trash_entry_contract_restoring_a_folder_revives_exactly_what_its_delete_moved
    dir_id = make_dir(name: "F")
    first_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl", io: StringIO.new("first")).node_id
    adapter.delete(@user, node_id: first_id)
    second_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl",
                              io: StringIO.new("corrected")).node_id
    keep_id = adapter.write(@user, parent_node_id: dir_id, name: "keep.stl", io: StringIO.new("keep")).node_id
    adapter.delete(@user, node_id: dir_id)
    purge_trash_entry!(first_id)

    assert_nothing_raised { adapter.undelete(@user, node_id: dir_id) }

    assert_equal "corrected", adapter.read(@user, node_id: second_id)
    assert_equal "F/x.stl", @user.nodes.find_by!(node_id: second_id).storage_path
    assert_equal "keep", adapter.read(@user, node_id: keep_id)
    first = @user.nodes.find_by!(node_id: first_id)
    assert first.deleted?, "restoring the folder undid an earlier delete inside it"
    assert_nil first.storage_path
    assert_equal first_id, first.trash_root_node_id, "the earlier delete is still its own entry"
  end

  # ROWS THE BACKFILL CANNOT TELL APART. The cascade before 2026-10-19 rewrote and re-stamped every
  # tombstone already inside the folder, so a file or a folder deleted on its own before its parent
  # reads exactly like one that travelled with it, and the migration files it into the parent's
  # entry. Its bytes are still in its OWN entry. So membership binds only while its root is in the
  # trash: once the folder is back, such a row is restored on its own, from its own entry, and a
  # folder restored that way brings back the rows that recorded the same root beneath it.
  def test_trash_entry_contract_a_row_filed_into_its_folder_by_the_backfill_comes_back_on_its_own
    dir_id = make_dir(name: "F")
    file_id = adapter.write(@user, parent_node_id: dir_id, name: "old.stl", io: StringIO.new("old")).node_id
    sub_id = adapter.mkdir(@user, parent_node_id: dir_id, name: "G").node_id
    inner_id = adapter.write(@user, parent_node_id: sub_id, name: "g.stl", io: StringIO.new("g")).node_id
    keep_id = adapter.write(@user, parent_node_id: dir_id, name: "keep.stl", io: StringIO.new("keep")).node_id
    adapter.delete(@user, node_id: file_id)
    adapter.delete(@user, node_id: sub_id)
    adapter.delete(@user, node_id: dir_id)
    @user.nodes.where(node_id: [ file_id, sub_id, inner_id ]).update_all(trash_root_node_id: dir_id)

    adapter.undelete(@user, node_id: dir_id)

    assert_equal "keep", adapter.read(@user, node_id: keep_id)
    [ file_id, sub_id, inner_id ].each do |id|
      assert @user.nodes.find_by!(node_id: id).deleted?, "#{id} came back although its bytes did not"
    end

    adapter.undelete(@user, node_id: file_id)
    assert_equal "old", adapter.read(@user, node_id: file_id)
    adapter.undelete(@user, node_id: sub_id)
    assert_equal "g", adapter.read(@user, node_id: inner_id), "the folder's own contents stayed behind"
    assert_trash_spellings_agree "after restoring rows the backfill misfiled"
  end
end
