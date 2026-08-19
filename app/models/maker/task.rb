module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES = %w[todo doing done].freeze

    # ONE MAP, AND `TASKABLE_TYPES` IS DERIVED FROM ITS KEYS — because these were two independent
    # enumerations of one set (an array here, a `case` in the validation 17 lines below) with
    # nothing linking them, and the split failed **OPEN**: `taskable_belongs_to_owner` resolved its
    # owner class from that `case` and then `return unless owner_class`, so a type the `case` did
    # not name got **NO TENANT CHECK AT ALL**. Probed directly: `Maker::Project` ran the check and
    # a third type ran nothing, i.e. A could point a task at B's row. **The edit that opens it is
    # adding one string to `TASKABLE_TYPES`** — and nothing would have gone red, because the
    # `inclusion:` validation below held the hole shut for exactly as long as the two lists agreed.
    # Derived from the keys, a split is no longer expressible.
    #
    # A MAP, NOT `taskable_type.constantize`: the string is allowlisted before it is resolved, so
    # `constantize` would not be a *security* hazard here — but it turns a typo in a constant name
    # into a runtime `NameError` on a user request, whereas a map cannot be extended without
    # supplying a class.
    #
    # **DECLARATION ORDER IS LOAD-BEARING.** `inclusion: { in: TASKABLE_TYPES }` captures the ARRAY
    # OBJECT at declaration time — verified by `const_set`-ing a replacement at runtime and watching
    # the validator go on reading the old one — so this must stay ABOVE the validation.
    #
    # Naming the classes in the class body forces their autoload here; `bin/rails zeitwerk:check`
    # is the thing that proves that is safe.
    TASKABLE_OWNERS = {
      "Maker::Item"    => Maker::Item,
      "Maker::Project" => Maker::Project
    }.freeze
    TASKABLE_TYPES = TASKABLE_OWNERS.keys.freeze

    validates :title, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :taskable_type, inclusion: { in: TASKABLE_TYPES }, allow_nil: true
    validate  :taskable_belongs_to_owner, if: -> { taskable_id.present? }

    scope :open, -> { where.not(status: "done") }

    def complete!
      update!(status: "done", completed_at: Time.current)
    end

    private

    # FAILS CLOSED ONLY FOR A TYPE THAT IS **PRESENT**, and the exemption is not a softening — the
    # naive "fail closed on anything unresolvable" walks straight into §14d's dangling-id lock. A
    # row carrying a `taskable_id` with a NULL `taskable_type` is reachable through the v1 API
    # today (probed: `POST /v1/maker/tasks {title, taskable_id}` answers **201** with
    # `taskable_type: null`, and the follow-up PATCH answers **200**) because `taskable_type` is
    # `allow_nil: true`, this check is guarded on `taskable_id.present?`, and `task_params` permits
    # the two columns independently. Refuse it and every such row becomes **permanently
    # unsaveable** — its owner cannot even rename it. A blank type means `taskable` is nil: there is
    # no owner to check and nothing to leak, so there is nothing for a refusal to protect.
    #
    # Do not chase the half-orphan state itself from here; this method's job is only to not lock it.
    def taskable_belongs_to_owner
      owner_class = TASKABLE_OWNERS[taskable_type]
      if owner_class.nil?
        return if taskable_type.blank?

        return errors.add(:taskable_type, "is not a valid task owner")
      end

      unless owner_class.exists?(id: taskable_id, user_id: user_id)
        errors.add(:taskable_id, "must reference your own #{owner_class.model_name.element}")
      end
    end
  end
end
