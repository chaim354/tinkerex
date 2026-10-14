module Tinkerex
  # THE PUBLIC DEMO'S NIGHTLY RESET: whatever a day of visitors did to the shared demo account is
  # destroyed, and the committed seed set (db/seeds/demo) is written back, so the next visitor finds
  # exactly what the first one did. Run by Tinkerex::DemoResetJob at 04:00 UTC and by
  # `bin/rails tinkerex:demo:setup` / `tinkerex:demo:reset`; the user is injected, so nothing here
  # reads DEMO_ACCOUNT_EMAIL.
  #
  # THE PHASES, each logged in one line carrying "DemoReset" (what the morning-after check greps for):
  #
  #   1. DELETE every live top-level node THROUGH THE PORT. A directory delete cascades on every
  #      backend (§14a), so a handful of calls empties the library while the catalog and the store
  #      stay agreed — the tombstones are trash tombstones, never paths a scan could revive.
  #   2. RECREATE THE ACCOUNT: destroy the row (the User model's `dependent:` chain IS the tenant
  #      cleanup — projects, notes, devices, previews, every maker_* row) and create a fresh one with
  #      the same address, the handle `demo`, a password nobody is told, and `confirmed_at` set. A new
  #      id is also what signs out every visitor holding the old one. One transaction, so a create
  #      that fails leaves the old row for the next night rather than no account at all.
  #   3. WRITE THE SEED through `mkdir` + `write`, parents first, so every node is born with the path
  #      and content facts the scan will agree with.
  #   4. SCAN (Library::ScanJob, inline), whose post-reconcile sequence discovers `Projects/Desk Lamp`
  #      as a project and sweeps its folder — and then queue the thumbnails the upload door would have:
  #      a port write is not an upload, and the scan sees these files as unchanged, so nothing else
  #      ever would.
  #   5. PURGE THE TRASH the deletes filled, with an explicit cutoff — never the env-driven job, whose
  #      LIBRARY_TRASH_DAYS=0 means keep forever and whose smallest window is a whole day.
  #
  # THE PURGE IS LAST, NOT SECOND, and that is a deliberate departure from the plan's listing (no
  # phase reads the trash, and neither observer looks inside it, so the order is free): a purge that
  # fails — an S3 listing cut short is the realistic case — then fails a reset that has already put
  # the demo back, rather than one that has emptied the library and stopped.
  #
  # NOTHING IS TOUCHED UNTIL `.refusal` HAS ANSWERED NIL — see it for the four ways it says no.
  class DemoReset
    Refused = Class.new(StandardError)

    HANDLE = "demo".freeze
    DEFAULT_SEED_DIR = Rails.root.join("db/seeds/demo").freeze

    # THE PURGE'S CUTOFF IS NOW PLUS THIS, NOT NOW. The reaper keeps an entry unless it is OLDER than
    # the cutoff (`<`), and the entries this reset made seconds ago were stamped by the STORE's clock
    # — an S3 Last-Modified, a NAS's mtime over SMB/NFS — not by ours. With a cutoff of exactly now, a
    # store whose clock runs a second ahead keeps the very entries the reset exists to clear. Nothing
    # in the trash is meant to survive a reset, so the slack costs nothing.
    PURGE_CLOCK_SLACK = 1.hour

    # The one definition of what the demo account is. tinkerex:demo:setup mints it once; every reset
    # mints it again.
    def self.create_account!(email)
      User.create!(email:, handle: HANDLE, password: SecureRandom.base58(32), confirmed_at: Time.current)
    end

    # NIL, OR THE SENTENCE A REFUSAL CARRIES — every reason a reset must not start, asked before it
    # touches anything, and asked WITHOUT the demo account so tinkerex:demo:setup can ask it before
    # minting one. Cheapest first:
    #
    #   - the seed directory is missing, or holds no file (folders and OS clutter are nothing to seed);
    #   - the port is neither share nor s3. chunk_remote has no byte write and no trash of this app's
    #     (the sync server owns both), so the reset would delete the library and then fail to put
    #     anything back. A dispatch that refuses, like Library::ScanJob's observer_for, not a gate
    #     that skips;
    #   - THE LIBRARY IS SHARED. A port with no sync server behind it (`syncable?` false: share, s3)
    #     addresses one root or bucket prefix with no user segment, and Library::ScanJob.scan_all!
    #     indexes it into EVERY account's catalog — the reason REGISTRATION=open is refused there
    #     (Tinkerex::Registration). The demo account's library is then everyone's library, and
    #     phase 1 would delete, and phase 5 purge, every other account's files. So a reset there
    #     runs only while the demo account is the deployment's only account. `except:` is that
    #     account; nil (setup, before minting) counts every account.
    def self.refusal(seed_dir: DEFAULT_SEED_DIR, except: nil, port: FileLayer.current)
      seed_dir = Pathname.new(seed_dir)
      return "the demo seed directory #{seed_dir} does not exist; nothing was changed" unless seed_dir.directory?
      if seed_entries(seed_dir).none? { |_rel, path| path.file? }
        return "the demo seed directory #{seed_dir} holds no files to seed the library with; nothing " \
               "was changed"
      end
      unless port.is_a?(FileLayer::Share) || port.is_a?(FileLayer::S3)
        return "the demo reset rebuilds the library through the port's byte write and empties its " \
               "trash, which only a share or s3 library has; #{port.class} has neither, so nothing " \
               "was changed"
      end

      others = accounts_sharing_library(except:, port:)
      return nil if others.zero?

      "the demo would wipe a library #{others} other #{others == 1 ? 'account shares' : 'accounts share'}: " \
        "on share and s3 every account indexes the one library, so the reset's delete would take " \
        "their files too. Remove the other accounts, or give the demo a deployment of its own; " \
        "nothing was changed"
    end

    # How many accounts besides `except` index the same library — 0 behind a sync server
    # (`syncable?`: chunk_remote, where every account has its own remote library), every other
    # account on share and s3, whose port has no user segment at all.
    def self.accounts_sharing_library(except: nil, port: FileLayer.current)
      return 0 if port.capabilities.syncable?

      User.where.not(id: except&.id).count
    end

    # [relative path, Pathname] for every folder and file in the seed, parents before their children,
    # in name order. OS clutter (.DS_Store, AppleDouble) is skipped as the scan skips it: the port
    # refuses those names, and a Finder visit to db/seeds/demo must not break the reset.
    def self.seed_entries(dir, prefix = nil)
      dir.children.sort.flat_map do |child|
        name = child.basename.to_s
        next [] if Library::OsClutter.clutter_segment?(name)

        rel = prefix ? "#{prefix}/#{name}" : name
        if child.directory? then [ [ rel, child ] ] + seed_entries(child, rel)
        elsif child.file? then [ [ rel, child ] ]
        else []
        end
      end
    end

    def initialize(user:, seed_dir: DEFAULT_SEED_DIR)
      @user = user
      @seed_dir = Pathname.new(seed_dir)
    end

    # Returns the NEW user — the injected one no longer exists.
    def call
      @port = FileLayer.current
      why = self.class.refusal(seed_dir: @seed_dir, except: @user, port: @port)
      raise Refused, why if why

      entries = self.class.seed_entries(@seed_dir)
      delete_library!
      user = recreate_account!
      write_seed!(user, entries)
      scan!(user)
      purge_trash!
      user
    end

    private

    def log(message) = Rails.logger.info("Tinkerex::DemoReset: #{message}")

    def delete_library!
      top = @user.nodes.present.where(parent_node_id: nil).order(:name).pluck(:node_id)
      top.each { |node_id| @port.delete(@user, node_id:) }
      log "deleted #{top.size} top-level entries from #{@user.email}'s library (user #{@user.id})"
    end

    def recreate_account!
      email = @user.email
      old_id = @user.id
      fresh = User.transaction do
        @user.destroy!
        self.class.create_account!(email)
      end
      log "recreated #{email} as user #{fresh.id} (was #{old_id})"
      fresh
    end

    def write_seed!(user, entries)
      folders = { "." => nil }
      entries.each do |rel, path|
        parent_node_id = folders.fetch(File.dirname(rel))
        name = File.basename(rel)
        if path.directory?
          folders[rel] = @port.mkdir(user, parent_node_id:, name:).node_id
        else
          path.open("rb") { |io| @port.write(user, parent_node_id:, name:, io:) }
        end
      end
      log "wrote #{entries.count { |_rel, path| path.file? }} files and #{folders.size - 1} folders " \
          "from #{@seed_dir}"
    end

    def scan!(user)
      Library::ScanJob.perform_now(user_id: user.id)
      queued = Maker::Previews::MissingBackfill.call(user:)
      log "scanned user #{user.id}'s library: projects #{user.maker_projects.pluck(:name).inspect}, " \
          "#{queued} thumbnails queued"
    end

    # Library::TrashPurgeJob's two reapers, reached directly with this reset's own cutoff. Its
    # `#perform` cannot be the door: it takes whole DAYS and refuses 0 ("keep forever"), so the
    # newest entry it can purge is a day old. The reapers are private to that job and the job's file
    # is not this change's, so `send` it is; `.refusal` has already confined the port to the two
    # adapters the job has a reaper for.
    def purge_trash!
      job = Library::TrashPurgeJob.new
      cutoff = Time.current + PURGE_CLOCK_SLACK
      purged =
        if @port.is_a?(FileLayer::S3)
          job.send(:purge_s3!, @port, cutoff)
        else
          job.send(:purge_share!, @port.root, cutoff)
        end
      log "purged #{purged.to_i} trash entries"
    end
  end
end
