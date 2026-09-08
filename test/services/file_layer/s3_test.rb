require "test_helper"
require_relative "adapter_contract"
require_relative "adapter_write_contract"
require_relative "adapter_mutation_contract"
require_relative "../../support/fake_s3"

module FileLayer
  # The S3 adapter over the user's own bucket: no chunks, no versions, no history -- the
  # object IS the truth, and content_token is its identity (FileLayer::S3::ObjectIdentity).
  #
  # Runs the SAME read contract as Chunk and Share. That is the anti-divergence mechanism,
  # and it is the reason this adapter needs so few tests of its own.
  class S3Test < ActiveSupport::TestCase
    include FileLayerAdapterContract
    # THE POINT OF THE MODULE. It was written in 2b as a SECOND contract, separate from the read
    # one, with exactly this adapter named as the reason: "Share includes it now; S3 in Phase 3 —
    # that is the point." It is satisfied UNMODIFIED here; if it ever needs editing to accommodate
    # a backend, that is a finding, not a licence.
    #
    # It earned its keep before this line existed: during 2b it caught that Phase 3's plan let
    # S3#write put_object straight over the user's file while Share, three feet away, refuses.
    include FileLayerWritableContract
    include FileLayerMutationContract

    # The hooks FileLayerMutationContract requires. S3's real door for creating a file is the
    # port's own write, which is exactly what the four extracted tests used inline before they
    # became backend-agnostic.
    def make_file(name:, bytes:)
      adapter.write(@user, parent_node_id: nil, name:, io: StringIO.new(bytes)).node_id
    end

    def make_dir(name:) = adapter.mkdir(@user, parent_node_id: nil, name:).node_id

    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3-#{SecureRandom.hex(4)}@example.com")
    end

    def adapter
      @adapter ||= FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                     secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end

    # --- presigned_origin: what the CSP's connect-src names -----------------------------------

    # ASSERTED AGAINST THE WIRE, not the config: the origin must be the one a real presigned
    # download carries, which holds only while #build_client forces path-style addressing — a
    # virtual-hosted signer would put the bucket in the host, and reading the endpoint alone would
    # then name an origin no redirect ever goes to.
    test "presigned_origin is the origin every presigned download carries" do
      id = create_file!(name: "o.stl", bytes: "origin")
      url = URI(adapter.download(@user, node_id: id, disposition: :attachment).url)

      assert_equal "#{url.scheme}://#{url.host}", adapter.presigned_origin
      # The SDK resolves us-east-1 to the LEGACY GLOBAL host, not `s3.us-east-1.amazonaws.com` —
      # which is the whole case for reading the origin off the client instead of composing it from
      # the region: the composed guess was this test's first draft, and it was wrong.
      assert_equal "https://s3.amazonaws.com", adapter.presigned_origin
    end

    # The self-host case: a SeaweedFS/MinIO endpoint on a non-default port, through a REAL SDK
    # client rather than the fake — construction is lazy and presigning is local HMAC, so nothing
    # is contacted. The port must survive: "http://192.168.1.2" is a different origin from ":8333",
    # and a policy naming the former would refuse every fetch to the latter.
    test "presigned_origin keeps a custom endpoint's scheme, host and port" do
      custom = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                 secret_access_key: "sk", endpoint: "http://192.168.1.2:8333")

      assert_equal "http://192.168.1.2:8333", custom.presigned_origin
    end

    # Seed the object as another tool would have, then index it with THE REAL OBSERVER. That is
    # the backend's actual premise: the bucket already has the user's files in it, and a scan is
    # what puts them in `nodes`.
    #
    # THE STAND-IN IS GONE. Tasks 4-6 built this by hand (Library::S3Observer did not exist yet)
    # and argued it could not drift because it routed the identity through the same
    # ObjectIdentity.for the observer would. Task 7 replaced it with the observer and ran both:
    # 79 of 80 tests agreed. The 80th did not, and the FIXTURE was the one that was wrong -- see
    # the sha256 half of the copy-precondition test below. That is the entire argument for doing
    # this rather than trusting the reasoning: a hand-built fixture agreeing with production is a
    # claim, and this makes it a fact.
    #
    # max_delete_pct: 100 because a fixture is not about the mass-deletion guard -- the Reconciler
    # documents that keyword for exactly this. Several tests here seed a second file into a
    # one-file bucket, which is a 0% deletion; but some delete a node and then create another, and
    # a helper that could refuse a scan depending on the test's history is a helper that fails
    # somewhere unrelated to what it is testing.
    def create_file!(name:, bytes:)
      @fake.seed!("#{PREFIX}/#{name}", bytes, last_modified: Time.now)
      scan!(max_delete_pct: 100)
      @user.nodes.find_by!(storage_path: name).node_id
    end

    # A SCAN. The real one -- Library::S3Observer over this fake's client, the same call
    # Library::ScanJob makes in production.
    #
    # Task 6's tests need a scan (the whole landmine is about what the next scan DECIDES about a
    # tombstone) and drove Library::Reconciler directly because the observer did not exist. It does
    # now, so they drive the observer, and the `.trash` skip / prefix stripping / identity that
    # those tests used to mirror by hand are now the production code paths rather than a faithful
    # copy of them.
    #
    # The observer's own suite (test/services/library/s3_observer_test.rb) owns proving it observes
    # correctly; this file owns the adapter's behavior across a scan.
    def scan!(max_delete_pct: nil)
      Library::S3Observer.call(@user, adapter:, max_delete_pct:)
    end

    # The write contract's `change_store_content!` hook: another tool putting different bytes at
    # this key -- rclone, the S3 console, the maker's own desktop client. Straight to the fake's
    # object, with no scan behind it, so the catalog still names the old identity. `seed!` re-derives
    # the ETag from the new body, which is what the store itself would do.
    def change_store_content!(node_id, bytes)
      @fake.seed!("#{PREFIX}/#{@user.nodes.find_by!(node_id:).storage_path}", bytes,
                  last_modified: Time.now)
    end

    # The contract's `vanish_store_content!` hook: the object deleted by another tool, no scan
    # behind it — through the fake's own stubbed client, the way that tool would.
    def vanish_store_content!(node_id)
      @fake.client.delete_object(bucket: adapter.instance_variable_get(:@bucket),
                                 key: "#{PREFIX}/#{@user.nodes.find_by!(node_id:).storage_path}")
    end

    # An attachment is WHY node_id stability is the port's promise: it is a bare string column
    # with no foreign key (maker_file_attachments.node_id), so a node_id that changes does not
    # error — it silently resolves to nothing. That is what "orphaned" means below, concretely.
    def attach!(node_id)
      project = Maker::Project.create!(user: @user, name: "bracket-project-#{SecureRandom.hex(4)}")
      Maker::FileAttachment.create!(user: @user, attachable: project, node_id:, role: "model")
    end

    def orphaned?(attachment)
      @user.nodes.present.find_by(node_id: attachment.node_id).nil?
    end

    # S3's "delete" as a USER would do it: the object leaves the bucket (deleted in the console,
    # by another tool), and the next scan tombstones the node. NOT the port's delete -- that is
    # the adapter under test, and it does not exist until Task 6.
    def delete_file!(node_id)
      node = @user.nodes.find_by!(node_id:)
      @fake.objects.delete("#{PREFIX}/#{node.storage_path}")
      node.update!(deleted: true)
    end

    # The web UI's delete, which here is the port's: copy to the trash prefix, delete the source,
    # then the tombstone. NOT delete_file! above — that is the user removing the object with
    # rclone or the S3 console, which produces a SCAN tombstone whose bytes are gone for good. The
    # two hooks are the two tombstone kinds, and the difference is what #trashed filters on.
    def trash_file!(node_id) = adapter.delete(@user, node_id:)

    # S3's transient failure: the bytes are there, we cannot read them right now -- an expired
    # credential, a 5xx, a network blip. Must NOT read as "the user deleted it". Faults the
    # TRANSPORT (the client), never the adapter's own classification -- stubbing that is what the
    # contract's test exists to catch.
    #
    # get_object only: the WRITE contract (Task 5) has its own hook, with_transient_write_failure,
    # for the reason share_test gives -- the read contract's test ends by re-reading the file to
    # prove the fault was transient, and a hook that broke both transports would stop that
    # assertion isolating the read path. (The plan faulted put_object here too, from before 2b's
    # note added the second hook.)
    def with_transient_backend_failure
      @fake.fault!(:get_object, "InternalError")
      yield
    ensure
      @fake.clear_faults!
    end

    # S3's transient WRITE failure: a 5xx, a throttle, an expired credential on the PUT. Separate
    # from with_transient_backend_failure by the write contract's own instruction, and the reason
    # is not symmetry: the READ hook's contract test ends by re-reading the file to prove the fault
    # was transient, so one hook faulting both transports would stop that assertion isolating the
    # read path. Faults the TRANSPORT (put_object), never the adapter's own classification.
    def with_transient_write_failure
      @fake.fault!(:put_object, "InternalError")
      yield
    ensure
      @fake.clear_faults!
    end

    # Contract hook, and a bare yield is the honest implementation: a bucket's presigned URL
    # ALWAYS points off-box. There is no other configuration of this backend to reach for.
    def with_off_box_presigning = yield

    # --- download: the presigned redirect (Task 2) ----------------------------------------

    # THE ASSERTIONS ARE ON THE URL, WHICH IS THE WIRE. That is not incidental here: a presigned
    # URL is not a round-trip through FakeS3 — it is the exact string the browser will send to a
    # real store, minted by the real SDK's real SigV4 signer. Phase 3's sharpest bug (CGI.escape)
    # was hidden for 79/80 tests by a fake that shared the adapter's misunderstanding, and the
    # lesson was: assert the thing the store actually sees.
    #
    # The call count is the §15 assertion, and it is the one that would catch a "simplification"
    # into get_object + send_data: presigning must not touch the bytes AT ALL.
    test "download presigns a GET — the bytes never touch Rails" do
      id = create_file!(name: "p.stl", bytes: "presigned")
      d = adapter.download(@user, node_id: id, disposition: "attachment")

      assert_kind_of FileLayer::Delivery::Redirect, d
      assert_includes d.url, "X-Amz-Signature", "it must be a signed URL, not a bare object URL"
      assert_includes d.url, "#{PREFIX}/p.stl"
      assert_equal 0, @fake.calls[:get_object], "§15: the bytes must never pass through Rails"
    end

    # LANDMINE 3, and this test is the reason `download` takes `disposition:` at all.
    #
    # A redirect bypasses EVERY header the controller sets — including the attachment disposition
    # #blob forces for SVG and HTML (which a browser would otherwise execute) and the ?download=1
    # control. Without the override, the same UI button behaves differently depending on the
    # deployment's backend, which is the divergence these contracts exist to prevent.
    #
    # THE SIGNATURE CHECK IS THE POINT, and `assert_includes url, "response-content-disposition"`
    # (the plan's version) is what it replaces. That assertion cannot tell a SIGNED override from
    # a string concatenated onto a finished URL — and a concatenated one is worse than none: a
    # real store rejects the whole request as a signature mismatch, so every download 403s. Here
    # the same URL minted with a different disposition MUST carry a different signature, which is
    # only true if the parameter is an input to SigV4's canonical query string. That is what
    # "tamper-proof" means, asserted rather than asserted-about.
    test "the disposition policy is SIGNED INTO the presigned URL, not silently dropped" do
      id = create_file!(name: "evil.svg", bytes: "<svg onload=alert(1)>")

      attach = adapter.download(@user, node_id: id, disposition: "attachment",
                                content_type: "application/octet-stream")
      q = CGI.parse(URI(attach.url).query)

      # The exact values, not merely the keys: the controller's policy has to arrive intact.
      # The RFC 5987 `filename*` half is not incidental — it is what #blob already emits (both go
      # through ActionDispatch::Http::ContentDisposition.format), so a name with a space or a
      # unicode character survives the redirect exactly as it survives the stream. Spelled out
      # literally rather than built by calling the same formatter, which would assert the code
      # against itself.
      assert_equal [ %q(attachment; filename="evil.svg"; filename*=UTF-8''evil.svg) ],
                   q["response-content-disposition"],
                   "the browser must be told to download it, with the real filename"
      assert_equal [ "application/octet-stream" ], q["response-content-type"],
                   "and never image/svg+xml, which the store would otherwise serve executable"

      inline = adapter.download(@user, node_id: id, disposition: "inline",
                                content_type: "application/octet-stream")
      assert_not_equal q["X-Amz-Signature"], CGI.parse(URI(inline.url).query)["X-Amz-Signature"],
                       "changing the disposition MUST change the signature — otherwise the " \
                       "override is a query param bolted onto a URL signed without it, which a " \
                       "real store answers with a signature mismatch, not the file"
    end

    # The policy is the CALLER'S, not the adapter's: the controller owns which disposition
    # (SAFE_INLINE_TYPES is a web concern, not a storage one) and the adapter owns the mechanism.
    # An adapter that hardcoded "attachment" would pass the test above and break inline preview.
    test "an inline disposition is honored too — the policy is the caller's, not the adapter's" do
      id = create_file!(name: "ok.png", bytes: "\x89PNG".b)
      d = adapter.download(@user, node_id: id, disposition: "inline", content_type: "image/png")
      q = CGI.parse(URI(d.url).query)

      assert_equal [ %q(inline; filename="ok.png"; filename*=UTF-8''ok.png) ],
                   q["response-content-disposition"]
      assert_equal [ "image/png" ], q["response-content-type"]
    end

    # content_type is OPTIONAL — the controller may have no opinion, and then the object's own
    # Content-Type is the right answer. Verified against the real SDK: a nil param is omitted
    # from the URL entirely rather than signed as an empty string (which would make the store
    # serve the file as "").
    test "download without a content_type leaves the object's own type alone" do
      id = create_file!(name: "q.stl", bytes: "b")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      q = CGI.parse(URI(d.url).query)

      assert_equal [ %q(attachment; filename="q.stl"; filename*=UTF-8''q.stl) ],
                   q["response-content-disposition"]
      assert_empty q["response-content-type"], "an absent override must not be signed as empty"
    end

    # The escape guard, on the download path. update_column bypasses validation — a poisoned row
    # of the shape a future bug could produce — and a presigned URL for an escaped key is a signed
    # grant to read outside the library prefix, which is strictly worse than a failed read.
    test "download refuses a storage_path that escapes the prefix" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../etc/passwd")
      err = assert_raises(FileLayer::NotFound) do
        adapter.download(@user, node_id: id, disposition: "attachment")
      end
      assert_match(/escapes the library prefix/, err.message)
    end

    test "download raises NotFound for a deleted node" do
      id = create_file!(name: "gone.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) do
        adapter.download(@user, node_id: id, disposition: "attachment")
      end
    end

    # --- S3-specific --------------------------------------------------------------

    test "write puts the object under the prefix and indexes it" do
      info = adapter.write(@user, parent_node_id: nil, name: "new.stl", io: StringIO.new("fresh"))

      assert_equal "fresh", @fake.objects["#{PREFIX}/new.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "new.stl", node.storage_path
      assert_equal "md5:#{Digest::MD5.hexdigest('fresh')}", node.content_hash
      assert_equal 5, node.size
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"
    end

    # mtime comes from the STORE, never from Time.now — the next scan compares the node against
    # what the store reports, so a clock we guessed makes every written file look changed on the
    # very next pass. Pinned by moving the store's clock somewhere Time.now could not be: a real
    # last_modified is what write must record, whatever our own clock says.
    test "write records the STORE's mtime, not our clock" do
      stored = Time.at(1_600_000_000)
      @fake.client.stub_responses(:head_object, ->(ctx) {
        @fake.objects.key?(ctx.params[:key]) ? { content_length: 5, last_modified: stored } : "NotFound"
      })
      info = adapter.write(@user, parent_node_id: nil, name: "clock.stl", io: StringIO.new("fresh"))

      assert_equal 1_600_000_000_000_000_000, @user.nodes.find_by!(node_id: info.node_id).mtime,
                   "the mtime must be the store's last_modified in nanos, not Time.now"
    end

    # LANDMINE 2, on the write side. put_object's response ETag is quoted exactly like the
    # listing's. If write stored the quoted form and the observer stored the stripped one, one
    # object would have two identities: every written file reads as changed on the very next scan,
    # and move-pairing never pairs. One normalizer, or the phase's promise inverts.
    #
    # PLAN DRIFT, deliberate and reported (the same drift Task 4's create_file! already took, and
    # for the same reason): the plan compares write's identity against Library::S3Observer's, which
    # is Task 7's and does not exist. ObjectIdentity.for is the call the observer WILL make — it is
    # named as the one normalizer — so comparing against it is the same assertion a task earlier,
    # and it cannot quietly disagree with the thing it stands in for. Task 7 owns proving the
    # observer routes through it too.
    test "write and the observer agree on the identity, byte for byte" do
      info = adapter.write(@user, parent_node_id: nil, name: "agree.stl", io: StringIO.new("x"))
      written = @user.nodes.find_by!(node_id: info.node_id).content_hash
      observed = FileLayer::S3::ObjectIdentity.for(etag: @fake.objects["#{PREFIX}/agree.stl"].etag)

      assert_equal observed, written, "write and the scan must produce the SAME identity"
      assert_not_includes written, '"', "the quotes S3 wraps ETags in must never reach the DB"
    end

    test "write into a subdirectory addressed by parent_node_id" do
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl",
                           io: StringIO.new("g"))

      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
    end

    # Assert the MESSAGE, not just the class. Every fixture below contains a separator, so it is
    # the LEAF check that refuses them — the escape guard is never reached. 2b shipped exactly this
    # test asserting NotFound by class alone and it pinned nothing: NotFound was reachable two ways
    # and the guard it named was dead code as far as the test was concerned.
    #
    # The call counts are what stop this being decoration in the OTHER direction: a refused write
    # and a write to a nonexistent-but-composed key both end in an exception, so "it raised" proves
    # nothing about WHERE. Zero requests = refused before anything left the process.
    test "write rejects a name that is not a leaf" do
      [ "cad/gear.stl", "../outside.stl", "/etc/passwd", "a/../../outside.stl", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal 0, @fake.calls[:put_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.calls[:head_object]
      assert_empty @fake.objects
    end

    # THE escape guard, reached the only way it can be: through the PARENT. A separator-free leaf
    # cannot escape once `.`/`..` are refused above, so `name` never gets here.
    #
    # THE WRITE PATH IS NOT THE READ PATH HERE, and the difference was established by mutation
    # rather than assumed. On the READ side, deleting the guard leaves "/etc/passwd" merely
    # composing a key that does not exist, so the read raises NotFound ANYWAY and assert_raises
    # passes while the request goes out over the wire — which is why those tests carry a call
    # count as their entire load. A WRITE to a bogus key SUCCEEDS: with the guard deleted this
    # composes "library/../escaped/pwned.stl", the store accepts it, nothing raises, and the
    # assert_raises above is what fails (verified: it does).
    #
    # The call counts stay regardless, as the stronger claim: refused BEFORE anything left the
    # process. They are what would catch the clobber-check HEAD being ordered ahead of the guard —
    # a request against an escaped key, sent, and no assertion above would notice.
    test "write through a parent whose storage_path escapes the prefix is refused" do
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 deleted: false, storage_path: "../escaped", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: evil.node_id, name: "pwned.stl", io: StringIO.new("x"))
      end
      assert_match(/escapes/, err.message)
      assert_equal 0, @fake.calls[:put_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.calls[:head_object]
      assert_equal 0, @fake.objects.keys.count { |k| !k.start_with?("#{PREFIX}/") },
                   "nothing may be written outside the prefix"
    end

    # NOT IN THE PLAN — added because 2b's structural finding transfers, with one half amputated.
    # S3 has no directories, so a `.trash` object cannot collide with the `.trash/<id>/<name>` keys
    # Task 6's delete writes (Share's EEXIST half does not apply). But Task 7's observer skips the
    # `.trash` prefix, so this upload would leave a live node at a key the scan NEVER observes ->
    # unpairable ghost -> tombstone -> the mass-deletion guard refuses that scan and every scan
    # after it, permanently. One ordinary-looking upload. The lesson 2b paid for four times:
    # assume every path that writes is exposed until you have checked it.
    test "write refuses a reserved path the scan does not index" do
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: Library::Scanner::TRASH_PREFIX,
                      io: StringIO.new("x"))
      end
      assert_match(/reserved/, err.message)
      assert_equal 0, @fake.calls[:put_object]

      # ...and a NESTED .trash is the user's own folder: observed, indexed, none of our business.
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      assert_nothing_raised do
        adapter.write(@user, parent_node_id: parent.node_id,
                      name: Library::Scanner::TRASH_PREFIX, io: StringIO.new("mine"))
      end
    end

    # The clobber guard's SECOND half, and the one the fail-safe direction turns on: a HEAD that
    # fails for a reason other than absence must never read as "vacant" and put over the user's
    # file. AccessDenied is the credentials-outage shape that caused the original incident.
    test "a clobber check that fails transiently refuses the write rather than assuming vacant" do
      @fake.fault!(:head_object, "AccessDenied")
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "risky.stl", io: StringIO.new("x"))
      end
      assert_equal 0, @fake.calls[:put_object], "a HEAD we could not trust must not be read as vacant"
    end

    test "write refuses an object larger than MAX_BYTES" do
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "big.stl", io: StringIO.new("hello"))
      end
      assert_match(/exceeds/, err.message)
      assert_equal 0, @fake.calls[:put_object]
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end

    # --- the two-phase presigned flow refuses (Task 8) -------------------------------------
    #
    # THE OTHER HALF OF Chunk#write's OWN REFUSAL, MIRRORED — see FileLayer::ShareTest's identical
    # pair for the full argument. FilesController never reaches this in the real app
    # (begin_upload/finalize_upload gate on `syncable`, which this backend answers false, so the
    # capability gate itself is what a caller actually sees); these exist for a caller that reaches
    # the adapter directly, so it gets a named refusal instead of a NoMethodError.
    test "begin_upload refuses, naming #write as the real door" do
      err = assert_raises(NotImplementedError) do
        adapter.begin_upload(@user, name: "x.stl", size: 1,
                             manifest: [ { "hash" => "a" * 64, "offset" => 0, "length" => 1 } ])
      end
      assert_match(/write/, err.message)
      refute_kind_of StandardError, err,
                     "NotImplementedError must stay a ScriptError -- a rescue-based gate would " \
                     "silently not catch it"
      assert_equal 0, @fake.calls[:put_object], "a refused begin must not touch the bucket"
    end

    test "finalize_upload refuses, naming #write as the real door" do
      err = assert_raises(NotImplementedError) do
        adapter.finalize_upload(@user, commit_id: SecureRandom.uuid)
      end
      assert_match(/write/, err.message)
    end

    # ------------------------------------------------------------------------------------------
    # CROSS-KIND OCCUPANCY — a directory occupying a file's name, and the reverse.
    #
    # The write contract pins the CLASS for all four verbs on both writable backends. These pin
    # the half only this backend can show: WHICH namespace answered, and what was left in the
    # bucket when the answer was "no".
    #
    # THE DIRECTORY IN MOST OF THESE HAS NO MARKER OBJECT, deliberately. A dir this adapter's own
    # mkdir created carries `<key>/`, which the bucket half of destination_vacant! sees unaided; a
    # dir the SCAN synthesized from a bare prefix (Library::S3Observer#dir_chain — an ordinary
    # bucket the user already had, which is this backend's whole premise) carries nothing at all,
    # and the CATALOG is the only namespace that knows it is there. Build these with mkdir instead
    # and the node half could be deleted with every one of them still green.
    def scan_derived_dir!(rel)
      @fake.seed!("#{PREFIX}/#{rel}/keeper.stl", "k", last_modified: Time.now)
      scan!(max_delete_pct: 100)
      @user.nodes.present.find_by!(storage_path: rel, kind: "dir")
    end

    test "write over a scan-derived directory's name refuses rather than 500ing, and writes nothing" do
      scan_derived_dir!("cad")

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.write(@user, parent_node_id: nil, name: "cad", io: StringIO.new("file over a folder"))
      end
      assert_match(/already exists/, err.message)
      assert_nil @fake.objects["#{PREFIX}/cad"],
                 "an exact-key HEAD reads `cad` as vacant, so the object landed and only the row raised"
      assert_equal "k", @fake.objects["#{PREFIX}/cad/keeper.stl"].body, "the folder's contents are untouched"
    end

    test "mkdir over a file's name refuses rather than 500ing, and leaves no stray marker" do
      create_file!(name: "report", bytes: "r") # no extension — an ordinary object and a plausible folder name

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.mkdir(@user, parent_node_id: nil, name: "report")
      end
      assert_match(/already exists/, err.message)
      assert_nil @fake.objects["#{PREFIX}/report/"], "no dir marker may be minted beside the file"
      assert_equal "r", @fake.objects["#{PREFIX}/report"].body
    end

    test "a move onto a scan-derived directory's name is refused, not answered with a 500" do
      scan_derived_dir!("cad")
      id = create_file!(name: "a.stl", bytes: "solid")

      assert_raises(FileLayer::UnsupportedOperation) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "cad")
      end
    end

    # THE SECOND HALF OF THE SAME REFUSAL, IN ITS OWN TEST AND SWALLOWING THE CLASS ON PURPOSE.
    # Asserting both in one method proves only the first: assert_raises fails and aborts before the
    # bucket is ever looked at, so a "refusal" that had already copied and DELETED THE SOURCE would
    # read exactly like a clean one (§15 — prove each assertion carries weight). This is the verb
    # where that matters: move is copy-then-delete here, so everything the row write raises over
    # has already happened to the bytes. §14a's copy -> delete -> orphan landmine.
    test "a refused move onto a directory's name leaves the source key where the row says it is" do
      scan_derived_dir!("cad")
      id = create_file!(name: "a.stl", bytes: "solid")

      begin
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "cad")
      rescue StandardError # deliberate: the CLASS belongs to the test above, the BYTES to this one
        nil
      end

      assert_equal "solid", @fake.objects["#{PREFIX}/a.stl"]&.body,
                   "the source object must still be there — a refusal that got as far as the copy deleted it"
      assert_equal "a.stl", @user.nodes.find_by!(node_id: id).storage_path,
                   "and the row must still name the key the bytes are actually at"
      assert_nil @fake.objects["#{PREFIX}/cad"], "nothing may have landed at the folder's own name"
    end

    test "undelete into a name a folder has taken refuses, keeping the trashed bytes in the trash" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      # Someone made a FOLDER of that name on the other side and the scan indexed it — a bare
      # prefix, so there is no marker object for a HEAD to find.
      @fake.seed!("#{PREFIX}/bracket.stl/inner.stl", "i", last_modified: Time.now)
      scan!(max_delete_pct: 100)

      assert_raises(FileLayer::UnsupportedOperation) { adapter.undelete(@user, node_id: id) }
      assert_equal "solid", @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"]&.body,
                   "the trashed bytes stay in the trash — a refusal after the copy strands them at both keys"
      assert_nil @fake.objects["#{PREFIX}/bracket.stl"], "and nothing may have landed at the taken name"
      assert @user.nodes.find_by!(node_id: id).deleted, "the node stays trashed, not half-restored"
    end

    # `replace: true` IS AN APPROVED OVERWRITE OF A FILE, AND A DIRECTORY IS NOT ONE. The opt-in
    # waives the clobber refusal for the file a user was shown and confirmed; replacing a folder
    # with a file is not that, and `existing` is looked up `kind: "file"` — so before this it fell
    # through to create! and the kind-agnostic unique index, i.e. a 500 with the object written.
    test "replace: true replaces the FILE at a name and never the DIRECTORY at one" do
      scan_derived_dir!("cad")

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.write(@user, parent_node_id: nil, name: "cad", io: StringIO.new("x"), replace: true)
      end
      assert_match(/already exists/, err.message)
      assert_nil @fake.objects["#{PREFIX}/cad"]
      assert_equal 1, @user.nodes.present.where(storage_path: "cad").count
      assert_equal "dir", @user.nodes.present.find_by!(storage_path: "cad").kind, "still the folder"
    end

    # A SCAN TOMBSTONE IS NOT AN OCCUPANT, and this is the whole reason destination_vacant!'s node
    # lookup is `.present` and not a bare `user.nodes`. §14a's two tombstone kinds: a SCAN tombstone
    # KEEPS its storage_path — that is what lets a file that comes back revive with the same
    # node_id, and every attachment with it — while the unique index ignores it (WHERE deleted =
    # false). Ask unscoped and every re-upload over a file the scan tombstoned is refused with
    # "already exists" about a file that is not there: the ordinary repair after someone removes
    # something on the NAS side and puts it back through the app, broken on every write in the
    # library. It is the failure this fix is one line away from at all times.
    test "a path a SCAN tombstoned is vacant again — both write and mkdir may take it" do
      gone = create_file!(name: "gone.stl", bytes: "b")
      folder = create_file!(name: "folder-to-be", bytes: "b")
      delete_file!(gone)   # the object left the bucket; the scan tombstoned the node
      delete_file!(folder)
      assert_equal "gone.stl", @user.nodes.find_by!(node_id: gone).storage_path,
                   "the precondition — a scan tombstone keeps its path, unlike a trash tombstone"

      adapter.write(@user, parent_node_id: nil, name: "gone.stl", io: StringIO.new("back"))
      assert_equal "back", @fake.objects["#{PREFIX}/gone.stl"].body

      info = adapter.mkdir(@user, parent_node_id: nil, name: "folder-to-be")
      assert_equal "dir", @user.nodes.find_by!(node_id: info.node_id).kind
    end

    # THE BUCKET HALF, WHICH THE CATALOG CANNOT ANSWER: a dir marker the S3 console minted, in a
    # bucket nothing has scanned yet. No node exists, so the node half reads vacant; writing a file
    # at that exact key would leave `cad` and `cad/` side by side, which the next scan sees as a
    # file observation AND a dir observation for one rel_path.
    test "an unindexed dir marker occupies a file's name too" do
      @fake.seed!("#{PREFIX}/cad/", "", last_modified: Time.now)

      assert_raises(FileLayer::UnsupportedOperation) do
        adapter.write(@user, parent_node_id: nil, name: "cad", io: StringIO.new("x"))
      end
      assert_nil @fake.objects["#{PREFIX}/cad"]
    end

    # ...AND THE SAME MARKER IS NOT A COLLISION FOR MKDIR, which is what `kind:` is for. Same kind,
    # so this is the idempotent case one layer down from mkdir's own short-circuit (which asks the
    # catalog, and the catalog has never heard of this folder). Refusing here would make creating a
    # folder over an existing, unscanned bucket prefix impossible — the on-ramp this backend is for.
    test "mkdir over an unindexed dir marker creates the folder rather than refusing itself" do
      @fake.seed!("#{PREFIX}/cad/", "", last_modified: Time.now)

      info = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_equal "dir", @user.nodes.find_by!(node_id: info.node_id).kind
      assert_equal "cad", @user.nodes.find_by!(node_id: info.node_id).storage_path
    end

    test "stat reports the identity as the content token" do
      id = create_file!(name: "a.stl", bytes: "hello")
      info = adapter.stat(@user, node_id: id)
      assert_equal "md5:#{Digest::MD5.hexdigest('hello')}", info.content_token
      assert_equal 5, info.size
    end

    # The prefix is what lets a bucket hold a library WITHOUT owning the whole bucket.
    # A node's storage_path is relative to it; the key is prefix + path. Getting this
    # wrong reads and writes the wrong keyspace -- silently, on someone else's data.
    test "the prefix scopes the keyspace and never leaks into storage_path" do
      id = create_file!(name: "cad/gear.stl", bytes: "g")
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: id).storage_path
      assert @fake.objects.key?("#{PREFIX}/cad/gear.stl"), "the key is prefix + storage_path"
      assert_equal "g", adapter.read(@user, node_id: id)
    end

    # The mirror of Share#library_present?. An empty/wrong bucket makes EVERY object 404
    # at once -- indistinguishable from "this one was deleted" if we only look at the key.
    # NotFound is terminal (a preview burns to permanently failed), so when the whole
    # library appears to have evaporated, prefer the retryable answer. Same trade, same
    # reasoning, same direction as the share (spec 6).
    test "a missing object in an EMPTY library reads as transient, not as a deletion" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      @fake.objects.clear # the bucket is gone/wrong/empty, not "one file deleted"
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    test "a missing object in a POPULATED library is genuinely gone: terminal" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      create_file!(name: "other.stl", bytes: "still here")
      @fake.objects.delete("#{PREFIX}/vanish.stl")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # AccessDenied is the credentials-outage shape that caused the original production
    # incident. It is NOT NoSuchKey, so it must never read as absence.
    test "AccessDenied is transient, never NotFound" do
      id = create_file!(name: "denied.stl", bytes: "b")
      @fake.fault!(:get_object, "AccessDenied")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/AccessDenied/, err.message, "the operator needs to know WHICH failure")
    end

    test "a networking error is transient, never NotFound" do
      id = create_file!(name: "net.stl", bytes: "b")
      @fake.fault!(:get_object, Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new))
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The library_present? probe is itself I/O against the same store that just failed, so it
    # fails too during a real outage. It must not turn a transient answer terminal on its way
    # out -- and an `.any?` on a raised list is a NoMethodError, not a FetchError. Same as Share,
    # where an unlistable root answers "not present".
    test "a NoSuchKey whose library probe ALSO fails stays transient" do
      id = create_file!(name: "probe.stl", bytes: "b")
      @fake.fault!(:get_object, "NoSuchKey")
      @fake.fault!(:list_objects_v2, "InternalError")
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The escape guard, at the key layer. A storage_path is written by our own observer, but
    # the audit that preceded this work found exactly this bug class in client-supplied
    # values used as storage keys. update_column bypasses validation -- a poisoned row.
    test "a storage_path that escapes the prefix is refused" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_equal 0, @fake.calls[:get_object], "refused BEFORE any request left the process"
    end

    # A leading slash escapes by another road -- and a `..`-only check misses it entirely, which
    # is precisely why the guard names it separately.
    #
    # The calls assertion is the ENTIRE test, and it was decoration without it: with the guard
    # deleted, "/etc/passwd" merely composes a key that happens not to exist, so the read raises
    # NotFound anyway and the assert_raises above passes while the request goes out over the
    # wire. Proven by mutation, not by reading it. What is being pinned is that the path is
    # refused BEFORE we ask the store — the same reason the `..` test carries it.
    test "a storage_path with a leading slash is refused" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "/etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_equal 0, @fake.calls[:get_object], "refused BEFORE any request left the process"
    end

    # The guard REJECTS rather than normalizes, and this is the test that says so: an
    # expand_path-shaped fix would resolve this to the perfectly valid key "library/b.stl" and
    # serve b's bytes for a's node -- silently, which is the whole objection to normalizing.
    test "the escape guard refuses rather than normalizing away the .." do
      id = create_file!(name: "a.stl", bytes: "a bytes")
      create_file!(name: "b.stl", bytes: "b bytes")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "cad/../b.stl")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # The mirror image of the guard: ".." as a SUBSTRING is an ordinary filename, and a guard
    # that refused it would make a real object permanently unreadable -- NotFound is terminal.
    test "a filename merely CONTAINING dots is not an escape" do
      id = create_file!(name: "v1..2.stl", bytes: "dots")
      assert_equal "dots", adapter.read(@user, node_id: id)
    end

    # MAX_BYTES is port-wide (FileLayer::MAX_BYTES), and NotFound for "too big" matches Share --
    # a shared wart (the port has no terminal-but-present error), not a local choice. Shrinking
    # the constant rather than seeding 256MB, exactly as share_test's write-cap test does.
    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      id = create_file!(name: "big.stl", bytes: "hello")
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)
      err = assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_match(/exceeds/, err.message)
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end

    # The cap is enforced by a RANGED get, which is the only thing that actually bounds memory:
    # get_object buffers the whole body into a StringIO before it returns, so reading first and
    # checking content_length after would already be holding the 2GB it means to refuse.
    test "read bounds the transfer with a range rather than pulling the whole object" do
      id = create_file!(name: "ranged.stl", bytes: "hello")
      seen = nil
      @fake.client.stub_responses(:get_object, lambda { |ctx|
        seen = ctx.params[:range]
        { body: "hello", content_length: 5 }
      })
      adapter.read(@user, node_id: id)
      assert_equal "bytes=0-#{FileLayer::MAX_BYTES}", seen,
                   "the GET must cap at MAX_BYTES + 1 bytes, not fetch an unbounded object"
    end

    test "a user cannot read ANOTHER user's file by node_id" do
      id = create_file!(name: "mine.stl", bytes: "my bytes")
      other = User.create!(email: "s3-other-#{SecureRandom.hex(4)}@example.com")
      # The object is right there in the bucket and the key resolves — only the user-scoped node
      # lookup (CLAUDE.md §8's whole tenancy mechanism) stands between them and the file.
      assert_raises(FileLayer::NotFound) { adapter.read(other, node_id: id) }
      assert_raises(FileLayer::NotFound) { adapter.stat(other, node_id: id) }
    end

    # --- delete -> trash (task 6) ---------------------------------------------------------

    test "delete copies to the trash prefix keyed by node_id, then removes the original" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)

      assert_nil @fake.objects["#{PREFIX}/bracket.stl"], "the object leaves the indexed keyspace"
      assert_equal "solid", @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"].body
      assert @user.nodes.find_by!(node_id: id).deleted, "the node is tombstoned, never destroyed"
    end

    test "two deleted objects of the SAME NAME do not collide in the trash" do
      x = create_file!(name: "a/bracket.stl", bytes: "one")
      y = create_file!(name: "b/bracket.stl", bytes: "two")
      adapter.delete(@user, node_id: x)
      adapter.delete(@user, node_id: y)

      assert_equal "one", @fake.objects["#{PREFIX}/.trash/#{x}/bracket.stl"].body
      assert_equal "two", @fake.objects["#{PREFIX}/.trash/#{y}/bracket.stl"].body
    end

    # LANDMINE 3, half one. Spec §6 says "tombstone only after the copy confirms". A failed copy
    # that tombstoned would hide a file that is still there — and the next scan, finding no live
    # node and (2b Landmine 2) no tombstone at that path to revive, CREATES A NEW NODE with a new
    # node_id. Every attachment orphaned, silently.
    test "a failed COPY tombstones nothing and loses nothing" do
      id = create_file!(name: "x.stl", bytes: "b")
      @fake.fault!(:copy_object, "InternalError")

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }

      assert_not @user.nodes.find_by!(node_id: id).deleted, "a failed copy must not tombstone"
      assert_equal "b", @fake.objects["#{PREFIX}/x.stl"].body, "and must not lose the object"
      assert_equal 0, @fake.calls[:delete_object], "and must not proceed to the delete"
    end

    # LANDMINE 3, HALF TWO — the half spec §6 does NOT say, and the one that bites. This is the
    # task's headline test.
    #
    # Tombstoning after the copy but before the delete leaves the object live at its original key
    # with the node tombstoned and storage_path NULL. The next scan observes the key, no live node
    # claims it, revive-by-path CANNOT fire (2b nulls storage_path on a trash tombstone), so it
    # creates a NEW node. The attachment is orphaned by a scan that did nothing wrong.
    #
    # Tombstone LAST — after the DELETE confirms. Then a failed delete is merely a delete that did
    # not happen: the object is at its key, the node is live and matches by path, the next scan is
    # a no-op, and the user retries.
    #
    # Only visible by reading §6 together with a landmine settled in a DIFFERENT PHASE. That is
    # the cross-task shape that has produced every serious defect in this project.
    test "a failed DELETE after a successful copy tombstones nothing, and the attachment survives" do
      id = create_file!(name: "y.stl", bytes: "b")
      attachment = attach!(id)
      @fake.fault!(:delete_object, "InternalError")

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted, "the tombstone goes LAST — after the delete confirms"
      assert_equal "y.stl", node.storage_path, "and the path is not released either"
      assert_equal "b", @fake.objects["#{PREFIX}/y.stl"].body

      # ...and the state is CONSISTENT: the next scan is a no-op, not a resurrection.
      @fake.clear_faults!
      assert_nothing_raised { scan! }
      assert_equal id, @user.nodes.find_by!(storage_path: "y.stl").node_id

      # THE POINT OF THE ORDERING, stated in the only terms that matter. node_id is a bare string
      # column with no FK, so the wrong order does not error — the attachment just stops resolving.
      assert_not orphaned?(attachment),
                 "tombstoning before the delete confirms orphans every attachment on the node"
    end

    # 2b LANDMINE 1, inherited. delete tombstones in the same breath as the move, so
    # vanished_paths (which uses the `present` scope) never sees it. Without that, deleting most
    # of a library through the UI makes the very next scan refuse itself with UnsafeScan — the
    # guard firing on the app's own deliberate action.
    test "deleting most of the library does NOT trip the mass-deletion guard on the next scan" do
      ids = 5.times.map { |i| create_file!(name: "f#{i}.stl", bytes: "x#{i}") }
      ids.first(4).each { |id| adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { scan! }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    # 2b LANDMINE 2, inherited. A trash tombstone releases its path, so revive-by-path cannot hand
    # a NEW object the trashed node's identity — and with it every attachment and tag — while the
    # old bytes sit in .trash awaiting an undelete that would then collide.
    test "a NEW object at a trashed path is a NEW node, not the trashed one revived" do
      old = create_file!(name: "bracket.stl", bytes: "original")
      adapter.delete(@user, node_id: old)
      assert_nil @user.nodes.find_by!(node_id: old).storage_path,
                 "a trash tombstone must release its path"

      @fake.seed!("#{PREFIX}/bracket.stl", "a completely different file")
      scan!

      fresh = @user.nodes.find_by!(storage_path: "bracket.stl")
      assert_not_equal old, fresh.node_id, "the new object must not inherit the trashed identity"
      assert @user.nodes.find_by!(node_id: old).deleted
    end

    test "the scan never indexes the trash prefix" do
      id = create_file!(name: "t.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      scan!(max_delete_pct: 100)
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    test "deleting an already-trashed node is refused and leaves the trashed bytes alone" do
      id = create_file!(name: "once.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      assert_raises(FileLayer::NotFound) { adapter.delete(@user, node_id: id) }
      assert_equal "b", @fake.objects["#{PREFIX}/.trash/#{id}/once.stl"].body
    end

    test "a user cannot delete ANOTHER user's file by node_id" do
      id = create_file!(name: "mine.stl", bytes: "b")
      other = User.create!(email: "s3-other-#{SecureRandom.hex(4)}@example.com")
      assert_raises(FileLayer::NotFound) { adapter.delete(other, node_id: id) }
      assert_equal "b", @fake.objects["#{PREFIX}/mine.stl"].body
    end

    # --- the copy's preconditions and its wire format -------------------------------------

    # THE CONDITIONAL COPY, exercised for real rather than faulted. The plan's version of this
    # test did `@fake.fault!(:copy_object, "PreconditionFailed")`, which only proves that error
    # maps to FetchError — it would pass IDENTICALLY with copy_source_if_match never sent at all.
    # Vacuous for the thing it names. FakeS3#do_copy genuinely honors the header (deliberately),
    # so this drives a REAL concurrent overwrite: delete the precondition from the adapter and
    # the copy succeeds, nothing raises, and this fails.
    #
    # Why it matters: if the object changed between our listing and our copy, an unconditional
    # copy trashes bytes the user never meant to lose and then deletes them from their key.
    test "a concurrent overwrite makes the trash copy refuse rather than trash the wrong bytes" do
      id = create_file!(name: "raced.stl", bytes: "original")
      # Another tool overwrites the object AFTER the scan indexed it: new bytes, new ETag.
      @fake.seed!("#{PREFIX}/raced.stl", "overwritten by someone else")

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }

      assert_not @user.nodes.find_by!(node_id: id).deleted
      assert_equal "overwritten by someone else", @fake.objects["#{PREFIX}/raced.stl"].body,
                   "the bytes we did not index must not be trashed"
      assert_equal 0, @fake.calls[:delete_object], "and must not be deleted from their key"
    end

    # The ladder's rungs are not interchangeable as PRECONDITIONS, and this is where that bites.
    # An md5:/etag: identity IS the object's ETag and can be matched. A sha256: identity is a
    # CHECKSUM, not an ETag — sending it as one would make every If-Match fail, so every delete
    # and every move of such an object would refuse forever. We send nothing instead and take the
    # unconditional behavior (which is what a store ignoring the header gives anyway).
    #
    # NOT "HEAD for the current ETag first", which is the other option the plan offered: that is
    # precondition theater. The window worth guarding is between the SCAN and the DELETE — hours
    # — and a HEAD taken milliseconds before the copy would happily match an overwrite that landed
    # an hour ago, i.e. exactly the bytes this precondition exists to refuse to trash. It buys a
    # billed request and a false sense of safety.
    test "an md5 identity is sent as the copy precondition, QUOTED; a sha256 identity is not sent" do
      seen = :never_called
      @fake.client.stub_responses(:copy_object, lambda { |ctx|
        seen = ctx.params[:copy_source_if_match]
        { copy_object_result: { etag: '"x"' } }
      })

      adapter.delete(@user, node_id: create_file!(name: "m.stl", bytes: "mm"))
      assert_equal %Q("#{Digest::MD5.hexdigest('mm')}"), seen,
                   "the md5 rung IS the ETag — send it in the quoted form S3 itself emits"

      # THE sha256 IDENTITY IS SET BY HAND, and the reason is a finding rather than a shortcut.
      #
      # This used to pass `checksum_sha256:`/`checksum_type:` to create_file!, which seeded them on
      # the object and handed them to ObjectIdentity.for — implying a scan of such an object yields
      # `sha256:`. IT DOES NOT, AND CANNOT. `list_objects_v2` returns `checksum_algorithm` and
      # `checksum_type` but NEVER the checksum VALUE, so rung 1 is unreachable from a listing by
      # construction; it needs a HEAD per object, which is `LIBRARY_S3_HEAD_FOR_CHECKSUM` and is
      # not implemented (see Library::S3Observer#file_observation). Task 7 caught this by replacing
      # this file's hand-built fixture with the real observer: 79 of 80 tests agreed, and this was
      # the 80th. The fixture was wrong, not the observer.
      #
      # So NO PRODUCTION PATH mints a `sha256:` identity today, and this is an artificial node on
      # purpose. The test stays because the adapter must not send one as an ETag if it ever meets
      # one — from a future HEAD rung, or from `nodes.content_hash` being SHARED with share mode,
      # whose values are bare SHA-256 hex with no prefix at all. Deleting the test would delete the
      # guard for the case that actually arrives first.
      sha = create_file!(name: "s.stl", bytes: "ss")
      @user.nodes.find_by!(node_id: sha).update!(content_hash: "sha256:Ynl0ZXM=")

      adapter.delete(@user, node_id: sha)
      assert_nil seen, "a sha256 checksum is NOT an ETag: sent as one it would refuse every copy"
    end

    # ASSERTED AT THE WIRE, which is what makes this test independent of the fake's decoder.
    #
    # aws-sdk-s3 does NOT escape copy_source — it puts the string on the wire verbatim (verified
    # by capturing x-amz-copy-source at the :sign step), so the caller must encode it.
    #
    #   CGI.escape("Bracket v2.stl") -> "Bracket+v2.stl"
    #
    # CGI.escape is FORM encoding (application/x-www-form-urlencoded), where "+" means space. Real
    # S3 decodes the copy source per RFC 3986, where "+" is a LITERAL PLUS. So "Bracket v2.stl"
    # would be copied from the key "Bracket+v2.stl" — a different object. Traced through #delete:
    # the copy reads the wrong key (or 404s), the delete removes the RIGHT key, and the tombstone
    # follows the delete — so the user's file is permanently gone and the trash holds a copy of
    # someone else's. A space in a filename is the single most common thing in a CAD library.
    #
    # WHY THIS COMMENT CHANGED (2026-07-17, the first real-bucket run). It used to open "THE FAKE
    # CANNOT CATCH THIS ONE" and explain that FakeS3's CGI.unescape is CGI.escape's inverse, so a
    # form-encoding adapter passed every test in this file. That was TRUE and is now FALSE: the
    # fake decodes with URI::DEFAULT_PARSER.unescape, which is what a real store does, so it
    # misses "Bracket+v2.stl" exactly as SeaweedFS does (verified: the real store answers
    # Aws::S3::Errors::InvalidArgument, NOT a space-decoded hit).
    #
    # THE WIRE ASSERTION STAYS, and its reason is now the general one rather than a workaround for
    # a fake that forgave the bug: a round-trip through ANY test double can only ever prove the
    # double and the code agree, which is the precise mechanism that hid this bug at 79/80 green.
    # The wire format is the thing the store actually sees, so it is the thing to pin. The fake
    # agreeing with reality is defense in depth underneath it, not a replacement for it.
    #
    # Per-segment ERB::Util.url_encode is correct against BOTH: "%20" decodes to a space in the
    # fake AND on a real store (checked live for space, "+", "%", unicode, "&", "#", "?").
    test "the copy source is URL-encoded the way REAL S3 decodes it, not form-encoded" do
      id = create_file!(name: "Bracket v2.stl", bytes: "solid")
      seen = nil
      @fake.client.handle(step: :sign) do |ctx|
        seen = ctx.http_request.headers["x-amz-copy-source"] if ctx.operation_name == :copy_object
        @handler.call(ctx)
      end

      adapter.delete(@user, node_id: id)

      assert_equal "b/#{PREFIX}/Bracket%20v2.stl", seen,
                   "a space must go on the wire as %20 — CGI.escape's + is a literal plus to S3"
      assert_equal "solid", @fake.objects["#{PREFIX}/.trash/#{id}/Bracket v2.stl"].body
    end

    # A TEST OF THE FAKE, deliberately, and the only one in this file — because this fake's
    # decoder is load-bearing infrastructure for every copy test above it, and it was WRONG until
    # the first real-bucket run (2026-07-17) looked.
    #
    # The property under test is the one whose ABSENCE hid the CGI.escape bug at 79/80 green:
    # a form-encoded copy source must MISS, here, exactly as it misses on a real store. Without
    # this, nothing stops the fake drifting back to CGI.unescape — a one-word edit that silently
    # re-forgives the whole class of bug and leaves the wire assertion above as the only guard for
    # the copy paths that happen to have one.
    #
    # The expected values are not invented; they were read off SeaweedFS 4.39:
    #   copy_source ".../plus/Bracket+Mount.stl" against a bucket holding "plus/Bracket Mount.stl"
    #   -> Aws::S3::Errors::InvalidArgument. The store does not read "+" as a space. Neither may
    #   this fake.
    test "FakeS3 decodes a copy source like a real store: percent-decoding, never form-decoding" do
      @fake.seed!("plus/Bracket Mount.stl", "the real bytes")

      # "%20" IS a space to a real store, so the fake must find the object.
      @fake.client.copy_object(bucket: "b", key: "plus/ok.stl",
                               copy_source: "b/plus/Bracket%20Mount.stl")
      assert_equal "the real bytes", @fake.objects["plus/ok.stl"].body,
                   "%20 must decode to a space, as it does on a real store"

      # "+" is a LITERAL PLUS to a real store, so a form-encoded source names a key that does not
      # exist and the copy must fail. Green here is the bug.
      assert_raises(Aws::S3::Errors::NoSuchKey,
                    "a form-encoded '+' must NOT resolve to a space — that is the CGI.escape " \
                    "bug this fake once forgave") do
        @fake.client.copy_object(bucket: "b", key: "plus/bad.stl",
                                 copy_source: "b/plus/Bracket+Mount.stl")
      end
      assert_nil @fake.objects["plus/bad.stl"], "nothing may be written by a copy that must fail"
    end

    # --- a copy re-tags, and the row must follow it ----------------------------------------

    # F-65. THE FAKE'S OWN CONTRACT, asserted directly, because everything below it rests on the
    # fake disagreeing with the code where a real store disagrees with it.
    #
    # `Obj` has five fields and `do_copy` used to re-derive exactly one of them (last_modified,
    # itself forced by a bug of this shape — see trash_purge_job_test.rb). `etag` was inherited,
    # which is verbatim the adapter's own unstated assumption, so a `move` leaving `content_hash`
    # stale and a `move` refreshing it produced IDENTICAL suite results. A fake that shares the
    # code's misunderstanding confirms it (CLAUDE.md §14e).
    #
    # This test does not go through the adapter on purpose: the property belongs to the fake, and
    # every test below it would go green again if this rule were reverted, so this is the one that
    # has to name it. Reverting do_copy to `{ etag: o.etag }` turns THIS red.
    test "FakeS3: a copy mints its ETag from its own bytes — a seeded override does not survive" do
      body = "multipart-uploaded bytes"
      @fake.seed!("src.stl", body, etag: "#{'a' * 32}-7") # what a real multipart upload carries

      res = @fake.client.copy_object(bucket: "b", key: "dst.stl", copy_source: "b/src.stl")

      expected = %Q("#{Digest::MD5.hexdigest(body)}")
      assert_equal expected, res.copy_object_result.etag,
                   "the RESPONSE carries the copy's ETag — that value is what #move stores"
      assert_equal expected, @fake.objects["dst.stl"].etag,
                   "and the stored object must agree with what the response claimed"
      assert_equal %Q("#{'a' * 32}-7"), @fake.objects["src.stl"].etag,
                   "the SOURCE is untouched: only the copy is re-tagged"
    end

    # F-04's three cases below all install this rather than leaning on the fixed do_copy above, and
    # the independence is the whole point: if they relied on the fake to produce the re-tag, then
    # reverting do_copy would make them pass vacuously — the false green this pair exists to end.
    # So the re-tag is forced here, by a value the bytes could never produce.
    #
    # It HONORS copy_source_if_match, which is the assertion's entire mechanism: a stub that
    # ignored the precondition would let a stale content_hash through and every test below would
    # pass with the fix reverted.
    def retag_copies!(new_etag)
      @fake.client.stub_responses(:copy_object, lambda { |ctx|
        src = URI::DEFAULT_PARSER.unescape(ctx.params[:copy_source].to_s.split("/", 2).last)
        o = @fake.objects[src] or return "NoSuchKey"
        return "PreconditionFailed" if (m = ctx.params[:copy_source_if_match]) && m != o.etag

        @fake.objects[ctx.params[:key]] =
          o.dup.tap { |c| c.etag = new_etag; c.last_modified = Time.now }
        { copy_object_result: { etag: new_etag } }
      })
    end

    # F-04. THE ORDINARY UI SEQUENCE — move a file, then delete it — against the object population
    # this backend exists to serve. A store re-tags a copy whenever the source ETag was not
    # md5(bytes): a multipart-origin object (rung 3) or an SSE-KMS one (which wears a 32-hex ETag
    # and is therefore misfiled onto rung 2). Leave content_hash naming the SOURCE's ETag and the
    # next copy_source_if_match names an ETag no object has: PreconditionFailed -> FetchError ->
    # 503 "try again", until Library::ScanJob's next pass repairs the row.
    #
    # Drop `content_hash:` from #move's node.update! and this is the test that dies.
    test "move refreshes the row's identity from the copy, so the next delete still matches" do
      id = create_file!(name: "moved.stl", bytes: "bracket")
      retag_copies!('"7b1f0c9e"') # the destination is not what the source was

      adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "renamed.stl")

      # THE USER-VISIBLE SYMPTOM FIRST: a stale precondition raises FetchError here, which the web
      # layer renders as a 503 "try again" on the file they just moved, for up to fifteen minutes.
      # (`delete` writes only `deleted`/`storage_path`, so the identity assertion below still reads
      # what `move` left.)
      assert_nothing_raised { adapter.delete(@user, node_id: id) }
      assert @user.nodes.find_by!(node_id: id).deleted
      assert_equal "etag:7b1f0c9e", @user.nodes.find_by!(node_id: id).content_hash,
                   "the row must name the ETag the BUCKET now has, through ObjectIdentity"
    end

    # F-04, the second half — and it fails INDEPENDENTLY of the first: restored_stat already holds
    # the HEAD that carries `.etag` and dropped it, while its own comment says its purpose is "so
    # the next scan skips it" and Reconciler#unchanged? tests content_hash FIRST.
    test "undelete refreshes the row's identity from its HEAD, so the next delete still matches" do
      id = create_file!(name: "restored.stl", bytes: "lamp")
      retag_copies!('"3c4d5e6f"')

      adapter.delete(@user, node_id: id)
      adapter.undelete(@user, node_id: id)

      # A restored file must not be undeletable — same 503, one verb over.
      assert_nothing_raised { adapter.delete(@user, node_id: id) }
      assert_equal "etag:3c4d5e6f", @user.nodes.find_by!(node_id: id).content_hash
    end

    # THE GUARD, and why it is a presence test rather than a rescue. ObjectIdentity.for RAISES
    # ArgumentError on a blank ETag (deliberately: the ladder must be total, and a nil identity
    # means Reconciler#plan_moves drops the object and never indexes it at all). ArgumentError is
    # not an Aws ServiceError, so #move's rescue would not catch it — and by the line that would
    # raise, delete_object has ALREADY removed the source.
    #
    # SO THE RAISE IS CAUGHT BY HAND RATHER THAN BY assert_nothing_raised, and "the source is gone"
    # is asserted FIRST and unconditionally. That ordering is the evidence: under the mutation both
    # facts have to be visible at once — the store answered nothing, the source key is already
    # deleted, and an unguarded refresh blows up there — or the test proves only that something
    # raised somewhere, which says nothing about whether the guard sits where it matters.
    # A raise in that window leaves the bytes only at the new key with the row still naming the
    # old one: §14a's orphaning landmine, reached by a store merely being unhelpful.
    #
    # Make the refresh unconditional and this goes red with ArgumentError.
    test "a copy that reports no ETag leaves the previous identity in place rather than raising" do
      id = create_file!(name: "quiet.stl", bytes: "hush")
      before = @user.nodes.find_by!(node_id: id).content_hash
      retag_copies!("") # a store that answers a copy with no ETag at all

      raised = nil
      begin
        adapter.move(@user, node_id: id, new_name: "quieter.stl")
      rescue StandardError => e
        raised = e
      end

      assert_not @fake.objects.key?("#{PREFIX}/quiet.stl"),
                 "the source is already deleted by the line that derives the new identity"
      assert_nil raised, "a store that reports no ETag must not blow up a move that landed"

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "quieter.stl", node.storage_path, "the move itself must still land"
      assert_equal before, node.content_hash,
                   "keep the previous value — NEVER nil, which un-indexes the object"
    end

    # THE SAME GUARD, ONE VERB OVER — and it went in unmutated. Removing `if head.etag.present?`
    # from #restored_stat ALONE left all 286 tests green, so nothing had ever shown that half to
    # work (CLAUDE.md §15: a guard that has never failed has not been shown to work).
    #
    # ITS FAILURE MODE IS WORSE THAN #move'S, which is why it earns its own test rather than an
    # argument-by-symmetry. #restored_stat's own rescue lists ServiceError/NetworkingError only, so
    # an ArgumentError from the refresh escapes it AND escapes into #undelete's caller — after the
    # copy has landed and BEFORE `node.update!(deleted: false, ...)`. That leaves the bytes at BOTH
    # keys, the node still tombstoned, and the trash copy never swept: the user's file is restored
    # in the bucket and still in the Trash in the app, and the next undelete hits the
    # "occupied — undelete must not clobber" refusal against a copy of itself.
    #
    # Make the refresh unconditional and this goes red with ArgumentError.
    test "a HEAD that reports no ETag leaves the restore complete rather than raising" do
      id = create_file!(name: "quietly-restored.stl", bytes: "shade")
      before = @user.nodes.find_by!(node_id: id).content_hash
      adapter.delete(@user, node_id: id)

      # Blank the ETag on HEAD only, delegating everything else to the fake — object_exists? asks
      # this same verb and must keep answering truthfully, or the test passes for the wrong reason.
      @fake.client.stub_responses(:head_object, lambda { |ctx|
        o = @fake.objects[ctx.params[:key]] or return "NotFound"
        { content_length: o.body.bytesize, etag: "", last_modified: o.last_modified }
      })

      raised = nil
      begin
        adapter.undelete(@user, node_id: id)
      rescue StandardError => e
        raised = e
      end

      # THE THREE FACTS THAT MUST BE VISIBLE TOGETHER under the mutation, asserted before the raise
      # so the test cannot pass by proving merely that something raised somewhere.
      node = @user.nodes.find_by!(node_id: id)
      assert @fake.objects.key?("#{PREFIX}/quietly-restored.stl"), "the copy back has landed"
      assert_not node.deleted, "the node must be live again, not stranded mid-restore"
      assert_nil raised, "a store that reports no ETag must not blow up a restore that landed"

      assert_equal before, node.content_hash,
                   "keep the previous value — NEVER nil, which un-indexes the object"
    end

    # --- the 5GB copy cap -----------------------------------------------------------------

    # copy_object is capped at 5GiB: it ERRORS, it does not truncate. Both delete and move are
    # copy-then-delete, so neither can run above it.
    #
    # Refused from node.size BEFORE the request, and the tombstone never happens — 2b's EXDEV
    # shape: a clear error, never a silent half-delete. UnsupportedOperation because it is a
    # PERMANENT property of this node on this backend (a client condition -> 409/422), not
    # FetchError, which would tell the user to retry an operation that can never succeed.
    test "delete refuses an object over the copy cap rather than half-deleting it" do
      id = create_file!(name: "huge.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:size, FileLayer::S3::COPY_MAX_BYTES + 1)

      err = assert_raises(FileLayer::UnsupportedOperation) { adapter.delete(@user, node_id: id) }
      assert_match(/5 ?GiB|copy cap|too large/i, err.message)
      assert_equal 0, @fake.calls[:copy_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.calls[:delete_object]
      assert_not @user.nodes.find_by!(node_id: id).deleted, "and nothing is tombstoned"
      assert_equal "b", @fake.objects["#{PREFIX}/huge.stl"].body
    end

    test "move refuses an object over the copy cap" do
      id = create_file!(name: "huge.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:size, FileLayer::S3::COPY_MAX_BYTES + 1)

      assert_raises(FileLayer::UnsupportedOperation) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "huge2.stl")
      end
      assert_equal 0, @fake.calls[:copy_object]
      assert_equal "huge.stl", @user.nodes.find_by!(node_id: id).storage_path
    end

    # The size guard reads node.size, which the scan wrote — so it is STALE if the object grew
    # since. The store's own refusal is the backstop, and it must land in the fail-safe direction:
    # whatever error an S3-compatible store picks for an over-cap copy, it is a ServiceError, so
    # it maps to FetchError and NOTHING IS TOMBSTONED. That is the property that matters, and it
    # does not depend on the error's NAME — which is just as well: see COPY_MAX_BYTES, where the
    # plan's "verify the exact error class" turns out to be unfalsifiable.
    test "a store-side copy refusal is transient and tombstones nothing, whatever it is called" do
      id = create_file!(name: "grown.stl", bytes: "b")
      @fake.fault!(:copy_object, "InvalidRequest") # what AWS answers an over-cap copy source

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }
      assert_not @user.nodes.find_by!(node_id: id).deleted
      assert_equal "b", @fake.objects["#{PREFIX}/grown.stl"].body
    end

    # --- directories: this backend's own answer -------------------------------------------

    # CAN a dir node reach here? YES — Task 7 synthesizes dir nodes from key prefixes, so a user
    # can click delete on a folder in the browse UI. It is not a hypothetical.
    #
    # WITHOUT this guard the failure is not loud, it is a LIE: a dir node's storage_path is "cad",
    # so key_for composes "library/cad" — a key that does not exist, because S3 has no directories
    # and the dir is a synthesis of a prefix. The copy 404s, that maps to FetchError (correctly —
    # every unknown store error must), and the user is told to RETRY, forever, an operation that
    # can never succeed. Verified by mutation: delete the guard and this test sees FetchError.
    #
    # WHY REFUSE RATHER THAN CASCADE — Share's argument transfers, and gets worse. Share: "a
    # cascade whose inverse does not exist is a delete the user cannot undo" (undelete restores
    # ONE path under ONE parent; 2b is file-only). On S3 a cascade is additionally N copies + N
    # deletes with no atomicity across them, so a failure at object 400 of 1000 leaves half the
    # subtree in .trash and half live, with no undo for either half.
    #
    # The CONCLUSION matches Share's; the ARGUMENT does not, and that is why Share named its guard
    # deletable_file! per-op rather than by kind. Share refuses because File.rename on a directory
    # SUCCEEDS and strands the children (its danger is that it works too well). This refuses
    # because there is nothing to copy at all.
    test "deleting a DIRECTORY is refused as a client condition, not a retry-forever FetchError" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                deleted: false, storage_path: "cad", mtime: 1)
      create_file!(name: "cad/gear.stl", bytes: "g")

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.delete(@user, node_id: dir.node_id)
      end
      assert_match(/files only/, err.message)
      assert_equal 0, @fake.calls[:copy_object], "refused BEFORE any request left the process"
      assert_not @user.nodes.find_by!(node_id: dir.node_id).deleted
      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body, "the children are untouched"
    end

    # A DELIBERATE DIVERGENCE FROM SHARE, which ALLOWS a directory move. Share's permission rests
    # entirely on File.rename being ONE ATOMIC SYSCALL that carries the bytes with it: the
    # children stay OBSERVABLE at the new path, so the next scan re-homes them with their node_ids
    # intact. That primitive does not exist here.
    #
    # On S3 "moving cad/ to cad2/" is 2N non-atomic requests, and the tempting cheap version —
    # rewrite the dir node's storage_path and touch no keys — is silent corruption: the children's
    # KEYS stay at cad/*, their nodes still say cad/*, and the next scan re-synthesizes a dir node
    # at the cad/ prefix. The tree then claims a folder the bytes are not in.
    #
    # So both verbs refuse dirs here, and unlike Share the two refusals come from ONE fact —
    # there is no directory and there is no rename — rather than from Share's observable-vs-skipped
    # asymmetry. This is a real capability regression against Share, and it is the honest one:
    # a user renaming a folder in their own S3 console does the same 2N copies, and the observer
    # pairs every child back by (content_hash, size). We decline to ORIGINATE it, not to survive it.
    test "moving a DIRECTORY is refused: S3 has no directory and no rename" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                deleted: false, storage_path: "cad", mtime: 1)
      gear = create_file!(name: "cad/gear.stl", bytes: "g")

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.move(@user, node_id: dir.node_id, new_parent_node_id: nil, new_name: "cad2")
      end
      assert_match(/files only/, err.message)
      assert_equal 0, @fake.calls[:copy_object]
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: gear).storage_path
      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
    end

    # UnsupportedOperation is a StandardError, and that is load-bearing rather than taxonomy: a
    # user clicked delete on a folder, so GeneratePreviewJob's `rescue StandardError` shape must
    # catch it. NotImplementedError is a ScriptError and would propagate uncaught and page on-call.
    test "a refused directory delete is a client condition, catchable by rescue StandardError" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                deleted: false, storage_path: "cad", mtime: 1)
      caught = begin
        adapter.delete(@user, node_id: dir.node_id)
        nil
      rescue StandardError => e
        e
      end
      assert_instance_of FileLayer::UnsupportedOperation, caught
    end

    # --- move (task 6) --------------------------------------------------------------------

    test "move copies to the new key, removes the original, and keeps the node_id" do
      id = create_file!(name: "old.stl", bytes: "same")
      attachment = attach!(id)
      adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "new.stl")

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "new.stl", node.storage_path
      assert_equal "new.stl", node.name
      assert_equal "same", @fake.objects["#{PREFIX}/new.stl"].body
      assert_nil @fake.objects["#{PREFIX}/old.stl"], "S3 has no rename: the original is removed"

      scan!
      assert_equal id, @user.nodes.find_by!(storage_path: "new.stl").node_id, "the scan must agree"
      assert_not orphaned?(attachment), "the attachment survives the move — the port's promise"
    end

    test "move into a subdirectory addressed by parent_node_id" do
      id = create_file!(name: "loose.stl", bytes: "g")
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      adapter.move(@user, node_id: id, new_parent_node_id: parent.node_id, new_name: "gear.stl")

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
      assert_nil @fake.objects["#{PREFIX}/loose.stl"]
    end

    test "move refuses to overwrite an existing object" do
      a = create_file!(name: "a.stl", bytes: "aaa")
      create_file!(name: "b.stl", bytes: "bbb")
      assert_raises(FileLayer::UnsupportedOperation) do
        adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_equal "bbb", @fake.objects["#{PREFIX}/b.stl"].body, "the destination is untouched"
      assert_equal "aaa", @fake.objects["#{PREFIX}/a.stl"].body, "and the source survives"
      assert_equal 0, @fake.calls[:copy_object], "checked BEFORE copying"
    end

    # A clobber check that fails for a reason OTHER than absence must not read as "vacant" — the
    # same fail-safe direction write's HEAD takes, and the same credentials-outage shape.
    test "a move whose clobber check fails transiently refuses rather than assuming vacant" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      @fake.fault!(:head_object, "AccessDenied")
      assert_raises(FileLayer::FetchError) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_equal 0, @fake.calls[:copy_object]
    end

    # "../escaped.stl" contains a separator, so it is the LEAF check that refuses it — assert the
    # MESSAGE so this test names what it actually pins (2b shipped this asserting NotFound by class
    # alone, and it pinned nothing).
    test "move refuses a new_name that is not a leaf" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      [ "cad/gear.stl", "../escaped.stl", "/etc/passwd", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: bad)
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal 0, @fake.calls[:copy_object], "refused BEFORE any request left the process"
      assert_equal "aaa", @fake.objects["#{PREFIX}/a.stl"].body
    end

    # THE escape guard on move's DESTINATION, reached the only way it can be — through the parent.
    #
    # assert_raises IS THE LOAD HERE, unlike the read path's escape tests where it is decoration.
    # Same split Task 5 found for write, and for the same reason: with the guard deleted this
    # composes "library/../escaped/pwned.stl" and copy_object SUCCEEDS — nothing raises, and the
    # bytes land outside the prefix. On the read side a bogus key merely 404s, so the raise happens
    # anyway and only the call count carries any weight. Work out which case a test is in.
    test "move to a destination that escapes the prefix is refused" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 deleted: false, storage_path: "../escaped", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: evil.node_id, new_name: "pwned.stl")
      end
      assert_match(/escapes/, err.message)
      assert_equal 0, @fake.calls[:copy_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.objects.keys.count { |k| !k.start_with?("#{PREFIX}/") },
                   "nothing may be written outside the prefix"
    end

    # THE FLAG TASK 5 LEFT FOR TASK 6, in its own words: "move's destination needs this same
    # guard". A move into .trash is a live node at a key Task 7's observer never observes ->
    # unpairable ghost -> tombstone -> the mass-deletion guard refuses that scan and every scan
    # after it. 2b's retracted sentence — "a move is self-healing because the bytes stay
    # observable" — is false exactly when the DESTINATION is the unobservable one.
    test "move refuses a destination the scan does not index" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil,
                     new_name: Library::Scanner::TRASH_PREFIX)
      end
      assert_match(/reserved/, err.message)
      assert_equal 0, @fake.calls[:copy_object]

      # ...and a NESTED .trash is the user's own folder: observed, indexed, none of our business.
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      assert_nothing_raised do
        adapter.move(@user, node_id: id, new_parent_node_id: parent.node_id,
                     new_name: Library::Scanner::TRASH_PREFIX)
      end
    end

    # The row is updated LAST, so a failed copy/delete leaves the node pointing at bytes that are
    # still there. And a failure BETWEEN the copy and the delete is self-healing rather than
    # silent: both keys exist, so the next scan pairs old->new by (content_hash, size) and re-homes
    # the node with its node_id. Unlike delete, there is no tombstone to get wrong here — which is
    # exactly why delete is the dangerous one.
    test "a failed move leaves the node and the bytes where they were" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      @fake.fault!(:copy_object, "InternalError")

      assert_raises(FileLayer::FetchError) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "b.stl")
      end
      node = @user.nodes.find_by!(node_id: id)
      assert_equal "a.stl", node.storage_path
      assert_equal "aaa", @fake.objects["#{PREFIX}/a.stl"].body
      assert_equal 0, @fake.calls[:delete_object]
    end

    # --- undelete (task 6) ----------------------------------------------------------------

    test "undelete copies the bytes back and revives the node with its node_id" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      attachment = attach!(id)
      adapter.delete(@user, node_id: id)
      assert orphaned?(attachment), "a trashed file's attachment is dangling by construction"

      adapter.undelete(@user, node_id: id)

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted
      assert_equal "bracket.stl", node.storage_path
      assert_equal "solid", @fake.objects["#{PREFIX}/bracket.stl"].body
      assert_nil @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"], "the trash entry is consumed"
      assert_not orphaned?(attachment), "and the attachment resolves again"
    end

    test "undelete restores into the original subdirectory, not the root" do
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl",
                           io: StringIO.new("g"))
      adapter.delete(@user, node_id: info.node_id)
      adapter.undelete(@user, node_id: info.node_id)

      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: info.node_id).storage_path
      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
    end

    # The `live: false` parent lookup, and S3 needs it MORE than Share does: trashing the only
    # file under a prefix makes that prefix disappear, so Task 7's observer — which synthesizes
    # dirs FROM prefixes — tombstones the dir node. Refusing here would make the last file in any
    # folder permanently unrestorable, which is the common case rather than an edge one.
    #
    # No mkdir_p is needed (S3 has no directories): writing the key makes the prefix exist again,
    # and the observer revives that very dir node by storage_path with its original node_id.
    test "undelete restores into a parent the scan tombstoned after the folder emptied" do
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl",
                           io: StringIO.new("g"))
      adapter.delete(@user, node_id: info.node_id)
      parent.update!(deleted: true) # the prefix is empty now; the observer tombstones the dir

      assert_nothing_raised { adapter.undelete(@user, node_id: info.node_id) }
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: info.node_id).storage_path
      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
    end

    test "undelete refuses when something else now occupies the key" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      @fake.seed!("#{PREFIX}/bracket.stl", "someone else's file")

      assert_raises(FileLayer::UnsupportedOperation) { adapter.undelete(@user, node_id: id) }
      assert_equal "someone else's file", @fake.objects["#{PREFIX}/bracket.stl"].body,
                   "undelete must never clobber a live object"
      assert @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"], "the trashed bytes survive"
    end

    test "undeleting a LIVE node is a clean NotFound, not a confusing copy" do
      id = create_file!(name: "live.stl", bytes: "b")
      assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_equal 0, @fake.calls[:copy_object]
    end

    test "a user cannot undelete ANOTHER user's trashed node" do
      id = create_file!(name: "mine.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      other = User.create!(email: "s3-other-#{SecureRandom.hex(4)}@example.com")
      assert_raises(FileLayer::NotFound) { adapter.undelete(other, node_id: id) }
    end

    test "undelete of a node whose trashed bytes are gone is terminal NotFound" do
      id = create_file!(name: "purged.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      @fake.objects.delete("#{PREFIX}/.trash/#{id}/purged.stl")
      create_file!(name: "other.stl", bytes: "the library is populated") # so the probe says present

      err = assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_match(/purged/, err.message)
    end

    # AN UNMOUNTED LIBRARY MUST NEVER READ AS "YOUR FILE IS PERMANENTLY GONE". Share raises
    # FetchError, not NotFound, when the trashed bytes are missing AND the root looks unmounted.
    # S3's equivalent of "unmounted" is a credentials outage / a wrong bucket / a mistyped prefix —
    # which is exactly what FetchError already means, and it makes EVERY object 404 at once.
    # NotFound is terminal; a genuinely purged file retried is harmless, a live library burned to
    # "your file is gone" is not. Same trade, same direction as read's (spec §6).
    test "undelete with the library prefix EMPTY is transient, not a false 'purged'" do
      id = create_file!(name: "gone.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      @fake.objects.clear # the bucket is wrong/empty/unreachable, not "the purge job ran"

      assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }
      assert @user.nodes.find_by!(node_id: id).deleted, "and it stays restorable"
    end

    # The probe is itself I/O against the store that just failed, so it fails too during a real
    # outage. It must not turn a transient answer terminal on its way out.
    test "an undelete whose trash HEAD fails transiently stays transient" do
      id = create_file!(name: "flaky.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      @fake.fault!(:head_object, "AccessDenied")

      assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }
      assert @user.nodes.find_by!(node_id: id).deleted
    end

    # ORDER: copy -> revive -> sweep the trash copy. The redundant copy is dropped LAST, after the
    # node is live, and the sweep is BEST-EFFORT rather than raising — the same "the destructive
    # act goes last" rule delete's tombstone follows, applied to undelete's one destructive act.
    #
    # Copy -> delete-trash -> revive (the order that mirrors Share) is the LANDMINE AGAIN: a failed
    # delete-trash would raise with the node still trashed and the bytes already at their real key,
    # so the next scan observes an unclaimed path, cannot revive by path (storage_path is NULL),
    # and mints a NEW node — orphaning every attachment. Share cannot have both copies at once
    # (rename is atomic) and so cannot reach for this; we can, and having both beats having neither.
    test "a failed trash sweep still leaves the file restored, not half-undeleted" do
      id = create_file!(name: "swept.stl", bytes: "b")
      attachment = attach!(id)
      adapter.delete(@user, node_id: id)
      @fake.fault!(:delete_object, "InternalError")

      assert_nothing_raised { adapter.undelete(@user, node_id: id) }

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted, "the undelete SUCCEEDED — the leftover is the purge job's problem"
      assert_equal "swept.stl", node.storage_path
      assert_equal "b", @fake.objects["#{PREFIX}/swept.stl"].body
      assert_not orphaned?(attachment)

      # ...and the next scan is a no-op rather than a resurrection or a duplicate.
      @fake.clear_faults!
      assert_nothing_raised { scan!(max_delete_pct: 100) }
      assert_equal id, @user.nodes.find_by!(storage_path: "swept.stl").node_id
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    # A failed COPY must leave the node trashed and the trashed bytes intact — the file is still
    # restorable, and the user retries. Never a revive whose bytes never arrived.
    test "a failed undelete copy revives nothing and keeps the trashed bytes" do
      id = create_file!(name: "back.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      @fake.fault!(:copy_object, "InternalError")

      assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }

      assert @user.nodes.find_by!(node_id: id).deleted, "still trashed, still restorable"
      assert_equal "b", @fake.objects["#{PREFIX}/.trash/#{id}/back.stl"].body
      assert_nil @fake.objects["#{PREFIX}/back.stl"]
    end

    test "s3 is the unversioned, unsyncable, PRESIGNABLE backend" do
      caps = adapter.capabilities
      refute caps.versioned?, "the object IS the truth — restore is a chunk-mode feature"
      refute caps.syncable?
      assert caps.presignable?, "a bucket has a URL signer — §15 survives here"
    end

    # THE FILTER #trashed TURNS ON. It cannot live in the shared contract — chunk mode has no scan
    # tombstone to exclude — so it is asserted on both backends that DO have one. ShareTest
    # carries the identical test: the Reconciler that mints this tombstone is shared between the
    # two, and the filter that must exclude it is duplicated, which is precisely why one test is
    # not enough.
    #
    # An object the user deleted with rclone or the console is GONE: nothing was ever copied to
    # the trash prefix, so `undelete` cannot bring it back. Listing it would offer a Restore
    # button that always fails.
    test "an object deleted out of band is not in the trash — there is nothing to restore" do
      # BALLAST, NOT DECORATION: with only one object, deleting it empties the prefix, and an
      # empty prefix is how this adapter recognises an unreachable bucket — so undelete would
      # answer FetchError ("try again later") instead of NotFound ("it's gone"), and the assertion
      # below would pin that heuristic rather than the trash filter. A real bucket has other
      # objects in it.
      create_file!(name: "ballast.stl", bytes: "still here")
      id = create_file!(name: "outofband.stl", bytes: "aaa")
      delete_file!(id) # deleted from the bucket + tombstoned: a SCAN tombstone, storage_path kept

      assert_not_includes adapter.trashed(@user).map(&:node_id), id
      # The reason it must not be listed, asserted rather than assumed.
      assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
    end

    # ---- mkdir (project folders) ---------------------------------------------

    test "mkdir puts a dir-marker object + a dir node, idempotent" do
      info = adapter.mkdir(@user, parent_node_id: nil, name: "Projects")
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "dir", node.kind
      assert_equal "Projects", node.storage_path
      # An empty folder needs a dir-marker object to survive the scan.
      assert_nothing_raised do
        @fake.client.head_object(bucket: "b", key: "#{PREFIX}/Projects/")
      end

      again = adapter.mkdir(@user, parent_node_id: nil, name: "Projects")
      assert_equal info.node_id, again.node_id
      assert_equal 1, @user.nodes.where(kind: "dir", storage_path: "Projects").count
    end

    test "mkdir nests under a parent dir node" do
      root = adapter.mkdir(@user, parent_node_id: nil, name: "Projects")
      sub  = adapter.mkdir(@user, parent_node_id: root.node_id, name: "desk-lamp")
      assert_equal "Projects/desk-lamp", @user.nodes.find_by!(node_id: sub.node_id).storage_path
    end

    test "an empty mkdir'd folder survives an observer/reconciler pass" do
      info = adapter.mkdir(@user, parent_node_id: nil, name: "Projects")
      scan!(max_delete_pct: 100)
      node = @user.nodes.find_by(node_id: info.node_id)
      assert node && !node.deleted, "the dir-marker keeps the empty folder alive"
    end
  end
end
