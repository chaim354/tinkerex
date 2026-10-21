module Maker
  # A MODEL'S "IN PROJECTS" ROW (2026-10-21; docs/superpowers/specs/
  # 2026-10-20-attach-model-to-project-design.md) — FilesController#attach_choices_for's two halves,
  # for a whole model: what it is already in, and what it could be attached to.
  #
  #   located   — the project whose folder holds the model (Maker::ModelProjects, the answer the
  #               3D models view groups by), or nil. A chip with no ×: it is the project's by where
  #               it is.
  #   linked    — non-archived projects holding an attachment row for any of the model's files —
  #               what a bundle attach writes — minus the located one. A chip with ×.
  #   available — every other non-archived project, for the dropdown.
  #
  # Archived projects are left out of `linked` and `available` as files/_attach leaves them out;
  # `located` keeps one, because an archived project still claims its folder.
  # Sorted by FilesController#name_key's rule. Constant in query count.
  class ModelProjectChoices
    Choices = Data.define(:located, :linked, :available)

    def self.for(user, model)
      located = Maker::ModelProjects.group(user, [ model ]).first&.project
      node_ids = model.file_attachments.map(&:node_id)
      linked_ids = if node_ids.empty?
        []
      else
        user.maker_file_attachments.where(attachable_type: "Maker::Project", node_id: node_ids)
            .distinct.pluck(:attachable_id)
      end
      open = user.maker_projects.where.not(status: "archived").to_a.reject { |p| p.id == located&.id }
      linked, available = open.partition { |p| linked_ids.include?(p.id) }
      Choices.new(located:, linked: by_name(linked), available: by_name(available))
    end

    def self.by_name(projects) = projects.sort_by { |p| [ p.name.downcase, p.name ] }
    private_class_method :by_name
  end
end
