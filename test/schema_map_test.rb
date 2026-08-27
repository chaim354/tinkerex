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
  #
  # `users.email` is here because it is BADGED: `data` gives it "u" and "ix", so this is the one
  # assertion that can tell the parse result from the page's copy of it. Every other column below
  # is badge-free and reads identically either way, which is what let `annotate` badge the memoized
  # parse in place for as long as it did — the assertions could not fail for the reason they exist,
  # and whether they saw a clean hash came down to the minitest seed. Do not "simplify" it away.
  test "columns keep their type, nullability and default through the parse" do
    assert_equal({ "n" => "email", "t" => "string", "req" => true }, column("users", "email"))
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
    # Badges are APPENDED to a COPY of the parse result (lib/schema_map.rb, `annotate`), and
    # `JSON.generate` emits keys in insertion order, so this key list IS the page's bytes stated as
    # a shape — the same column the parse test above asserts, plus exactly what `data` adds. It is
    # what makes the copy equivalent to the in-place badging it replaced, and unlike the stale-page
    # test above it cannot be answered by regenerating the map.
    assert_equal %w[n t req u ix], rendered_column("users", "email").keys
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

  # Correction, 2026-08-20: this map used to draw both columns as edges into `versions.version_id`
  # ("pinned" / "rendered from"), which was factually wrong on two of three deployments -- the
  # column is a backend-polymorphic content_token (a real version UUID on chunk, a content hash on
  # share/s3; see the comment beside their entries in SchemaMap::EDGES and FileLayer::FileInfo).
  # `problems` cannot catch a reintroduction of this: `versions.version_id` is a real column, so a
  # revived edge would parse cleanly and pass every check that method runs. This is the only guard
  # against it coming back.
  test "the two maker version_id columns are not drawn as edges into versions" do
    refute SchemaMap::EDGES.any? { |from, to, _k, _l|
      %w[maker_file_attachments.version_id maker_previews.version_id].include?(from) &&
        to == "versions.version_id"
    }
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
