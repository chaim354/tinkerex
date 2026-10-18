module Maker
  module Addons
    # WHAT `bin/rails "addons:check[PATH]"` RUNS — and tinkerex-addons' bin/publish runs it for the
    # author before a bundle ships. Two halves:
    #
    #   - `Registry.problems` — the host's OWN definition of a skipped manifest, never a second copy
    #     (a validator in the addons repo would drift from the rules this host enforces).
    #   - three checks only a directory on disk can answer, for each manifest that would build: its
    #     `<key>/` folder, its `entry` and every `pins` file exist. Over HTTP these would be a request
    #     per file, which is why they live here and not in Registry.
    #
    # READS PATH THROUGH Source::Local, NEVER Source.current: a check must not touch the network, a
    # cache, or whichever source this process happens to be configured with.
    class Check
      Result = Data.define(:count, :problems) do
        def ok? = problems.empty?
      end

      def self.run(path) = new(path).run

      def initialize(path) = @root = Pathname.new(path.to_s)

      def run
        raise Source::Error, "#{@root} is not a directory" unless @root.directory?

        index = Source::Local.new(@root).manifests
        file_problems = index.filter_map { |m| Registry.build(m) }.flat_map { |addon| files_for(addon) }
        Result.new(count: index.size, problems: Registry.problems(index) + file_problems)
      end

      private

      def files_for(addon)
        dir = @root.join(addon.key)
        return [ { key: addon.key, reason: "no #{addon.key}/ directory beside manifests.json" } ] unless dir.directory?

        { "entry" => addon.entry }.merge(addon.pins.to_h { |spec, file| [ "pin #{spec.to_s.inspect}", file ] })
                                  .filter_map do |label, file|
          reason = missing(dir, file.to_s)
          { key: addon.key, reason: "#{label}: #{reason}" } if reason
        end
      end

      # REJECT, NEVER NORMALIZE — the same guard the asset proxy uses, so a path this check passes is
      # one the host will actually serve.
      def missing(dir, file)
        Source.validate_asset_path!(file)
        "#{file} does not exist" unless dir.join(file).file?
      rescue Source::Error => e
        "#{file} is not a safe path (#{e.message})"
      end
    end
  end
end
