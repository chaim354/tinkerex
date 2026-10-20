module Tinkerex
  # THE LIBRARY FOLDER IS THE MOUNT PLUS A STORED CHOICE INSIDE IT (K, 2026-10-20). LIBRARY_PATH is
  # the MOUNT -- what compose bound to /library and what the boot guard probes; the `library.root`
  # setting is the chosen folder RELATIVE to it ("" = the whole mount, absent = not chosen yet); the
  # share root is their join. This module is the one reader and writer of that setting, so no second
  # place joins the two halves.
  #
  # RELATIVE ON PURPOSE: the row never holds a host path, so widening or narrowing LIBRARY_HOST_PATH
  # keeps the choice meaningful or makes it visibly missing, never silently wrong.
  #
  # PENDING IS NOT A BOOT STATE. The whole mount is always a valid root, so `path` answers it while
  # nothing is chosen and FileLayer.current can always be built (the CSP header resolves it per
  # response, §14a). Pending is a fact the web layer (the redirect) and the scan schedule consult.
  #
  # EVERY PROCESS FOLLOWS A CHANGE, AT ITS NEXT REQUEST OR JOB. The setting is cached per request and
  # per job (Setting.get, Current), and the factory-built FileLayer::Share asks `path` per call
  # rather than fixing its root at construction, so nothing needs resetting when the folder changes.
  # That is not the obvious design and the obvious one was WRONG: "jobs run inside Puma" is false --
  # Solid Queue's Puma plugin forks its supervisor and workers -- so a reset in the web process left
  # every worker on the old folder until a restart (found in review). A job already running when the
  # folder changes keeps the root it started with; Library::RootChangeJob queues behind it.
  module LibraryRoot
    KEY = "library.root".freeze

    # The chooser's listing stops here and says it did; a folder of more than 500 folders is
    # navigated by narrowing the mount, not by scrolling.
    LIST_CAP = 500

    # A choice the app refuses. The message is the sentence the page shows, naming the rule.
    Invalid = Class.new(StandardError)

    Listing = Data.define(:parent, :entries, :truncated)

    def self.mount
      raw = ENV["LIBRARY_PATH"]
      Pathname.new(raw).expand_path if raw.present?
    end

    def self.relative = Setting.get(KEY)

    def self.changed_at = Setting.changed_at(KEY)

    # Asked of the ADAPTER, so a test that installs `FileLayer.current = Share.new(root:)` is a share
    # deployment here too. The chooser is a share fact by nature: s3 has a prefix and chunk_remote no
    # folder, so every gate that asks `pending?` is a no-op there.
    def self.share? = FileLayer.current.is_a?(FileLayer::Share)

    # The adapter first (memoised per process), so s3 and chunk_remote never read the setting at all;
    # on share, a chosen library then pays one memoised read and no query.
    def self.pending? = share? && relative.nil?

    # FileLayer::Share's default root. ENV.fetch, as Share always did: FileLayer.build runs
    # LibraryBackendCheck first, so a missing LIBRARY_PATH is explained before it gets here.
    def self.path
      base = Pathname.new(ENV.fetch("LIBRARY_PATH")).expand_path
      rel = relative
      rel.blank? ? base : base.join(rel)
    end

    # "No live node for any user": on share every account indexes the one library.
    def self.catalog_empty? = !Node.present.exists?

    # Validates, probes and writes the row, in that order; nothing is written unless every check
    # passed. Returns the normalised relative path. No adapter reset: the share root follows the row.
    def self.choose!(relative)
      rel, dir = resolve!(relative)
      begin
        LibraryBackendCheck.writable!(dir.to_s)
      rescue LibraryBackendCheck::Error
        raise Invalid, unwritable_message(rel)
      end
      Setting.put(KEY, rel)
      rel
    end

    # The whole mount: the console door's answer (an operator chose the mount by mounting it).
    def self.clear! = Setting.put(KEY, "")

    # One folder's subfolders, for the chooser. DIRECTORIES ONLY, by lstat -- the Scanner's own
    # dispatch, so a symlink is neither listed nor followed -- and never a name `unchoosable?` refuses.
    def self.children(parent, limit: LIST_CAP)
      rel, dir = resolve!(parent)
      names =
        begin
          Dir.children(dir.to_s)
        rescue SystemCallError => e
          raise Invalid, "#{display(rel)} cannot be listed (#{e.message})."
        end
      dirs = names.select { |name| name.valid_encoding? && !unchoosable?(name) && real_dir?(dir.join(name)) }
                  .sort_by { |name| [ name.downcase, name ] }
      Listing.new(parent: rel, entries: dirs.first(limit).map { |name| rel.empty? ? name : "#{rel}/#{name}" },
                  truncated: dirs.size > limit)
    end

    # REJECT, NEVER NORMALISE -- FileLayer::S3#key_for's rule (§14a): `a/../b` is refused, not turned
    # into `b`. Every segment is lstat'd from the mount down, so a link anywhere on the way is refused
    # by name rather than followed out of the mount. -> [normalised relative, absolute Pathname]
    def self.resolve!(relative)
      base = mount or raise Invalid, "No library folder is mounted here (LIBRARY_PATH is not set)."
      rel = relative.to_s
      raise Invalid, "That folder name is not valid text." unless rel.valid_encoding?
      return [ "", base ] if rel.empty?
      raise Invalid, "Choose a folder inside the mounted folder, not an absolute path." if rel.start_with?("/")
      raise Invalid, "That folder name is not allowed." if rel.include?("\0")

      segments = rel.split("/", -1)
      raise Invalid, "#{rel.inspect} has an empty folder name in it." if segments.any?(&:empty?)
      if segments.any? { |s| s == "." || s == ".." }
        raise Invalid, "A folder path may not step outside the mounted folder (#{rel.inspect})."
      end
      if (bad = segments.find { |s| unchoosable?(s) })
        raise Invalid, "#{bad.inspect} is hidden or reserved by the library, so it cannot be the library's folder."
      end

      dir = base
      segments.each do |segment|
        dir = dir.join(segment)
        stat =
          begin
            dir.lstat
          rescue SystemCallError
            nil
          end
        raise Invalid, "#{rel} is a link, not a folder: the library never follows links." if stat&.symlink?
        raise Invalid, "#{rel} is not a folder any more; choose again." unless stat&.directory?
      end
      [ rel, dir ]
    end

    # Never the root, never listed: a dot-folder (which covers `.trash`, `.maker-tmp-*`, `.git` and
    # every dot-named clutter), and the library's reserved names that carry no dot (`__MACOSX`).
    # Library::ReservedNames is the write doors' own predicate, so the two cannot drift.
    def self.unchoosable?(name) = name.start_with?(".") || Library::ReservedNames.reserved?(name)

    def self.real_dir?(path)
      path.lstat.directory?
    rescue SystemCallError
      false
    end
    private_class_method :real_dir?

    def self.display(rel) = rel.empty? ? "The mounted folder" : rel
    private_class_method :display

    # THE OPERATOR'S FIX, IN THE OPERATOR'S WORDS (K §4.3). bin/docker-entrypoint infers the app's
    # uid from the MOUNT's owner, so a subfolder owned by someone else is exactly this case.
    def self.unwritable_message(rel)
      "The app runs as user #{Process.uid}:#{Process.gid} and cannot write in #{display(rel)}. " \
        "On Linux, set PUID and PGID in .env to that folder's owner (stat -c '%u:%g' on the folder, " \
        "on the host) and run docker compose up -d again."
    end
    private_class_method :unwritable_message
  end
end
