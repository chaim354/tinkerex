# THE PROJECTS INDEX'S HEAD (Shop manual slice 7; the screen `projects`): its lead sentence, from the
# list ProjectsController#index already loaded and nothing else. Its own file, beside ProjectsHelper,
# which the project page's slice owns.
module ProjectsIndexHelper
  def projects_lead
    count = @projects.size
    filtered = @tag.present? || @kind.present? || @q.present?
    if @archived_view
      return count.zero? ? "Nothing is archived." : "#{count_words(count).capitalize} archived #{count == 1 ? "project" : "projects"}, kept out of every other list."
    end
    return filtered ? "No project matches." : nil if count.zero?

    active = @projects.count { |project| project.status == "active" }
    noun = count == 1 ? "project" : "projects"
    head = filtered ? "#{count_words(count).capitalize} #{noun} #{count == 1 ? "matches" : "match"}" : "#{count_words(count).capitalize} #{noun}"
    tail =
      if count == 1 then active == 1 ? ", and it is active" : ""
      elsif active == count then ", all of them active"
      elsif active.zero? then ", none of them active yet"
      else ", #{count_words(active)} of them active"
      end
    "#{head}#{tail}."
  end
end
