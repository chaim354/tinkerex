# HOME'S NUMBERED SECTIONS (Shop manual spec §7, slice 7): one list, read by the page and by its
# left column, so a section's number in the column is the number over the section on the page. The
# order is the page's own reading order — the left stack, then the right — and a section that has
# nothing to show is not numbered, so the numbers run 1, 2, 3 with no gap whatever is absent.
#
# CARRY ON (each open project's next step, spec §9) heads the left stack, above Active projects, so
# it takes the first number whenever it has a row.
module HomeHelper
  HomeSection = Struct.new(:key, :label, :id, :count, :number, :column, keyword_init: true)

  # The sections HomeController#index has something for, numbered. Only on that page: the
  # onboarding wizard is Home's too and renders none of them.
  def home_sections
    return [] unless controller_path == "home" && action_name == "index"

    @home_sections ||= begin
      sections = []
      if @carry_on.any?
        sections << HomeSection.new(key: :carry_on, label: "Carry on", id: "home-carry-on",
                                    count: @carry_on.size, column: :left)
      end
      if @recent_projects.any?
        sections << HomeSection.new(key: :projects, label: "Active projects", id: "home-projects",
                                    count: @recent_projects.size, column: :left)
      end
      attention = @failed_prints.size + @low_stock.size + Array(@tidy_attention).size
      if attention.positive?
        sections << HomeSection.new(key: :attention, label: "Needs attention", id: "home-attention",
                                    count: attention, column: :right)
      end
      sections << (
        if @recent_files.empty?
          HomeSection.new(key: :getting_started, label: "Getting started", id: "home-getting-started", column: :right)
        else
          HomeSection.new(key: :recent, label: "Recently changed", id: "home-recent", count: @recent_files.size, column: :right)
        end
      )
      sections.each_with_index { |section, i| section.number = i + 1 }
    end
  end

  def home_section(key) = home_sections.find { |section| section.key == key }

  # THE LEAD, FROM WHAT THE PAGE ALREADY LOADED (spec §5's lead paragraph). Every list here is
  # bounded (HomeController), so a list that reached its bound says "your N latest" rather than
  # claiming a total it never counted.
  def home_lead
    projects = @recent_projects.size
    project_clause =
      if projects.zero? then "No project is open."
      elsif projects >= HomeController::RECENT_PROJECTS then "These are the #{count_words(projects)} projects you worked on last."
      else "#{count_words(projects).capitalize} #{projects == 1 ? "project is" : "projects are"} open."
      end
    tidy = Array(@tidy_attention).size
    capped = @failed_prints.size >= HomeController::ATTENTION_PRINTS || @low_stock.size >= HomeController::ATTENTION_STOCK ||
             tidy >= HomeController::ATTENTION_TIDY
    things = @failed_prints.size + @low_stock.size + tidy
    attention_clause =
      if things.zero? then "Nothing needs a look."
      elsif capped then "At least #{count_words(things)} things need a look."
      else "#{count_words(things).capitalize} #{things == 1 ? "thing needs" : "things need"} a look."
      end
    "#{project_clause} #{attention_clause}"
  end

  # "1 of 4 done": a project's task progress as Carry on and the project rows print it. `noun` is
  # the word the row puts between the count and "done" ("steps" on a project row, none in Carry on,
  # where the row is already about a step).
  def steps_done(progress, noun: nil)
    return nil unless progress

    word = noun && " #{progress.total == 1 ? noun : noun.pluralize}"
    "#{progress.done} of #{progress.total}#{word} done"
  end

  # What a Needs attention row is, in the caps word the screen sets before it: a mark in the accent
  # with its word (design-system.md rule 13: status is never colour alone).
  def attention_word(item) = item.quantity_cached.to_d <= 0 ? "Out of stock" : "Low stock"
end
