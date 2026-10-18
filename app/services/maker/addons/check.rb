module Maker
  module Addons
    # WHAT `bin/rails "addons:check[PATH]"` RUNS — and tinkerex-addons' bin/publish runs it for the
    # author before a bundle ships. Two halves:
    #
    #   - `Registry.problems` — the host's OWN definition of a skipped manifest, never a second copy
    #     (a validator in the addons repo would drift from the rules this host enforces).
    #   - checks only a directory on disk can answer, for each manifest that would build: its
    #     `<key>/` folder, its `entry` and every `pins` file exist AND RESOLVE INSIDE PATH. Over HTTP
    #     these would be a request per file, which is why they live here and not in Registry.
    #
    # THE KEY IS ONE PATH SEGMENT, REFUSED BEFORE ANY JOIN, AND NOTHING MAY RESOLVE OUTSIDE PATH.
    # `/tools/:key` is one URL segment and `<key>/` one folder, but Registry never validated `key`,
    # so `../elsewhere` or an absolute key made this check stat files outside PATH and pass a tool
    # the host can never serve; it is refused HERE, because refusing it in Registry would change
    # what production serves. Symlinks are compared by realpath on BOTH sides (macOS's /var is itself
    # a link): one that stays inside PATH is fine, one reaching outside is refused, because Docker's
    # COPY carries a link as a link — in the addons image it dangles and the host 404s a file this
    # check saw exist.
    #
    # READS PATH THROUGH Source::Local, NEVER Source.current: a check must not touch the network, a
    # cache, or whichever source this process happens to be configured with.
    class Check
      Result = Data.define(:count, :problems) do
        def ok? = problems.empty?
      end

      KEY_REASON = "key must be a single path segment (it becomes /tools/<key> and the <key>/ folder)"

      def self.run(path) = new(path).run

      def initialize(path) = @root = Pathname.new(path.to_s)

      def run
        raise Source::Error, "#{@root} is not a directory" unless @root.directory?

        @real_root = @root.realpath
        index = Source::Local.new(@root).manifests
        file_problems = index.filter_map { |m| Registry.build(m) }.flat_map { |addon| files_for(addon) }
        Result.new(count: index.size, problems: Registry.problems(index) + file_problems)
      end

      private

      def files_for(addon)
        key = addon.key
        return [ { key:, reason: KEY_REASON } ] unless segment?(key)
        unless routable?(key)
          return [ { key:, reason: "/tools/#{key} does not reach this tool — the host routes that URL elsewhere" } ]
        end

        dir = @root.join(key)
        return [ { key:, reason: "no #{key}/ directory beside manifests.json" } ] unless dir.directory?
        return [ { key:, reason: "#{key}/ #{outside}" } ] unless inside?(dir)

        { "entry" => addon.entry }.merge(addon.pins.to_h { |spec, file| [ "pin #{spec.to_s.inspect}", file ] })
                                  .filter_map do |label, file|
          reason = file_problem(dir, file.to_s)
          { key:, reason: "#{label}: #{reason}" } if reason
        end
      end

      def segment?(key) = !key.empty? && !key.include?("/") && !key.include?("\0") && !%w[. ..].include?(key)

      # THE ROUTER DECIDES WHETHER /tools/<key> REACHES THIS TOOL — never a list of reserved names
      # here, which would drift the day a route is added. A key the router splits (`a.b` -> key "a",
      # format "b") or an earlier route shadows (`new_menu`) builds, lists and links fine, then opens
      # a different page. Asked of the real route set, so it answers for exactly this host.
      def routable?(key)
        route = Rails.application.routes.recognize_path("/tools/#{ERB::Util.url_encode(key)}")
        route[:controller] == "tools/addons" && route[:action] == "show" && route[:key] == key
      rescue ActionController::RoutingError
        false
      end

      # REJECT, NEVER NORMALIZE — the same guard the asset proxy uses, so a path this check passes is
      # one the host will actually serve.
      def file_problem(dir, file)
        Source.validate_asset_path!(file)
        return "#{file} does not exist" unless dir.join(file).file?

        "#{file} #{outside}" unless inside?(dir.join(file))
      rescue Source::Error => e
        "#{file} is not a safe path (#{e.message})"
      end

      def inside?(path) = path.realpath.ascend.include?(@real_root)

      def outside = "resolves outside #{@root} (a symlink the image would not carry)"
    end
  end
end
