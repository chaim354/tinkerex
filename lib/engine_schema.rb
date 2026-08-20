# frozen_string_literal: true

# The eight tables Stage 3b Phase B's `tinkerex-sync` gem will own: `changelog_entries`,
# `chunks`, `conflicts`, `file_locks`, `manifest_chunks`, `pending_commits`, `share_links`,
# `versions`. This app already has all eight, created piecemeal and mixed with host DDL across
# four already-applied migrations
# (`db/migrate/20260611010000_create_sync_engine.rb`,`..._add_mode_to_nodes.rb`,
# `..._add_mtime_to_nodes.rb`, `..._drop_redundant_prefix_indexes.rb`) -- see CLAUDE.md §14j and
# `docs/superpowers/plans/2026-08-20-stage-3b-extract-the-engine.md` Task 5 for why SPLITTING
# those four files was considered and rejected: rewriting migration history that has already run
# on three live Unraid backends buys a fresh host nothing it needs, and CLAUDE.md §14i's
# backup/restore rehearsal exercises real archives against a real schema.
#
# So `db/migrate/` stays exactly as it is, forever, and the engine instead ships ONE consolidated
# migration -- `db/engine_schema.rb`, generated from here -- that creates these eight tables from
# scratch for a fresh host, standard Rails-engine practice (`install:migrations` + a schema
# check). THIS app will record that migration as already-applied rather than running it, once
# Phase B mounts the gem.
#
# THE DRIFT `db/engine_schema.rb` INVITES, AND WHY IT CANNOT HAPPEN SILENTLY. It is a second
# description of these eight tables' DDL, sitting alongside the real one in `db/schema.rb` --
# exactly the two-sources-of-truth shape CLAUDE.md warns about everywhere else in this file. The
# fix is the one `lib/schema_map.rb` already uses for `docs/schema-map.html`: `db/engine_schema.rb`
# is GENERATED, never hand-edited, and `test/engine_schema_test.rb` fails the moment a fresh
# `render` stops matching what is checked in -- so a migration that touches one of these eight
# tables without a `bin/rails engine_schema:generate` run in the same commit goes RED, not
# silently stale.
#
# THE CONTENT IS EXTRACTED, NEVER RE-DERIVED. `render` copies the literal
# `create_table "name", force: :cascade do |t| ... end` block straight out of `db/schema.rb`'s
# own text for each of the eight tables, plus their trailing `add_foreign_key` lines -- it does
# not parse columns into a structure and re-render Ruby from that structure the way `SchemaMap`
# does for `docs/schema-map.html`. `SchemaMap` can afford the extra step because its output is a
# diagram, not code a person will paste into a real migration; a re-rendering step is exactly
# where a parser bug could put text in `db/engine_schema.rb` that LOOKS like a subset of
# `db/schema.rb` but silently is not. Raw extraction cannot drift from its source that way -- it
# either finds the exact block or raises.
#
# THE EIGHT TABLE NAMES ARE THEMSELVES DERIVED, from `app/models/sync/*.rb` -- Stage 3b Phase A
# Task 3 namespaced exactly these eight models under `Sync::`, and nothing else lives in that
# directory -- rather than hand-listed here a second time. A ninth engine model added later is
# picked up with no line in this file to remember to edit.
#
# WHAT THIS FILE DOES NOT SETTLE, DELIBERATELY: every one of the eight extracted
# `add_foreign_key` lines points at `users`, a HOST table the engine does not define (CLAUDE.md
# §14j; the Stage 3b plan's Task 6, "the engine must declare User, Node and Device as HOST
# REQUIREMENTS, not define them"). Whether the eventual gem migration keeps those eight lines --
# requiring a `users` table to exist before the engine's migration runs -- or whether they move
# to a host-side migration instead is Phase B's decision, not this one's. `render` reproduces
# current reality (all eight FKs present) so Phase B chooses FROM something accurate rather than
# inventing the list from scratch.
module EngineSchema
  SOURCE = "db/schema.rb"
  OUTPUT = "db/engine_schema.rb"
  MIGRATION_CLASS = "CreateSyncEngine"

  class << self
    def root = defined?(Rails) ? Rails.root : Pathname.new(File.expand_path("..", __dir__))
    def source_path = root.join(SOURCE)
    def output_path = root.join(OUTPUT)

    # The eight table names, sorted -- see the header for why this reads app/models/sync/ rather
    # than naming the tables directly.
    def tables
      @tables ||= Dir.glob(root.join("app/models/sync/*.rb")).map { |f|
        "Sync::#{File.basename(f, ".rb").camelize}".constantize.table_name
      }.sort
    end

    # Line-array assembly rather than one big interpolated heredoc, deliberately: a squiggly
    # heredoc (`<<~`) strips leading whitespace by the LEAST-indented literal line in the heredoc
    # AS WRITTEN, and an interpolated multi-line block's own indentation would be at the mercy of
    # that computation rather than the block's own content. Plain lines + `join("\n")` has no such
    # ambiguity: what is pushed is exactly what is written.
    def render
      lines = header_comment
      lines << "class #{MIGRATION_CLASS} < ActiveRecord::Migration[8.1]"
      lines << "  def change"
      tables.each do |t|
        lines.concat(indent(create_table_block(t)).lines.map { |l| l.chomp("\n") })
        lines << ""
      end
      lines.pop # the blank separator after the last create_table -- one blank belongs before the FKs, not two
      lines << ""
      tables.each { |t| foreign_key_lines(t).each { |l| lines << "    #{l.strip}" } }
      lines << "  end"
      lines << "end"
      lines.join("\n") + "\n"
    end

    def current? = output_path.exist? && output_path.read == render

    def write!
      output_path.write(render)
      output_path
    end

    private

    def header_comment
      [
        "# AUTO-GENERATED by `bin/rails engine_schema:generate` from #{SOURCE} -- do not hand-edit.",
        "# See lib/engine_schema.rb for what this file is (and is not) and why it lives outside",
        "# db/migrate/: Rails never runs it against this app. It is Stage 3b Phase B's draft of the",
        "# tinkerex-sync gem's one consolidated migration (CLAUDE.md §14j).",
        "#",
        "# Regenerate: `bin/rails engine_schema:generate`. Guarded by test/engine_schema_test.rb."
      ]
    end

    def schema_lines
      @schema_lines ||= source_path.readlines
    end

    def create_table_block(table)
      start_idx = schema_lines.index { |l| l.match?(/^\s*create_table\s+"#{Regexp.escape(table)}"/) }
      raise "#{SOURCE} has no create_table \"#{table}\"" unless start_idx

      end_idx = ((start_idx + 1)...schema_lines.size).find { |i| schema_lines[i] == "  end\n" }
      raise "#{SOURCE}'s create_table \"#{table}\" block never closes" unless end_idx

      schema_lines[start_idx..end_idx].join
    end

    def foreign_key_lines(table)
      schema_lines.select { |l| l.match?(/^\s*add_foreign_key\s+"#{Regexp.escape(table)}",/) }
    end

    # Every extracted line sits at db/schema.rb's own 2-space indent (inside `...define(...) do`);
    # nested one level deeper inside `def change` needs 4. Blank lines stay blank.
    def indent(block)
      block.lines.map { |l| l == "\n" ? l : "  #{l}" }.join
    end
  end
end
