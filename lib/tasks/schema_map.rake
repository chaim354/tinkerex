# frozen_string_literal: true

namespace :schema do
  desc "Regenerate docs/schema-map.html from the four schema dumps (every table, column and relationship)"
  task map: :environment do
    problems = SchemaMap.problems
    if problems.any?
      warn "The schema has moved and SchemaMap's authored half has not:"
      problems.each { |p| warn "  - #{p}" }
      warn "\nEdit lib/schema_map.rb (LAYOUT and EDGES), then run this again."
      abort
    end

    was = SchemaMap.output_path.exist? ? SchemaMap.output_path.read : nil
    path = SchemaMap.write!
    data = SchemaMap.data
    columns = data["tables"].sum { |t| t["columns"].size }
    databases = data["tables"].map { |t| t["db"] }.uniq.size

    puts "#{was == path.read ? 'unchanged' : 'rewrote'} #{SchemaMap::OUTPUT}"
    puts "  #{data['tables'].size} tables, #{columns} columns, " \
         "#{data['edges'].size} relationships, #{databases} databases"
  end

  namespace :map do
    desc "Report whether docs/schema-map.html is still the current schema, without rewriting it"
    task check: :environment do
      problems = SchemaMap.problems
      problems.each { |p| warn "  - #{p}" }
      abort "SchemaMap's authored half disagrees with the schema (above)." if problems.any?
      abort "docs/schema-map.html is stale — run `bin/rails schema:map`." unless SchemaMap.current?
      puts "docs/schema-map.html is current."
    end
  end
end
