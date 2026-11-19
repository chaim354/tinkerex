# THE LIBRARY'S 3D MODELS VIEW'S LEAD (Shop manual slice 7; the screen `models`), counted off what
# Files::ModelsController#index already loaded: the models on the page and the project groups they
# fall into. A filtered page says how many matched; an empty catalog says nothing, because its empty
# state explains where models come from.
module ModelsViewHelper
  def models_lead
    count = @models.size
    filtered = @filters.slice(:q, :status, :tag).values.any?(&:present?)
    return nil if count.zero? && !filtered
    return "#{count_words(count).capitalize} #{count == 1 ? "model matches" : "models match"}." if filtered

    in_projects = Array(@groups).select(&:project).sum { |group| group.models.size }
    head = "#{count_words(count).capitalize} #{count == 1 ? "model" : "models"}"
    head += in_projects == count ? (count == 1 ? ", in a project" : ", all of them in projects") : ", #{count_words(in_projects)} of them in a project" if in_projects.positive?
    "#{head}. A 3D file in a models folder becomes a model at the next scan."
  end
end
