module Maker
  # WHO MAY READ WHAT THROUGH THE SANDBOX DOOR (2026-11-19, embedded files; SandboxController,
  # docs/invariants/files-preview.md "The sandbox door"). An HTML file from the library runs its own
  # scripts, so it is served from `/sandbox/<token>/<path>` under an enforcing CSP `sandbox` policy
  # that gives the document an OPAQUE origin. This class answers the two questions that door asks:
  # is this token good, and which file does this path name.
  #
  # THE TOKEN IS THE CREDENTIAL, NEVER THE SESSION. A sandboxed document's own requests carry no
  # `SameSite=Lax` cookie — its origin is opaque, so every request it makes is cross-site — and a
  # cookie-checked door would serve the HTML and then refuse every file beside it. The token names the
  # OWNER, the HTML FILE and, on a visitor's page, the PROJECT that page is about. It is signed with
  # this app's key generator under its own purpose (a token minted for anything else never verifies
  # here) and expires in TTL; each page render mints a fresh one, so a long-open tab is the only thing
  # that outlives it.
  #
  # A PATH NAMES THE HTML FILE ITSELF OR A FILE IN ITS FOLDER AND BELOW — never above, so a token for
  # `out/viewer/case.html` reaches `out/viewer/**` and nothing else of the library. Resolved through the
  # catalog by PARENT EDGE AND NAME, never a `storage_path` (chunk_remote nodes have none, and a moved
  # child's path is stale until a scan pairs it — §14a). A segment that is empty, `..`, or starts with
  # a dot is REFUSED, never normalised (`FileLayer::S3#key_for`'s rule): normalising `a/../b` would
  # turn a refusal into a valid read of something else, and the dot rule keeps `.git`, `.trash` and
  # every dot-file out without a list of names.
  #
  # A PUBLIC TOKEN RE-ASKS THE PAGE'S OWN QUESTION FOR EVERY FILE: the project must still be published
  # and `PublicProject#permits?` must pass for the HTML file and for each file it loads. Unpublishing
  # therefore closes the door on the next request, not twelve hours later, and a viewer can never pull
  # a file through the door that the public file page would refuse.
  class HtmlSandbox
    PURPOSE = "html_sandbox".freeze
    TTL = 12.hours

    # THE CATALOG'S SIZE IS THE GATE, BEFORE ANY READ (Maker::MarkdownFile's shape): the port's `read`
    # takes no byte limit and holds the whole file in memory. The motivating viewer is 4.2 MB of mesh
    # data inlined into one page; 32 MB leaves it room to grow without letting one request pull a
    # 256 MB file (FileLayer::MAX_BYTES) through a Puma thread.
    MAX_BYTES = 32 * 1024 * 1024

    # WHAT THE FRAME MAY DO, ONE STRING FOR THE RESPONSE HEADER AND THE <iframe> ATTRIBUTE ALIKE.
    # `allow-popups-to-escape-sandbox` is what lets an outbound link in the page open a working site
    # in a new tab — without it the new tab inherits the sandbox and a stranger's site runs with no
    # scripts. It cannot reopen THIS door unsandboxed: every response from it carries the header.
    #
    # NEVER `allow-same-origin`. That one token hands the document this app's origin back — the
    # session, every page, every door — which is the whole of what the sandbox exists to withhold.
    # test/integration/web/sandbox_test.rb refuses it in both places.
    PERMISSIONS = %w[
      allow-scripts allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox
      allow-downloads allow-pointer-lock
    ].join(" ").freeze

    # The page's own facts, read once per request: the file's owner, the HTML file the token names,
    # and the visitor's project (nil on the owner's own pages).
    Grant = Data.define(:owner, :html, :public_project)

    def self.token_for(owner:, node:, project: nil)
      verifier.generate({ "u" => owner.id, "n" => node.node_id, "p" => project&.id },
                        purpose: PURPOSE, expires_in: TTL)
    end

    # nil for anything that is not a live grant: a forged, expired or foreign token, an owner or file
    # gone since it was minted, an HTML file that is no longer HTML, a project that is no longer
    # published, or one that no longer permits the file. The door answers every one of them 404.
    def self.grant(token)
      data = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless data.is_a?(Hash)

      owner = User.find_by(id: data["u"])
      html = owner&.nodes&.present&.find_by(node_id: data["n"].to_s, kind: "file")
      return nil unless html && Maker::FileAttachment.html?(html.name)

      pub = nil
      if data["p"]
        project = owner.maker_projects.published.find_by(id: data["p"])
        return nil unless project

        pub = Maker::PublicProject.new(project)
        return nil unless pub.permits?(html)
      end
      Grant.new(owner:, html:, public_project: pub)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    # The node `path` names under this grant, or nil. `path` is the route's glob, already
    # percent-decoded by the router.
    def self.resolve(grant, path)
      segments = path.to_s.split("/", -1)
      return nil if segments.empty? || segments.any? { |s| s.empty? || s.start_with?(".") }

      nodes = grant.owner.nodes.present
      parent = grant.html.parent_node_id
      segments[0..-2].each do |name|
        dir = nodes.find_by(parent_node_id: parent, name:, kind: "dir")
        return nil unless dir

        parent = dir.node_id
      end
      node = nodes.find_by(parent_node_id: parent, name: segments.last, kind: "file")
      return nil unless node
      return nil if grant.public_project && !grant.public_project.permits?(node)

      node
    end

    # URL-SAFE because the token rides a PATH SEGMENT: standard base64's `/` would split it into two
    # segments and `+` would be read back as a space by anything form-decoding the path.
    def self.verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key(PURPOSE), digest: "SHA256", serializer: JSON, url_safe: true
      )
    end
  end
end
