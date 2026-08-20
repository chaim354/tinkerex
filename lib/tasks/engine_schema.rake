# frozen_string_literal: true

namespace :engine_schema do
  desc "Regenerate db/engine_schema.rb -- the sync engine's draft consolidated migration -- from db/schema.rb"
  task generate: :environment do
    was = EngineSchema.output_path.exist? ? EngineSchema.output_path.read : nil
    path = EngineSchema.write!
    changed = was != path.read

    puts "#{changed ? "rewrote" : "unchanged"} #{EngineSchema::OUTPUT}"
    puts "  #{EngineSchema.tables.size} tables: #{EngineSchema.tables.join(", ")}"
  end

  desc "Report whether db/engine_schema.rb is still the current schema, without rewriting it"
  task check: :environment do
    abort "#{EngineSchema::OUTPUT} is stale -- run `bin/rails engine_schema:generate`." unless EngineSchema.current?
    puts "#{EngineSchema::OUTPUT} is current."
  end
end
