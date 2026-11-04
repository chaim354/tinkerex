# frozen_string_literal: true

module McpServer
  # THE ONE PLACE A ROW IS SHAPED FOR AN LLM (spec §3). Names and paths over bare ids where a name
  # exists, ISO-8601 UTC times, floats for the decimal columns, nothing a model has to join by hand.
  # Every method takes what it renders already LOADED -- `tree:` is the one Maker::LibraryTree the
  # tool built, `open_tasks:` a count the tool grouped, `project:` the project a task's caller
  # already holds -- so rendering N rows adds no query (test/integration/mcp/query_budget_test.rb).
  module Render
    module_function

    def time(t) = t&.utc&.iso8601
    def number(d) = d&.to_f

    # `nodes.mtime` is unix NANOSECONDS (FileLayer::FileInfo), never seconds.
    def mtime(nanos) = nanos && Time.at(Rational(nanos, 1_000_000_000)).utc.iso8601

    def project(p, tree:, open_tasks: nil)
      { slug: p.slug, name: p.name, status: p.status, kind: p.kind, visibility: p.visibility,
        folder: folder_path(p, tree), open_tasks: open_tasks, updated_at: time(p.updated_at) }.compact
    end

    # nil when the project has no folder yet, or its folder is in the trash (a broken chain):
    # Maker::Project#ensure_library_folder!'s "nil is part of the contract".
    def folder_path(p, tree) = p.folder_node_id.presence && tree.path_for(p.folder_node_id)

    # `project:` defaults to the task's own taskable, evaluated only when not given, so a caller
    # holding the project passes it and pays no query; ListTasks preloads taskable instead.
    def task(t, project: t.taskable)
      { id: t.id, title: t.title, status: t.status, notes: t.notes, position: t.position,
        project: (project.slug if project.is_a?(Maker::Project)),
        completed_at: time(t.completed_at), updated_at: time(t.updated_at) }
    end

    def entry(e)
      { id: e.id, entry_type: e.entry_type, logged_at: time(e.logged_at), body: e.body.to_plain_text }
    end

    def item(i, full: false)
      base = { id: i.id, name: i.name, part_number: i.part_number, category: i.category,
               quantity: number(i.quantity_cached), unit: i.unit, min_quantity: number(i.min_quantity),
               low_stock: i.low_stock?, location: i.location&.name, supplier: i.supplier&.name }
      return base unless full

      base.merge(unit_cost: number(i.unit_cost), notes: i.notes, location_id: i.location_id,
                 supplier_id: i.supplier_id, updated_at: time(i.updated_at))
    end

    def transaction(t)
      { id: t.id, delta: number(t.delta), reason: t.reason, note: t.note, project_id: t.project_id,
        at: time(t.created_at) }
    end

    def bom(b, lines: nil) = { id: b.id, name: b.name, revision: b.revision, lines: lines }.compact

    def line(l)
      item = (l.inventory_item if l.target_kind == :inventory_item)
      { id: l.id, reference: l.reference, quantity: number(l.quantity), unit: l.unit, kind: l.target_kind,
        item: item && { id: item.id, name: item.name, on_hand: number(item.quantity_cached) },
        part_name: l.part_name, node_id: l.node_id, supplier: l.supplier&.name, notes: l.notes }
    end

    def supplier(s) = { id: s.id, name: s.name, url: s.url, notes: s.notes }

    def location(l)
      { id: l.id, name: l.name, parent_id: l.parent_id, parent: l.parent&.name, description: l.description }
    end

    # `path:` is computed by the caller (LibraryPath), who knows the folder it listed.
    def node(n, path:)
      { name: n.name, kind: n.kind, path: path, node_id: n.node_id, size: n.size, modified_at: mtime(n.mtime),
        text: n.file? && Maker::FileAttachment.text?(n.name) }
    end
  end
end
