namespace :models do
  desc "Catalogue every model-role file in the library (MODEL_CATALOG_MAX_MODELS to raise the cap)"
  task catalog: :environment do
    User.find_each do |user|
      run = Maker::ModelIntake.for_user(user:)
      puts "user #{user.id}: created #{run.created}, attached #{run.attached}, " \
           "skipped #{run.skipped} (no shelf above them), status #{run.status}"
      puts "  capped at #{run.cap} - run again to continue" if run.status == :capped
    end
  end

  # THE REPAIR HALF of the 2026-09-02 attach-rule change. `models:catalog` only ever INSERTS, so a
  # tightened rule cannot undo what the loose one wrote -- see Maker::ModelIntake::Prune.
  #
  # DRY BY DEFAULT. `APPLY=1` is the only thing that writes, and the dry run prints the same list,
  # so an operator sees the damage before authorising it.
  desc "Remove what an older model-catalog rule attached and the current one does not claim " \
       "(dry run; APPLY=1 to write)"
  task prune: :environment do
    apply = ENV["APPLY"].present?
    puts(apply ? "APPLYING." : "DRY RUN - re-run with APPLY=1 to write.")
    User.find_each do |user|
      run = Maker::ModelIntake::Prune.for_user(user:, apply:)
      next unless run.any?

      puts "user #{user.id}:"
      run.destroyed.each { |m| puts "  destroy model #{m.title.inspect} (a project or import claims its folder)" }
      run.detached.each { |m, n| puts "  detach #{n} file#{'s' if n != 1} from #{m.title.inspect}" }
    end
  end
end
