require "test_helper"

# Guards `docs/schema-map.html` — a GENERATED document checked into a directory of hand-written
# ones, which is a shape that goes stale silently by construction. Nothing in `bin/ci` reads a
# `docs/` file, so without this the map would go on describing whatever schema was current the
# day someone last ran the task (CLAUDE.md §15, "Keeping the docs honest").
#
# Two different failures, deliberately kept apart:
#
#   * SchemaMap's AUTHORED half disagreeing with the schema — a renamed column, a new foreign
#     key, a new table with nowhere to sit. A person must resolve those, so `problems` returns
#     sentences rather than a boolean.
#   * The checked-in PAGE being behind the generator. One command fixes that, and the test says
#     which command.
#
# What this canNOT see is stated in lib/schema_map.rb: a new app-level reference nobody draws.
# There is no constraint to notice it by.
class SchemaMapTest < ActiveSupport::TestCase
  test "every relationship the map draws still matches the schema it claims to describe" do
    # Each entry is already a sentence naming the table and the fix, so print them as-is.
    assert_equal [], SchemaMap.problems, "\n" + SchemaMap.problems.map { |p| "  - #{p}" }.join("\n")
  end

  test "the checked-in map is the current schema" do
    assert SchemaMap.output_path.exist?, "#{SchemaMap::OUTPUT} is missing — run `bin/rails schema:map`"
    current = SchemaMap.output_path.read
    return if current == SchemaMap.render

    # Naming WHICH half moved saves the next reader a bisect: the data blob is embedded verbatim,
    # so a page still carrying today's payload can only differ in its template. "Data" means the
    # schema OR the authored edges -- both feed the payload, and the page cannot tell them apart.
    why = current.include?(SchemaMap.payload) ? "only its template moved" : "its data moved"
    flunk "#{SchemaMap::OUTPUT} is stale (#{why}) — run `bin/rails schema:map`"
  end

  # The test above answers a stale page with "regenerate", which would happily bake a PARSER bug
  # into the map and call it current. These pin the meaning of what is parsed instead: one column
  # per branch of the dump reader — plain, nullable, defaulted, precision/scale, and limit.
  test "columns keep their type, nullability and default through the parse" do
    assert_equal({ "n" => "content_hash", "t" => "string" }, column("nodes", "content_hash"))
    assert_equal({ "n" => "deleted", "t" => "boolean", "req" => true, "d" => "false" },
                 column("nodes", "deleted"))
    assert_equal({ "n" => "quantity", "t" => "decimal(12,3)", "req" => true, "d" => "1.0" },
                 column("maker_bom_lines", "quantity"))
    assert_equal({ "n" => "key", "t" => "binary(1024)", "req" => true },
                 column("solid_cache_entries", "key"))
    assert_equal({ "n" => "data", "t" => "json", "req" => true, "d" => "{}" },
                 column("maker_addon_states", "data"))
  end

  test "the page carries an implicit primary key and the index badges the dump only implies" do
    id = rendered_column("nodes", "id")
    assert_equal({ "n" => "id", "t" => "bigint", "req" => true, "pk" => true }, id)

    # A single-column unique index is a badge; a composite one names its partners instead.
    assert rendered_column("users", "email")["u"]
    assert_equal "user_id, storage_path", rendered_column("nodes", "storage_path")["cu"]

    # `node_id` is not a primary key anywhere, and is what half the maker layer points at.
    assert rendered_column("nodes", "node_id")["key"]
    assert rendered_column("maker_previews", "node_id")["ref"]
  end

  test "every user-scoped table gets an ownership edge, derived rather than listed" do
    scoped = SchemaMap.tables.filter_map { |t|
      t["name"] if t["name"] != "users" && t["columns"].any? { |c| c["n"] == "user_id" }
    }
    drawn = SchemaMap.edges.filter_map { |e| e["f"].split(".").first if e["k"] == "tenant" }
    assert_equal scoped.sort, drawn.sort
    # Listing them by hand in EDGES would pass the line above on the day it was written and rot
    # the first time a user-scoped table is added, so pin that none of them is authored.
    assert_empty SchemaMap::EDGES.select { |_f, to, _k, _l| to == "users.id" }
  end

  private

  def column(table, name)
    SchemaMap.tables.find { |t| t["name"] == table }["columns"].find { |c| c["n"] == name }
  end

  # The same column as the page draws it: annotated with the badges `data` computes.
  def rendered_column(table, name)
    SchemaMap.data["tables"].find { |t| t["name"] == table }["columns"].find { |c| c["n"] == name }
  end
end
