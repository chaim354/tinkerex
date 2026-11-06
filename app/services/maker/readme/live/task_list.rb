module Maker
  class Readme
    module Live
      # `tasks` (spec §4): a GFM task list in position order — `- [x]` done, `- [ ]` open, a "doing"
      # task open and marked. kramdown's GFM parser renders these as disabled checkboxes (probed).
      module TaskList
        def self.call(_args, context:, mode:)
          tasks = context.tasks
          return Live.note("No tasks yet.") if tasks.empty?

          tasks.map do |task|
            box = task.status == "done" ? "x" : " "
            "- [#{box}] #{Live.cell(task.title)}#{' *(doing)*' if task.status == 'doing'}"
          end.join("\n")
        end
      end
    end
  end
end
