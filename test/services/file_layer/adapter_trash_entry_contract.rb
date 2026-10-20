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
# Include alongside FileLayerMutationContract, whose `make_file`/`make_dir` hooks it uses. Three more:
#
#   delete_file!(node_id)       -> the file removed OUT OF BAND (Finder, rclone, the console) and the
#                                  scan's tombstone after it: a SCAN tombstone, its path kept.
#   purge_trash_entry!(node_id) -> what Library::TrashPurgeJob does to an aged entry: every byte
#                                  under `.trash/<node_id>/` goes, and no row is touched.
#   lose_from_trash_entry!(root_id, path)
#                               -> ONE member's bytes gone from an entry, `path` beneath the entry's
#                                  id (`<root name>/<rel>`): lost by hand or by a store, no row touched.
module FileLayerTrashEntryContract
  # THE TWO SPELLINGS OF "TRASH TOMBSTONE" MUST AGREE ON EVERY ROW. A NULL `storage_path` on a deleted
  # row is what makes `Reconciler#create_or_revive!` unable to revive it by path (§14a's two kinds);
  # `trash_root_node_id` is what `undelete` reads to decide what comes back. A row with one and not
  # the other is a row the trash lists and cannot restore, or restores and the scan can steal.
  #
  # AND EVERY RECORDED ENTRY NAMES A ROOT STILL IN THE TRASH: a row whose own value is itself. The id
  # is the deleted node's own node_id, which the same folder's NEXT delete writes again, so a row still
  # naming a root that came back is read as a member of that next entry — revived over a same-named
  # replacement's bytes, or colliding with it in the partial unique index (audit defect (b)).
  def assert_trash_spellings_agree(context)
    rows = @user.nodes.reload.to_a
    drift = rows.reject { |n| n.trash_root_node_id.present? == (n.deleted? && n.storage_path.nil?) }
    assert_empty drift.map { |n| n.attributes.slice("name", "deleted", "storage_path", "trash_root_node_id") },
                 "#{context}: a row is a trash tombstone (deleted, path NULL) exactly when it names " \
                 "the trash entry it went into"

    roots = rows.select { |n| n.trash_root_node_id == n.node_id }.to_set(&:node_id)
    stray = rows.select { |n| n.trash_root_node_id.present? && !roots.include?(n.trash_root_node_id) }
    assert_empty stray.map { |n| n.attributes.slice("name", "deleted", "trash_root_node_id") },
                 "#{context}: a row names an entry whose root is not in the trash, so the folder's next " \
                 "delete adopts it"
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
  def test_trash_entry_contract_restoring_a_folder_never_revives_an_earlier_entry_inside_it
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
  # entry. Its bytes are still in its OWN entry. So the folder's restore, which cannot bring it back,
  # RE-ROOTS it: each row left behind becomes the root of its own entry, or joins its nearest
  # left-behind ancestor's (TrashMembership.release!) — and is then restored on its own, from there.
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
    assert_equal [ file_id, sub_id, sub_id ],
                 [ file_id, sub_id, inner_id ].map { |id| @user.nodes.find_by!(node_id: id).trash_root_node_id },
                 "what the folder's restore left behind is re-rooted, each row under its nearest left-behind ancestor"
    assert_trash_spellings_agree "after a folder restore that left misfiled rows behind"

    adapter.undelete(@user, node_id: file_id)
    assert_equal "old", adapter.read(@user, node_id: file_id)
    adapter.undelete(@user, node_id: sub_id)
    assert_equal "g", adapter.read(@user, node_id: inner_id), "the folder's own contents stayed behind"
    assert_trash_spellings_agree "after restoring rows the backfill misfiled"
  end

  # DELETE, RESTORE, RE-DELETE, RESTORE: A ROW THE FIRST RESTORE LEFT BEHIND IS NOT ADOPTED BY THE
  # SECOND DELETE. The entry's id is the folder's own node_id, and deleting the same folder again
  # writes that same id on what moves, so a row left behind still naming it reads as a member of the
  # new entry. Here the backfill filed a separately deleted `x.stl` under its folder; the folder comes
  # back without it, a corrected `x.stl` is uploaded, and the folder goes and comes back again.
  # Adopted, the old row was revived over the corrected bytes with its old content_hash, or collided
  # with the corrected row in the partial unique index and 500ed mid-restore — audit defect (b).
  def test_trash_entry_contract_a_row_a_restore_left_behind_is_not_adopted_by_the_next_delete
    dir_id = make_dir(name: "F")
    old_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl", io: StringIO.new("old")).node_id
    adapter.delete(@user, node_id: old_id)
    adapter.delete(@user, node_id: dir_id)
    @user.nodes.where(node_id: old_id).update_all(trash_root_node_id: dir_id) # the backfill's filing
    adapter.undelete(@user, node_id: dir_id)
    new_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl", io: StringIO.new("corrected")).node_id

    adapter.delete(@user, node_id: dir_id)
    assert_nothing_raised { adapter.undelete(@user, node_id: dir_id) }

    assert_equal "corrected", adapter.read(@user, node_id: new_id)
    assert_equal "F/x.stl", @user.nodes.find_by!(node_id: new_id).storage_path
    assert @user.nodes.find_by!(node_id: old_id).deleted?, "the row left behind came back over the corrected file"
    assert_trash_spellings_agree "after a second restore of the same folder"
  end

  # THE SAME ADOPTION WITHOUT THE BACKFILL: a member whose bytes are gone from the entry when its folder
  # comes back is left behind too, and its own restore must say so rather than name the folder.
  def test_trash_entry_contract_a_member_whose_bytes_were_lost_is_not_adopted_by_the_next_delete
    dir_id = make_dir(name: "F")
    lost_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl", io: StringIO.new("lost")).node_id
    adapter.delete(@user, node_id: dir_id)
    lose_from_trash_entry!(dir_id, "F/x.stl")
    adapter.undelete(@user, node_id: dir_id)
    assert @user.nodes.find_by!(node_id: lost_id).deleted?, "a member came back without its bytes"
    new_id = adapter.write(@user, parent_node_id: dir_id, name: "x.stl", io: StringIO.new("new")).node_id

    adapter.delete(@user, node_id: dir_id)
    assert_nothing_raised { adapter.undelete(@user, node_id: dir_id) }

    assert_equal "new", adapter.read(@user, node_id: new_id)
    assert @user.nodes.find_by!(node_id: lost_id).deleted?, "the member left behind came back over the new file"
    assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: lost_id) }
    assert_trash_spellings_agree "after a second restore of the same folder"
  end

  # A ROOT WHOSE ROW IS GONE NO LONGER HOLDS ITS MEMBERS. Every restore re-roots what it leaves behind,
  # so a member names a root that is out of the trash only when that root's row no longer exists — bad
  # data, not a door. With no folder left to restore, "restore the folder first" is a dead end the
  # maker can never act on; the member answers on its own instead, and with no entry of its own, says
  # it is gone.
  def test_trash_entry_contract_a_member_whose_root_row_is_gone_answers_on_its_own
    dir_id = make_dir(name: "F")
    member_id = adapter.write(@user, parent_node_id: dir_id, name: "m.stl", io: StringIO.new("m")).node_id
    adapter.delete(@user, node_id: dir_id)
    @user.nodes.find_by!(node_id: dir_id).destroy!

    assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: member_id) }
  end

  # A RESTORE THAT FAILS PARTWAY STILL RE-ROOTS WHAT IT LEFT BEHIND, once the folder itself is back. The
  # one failure a revive accepts is a live row already holding a member's path (a scan racing the
  # restore, the residual both adapters record): that member's revive raises RecordNotUnique, and the
  # members it had not reached named a folder that is live again — the state its next delete adopts.
  # Simulated with a live catalog row squatting on one member's path.
  def test_trash_entry_contract_a_restore_that_fails_partway_still_re_roots_what_it_left_behind
    dir_id = make_dir(name: "F")
    ids = %w[a.stl b.stl].map do |name|
      adapter.write(@user, parent_node_id: dir_id, name:, io: StringIO.new(name)).node_id
    end
    adapter.delete(@user, node_id: dir_id)
    @user.nodes.create!(node_id: "squatter-#{SecureRandom.hex(4)}", name: "b.stl", kind: "file",
                        storage_path: "F/b.stl", deleted: false, mtime: 1)

    assert_raises(ActiveRecord::RecordNotUnique) { adapter.undelete(@user, node_id: dir_id) }

    assert_not @user.nodes.find_by!(node_id: dir_id).deleted?, "precondition: the folder itself came back"
    assert @user.nodes.find_by!(node_id: ids.last).deleted?, "precondition: the squatted member did not"
    assert_trash_spellings_agree "after a folder restore that raised partway"
  end
end
