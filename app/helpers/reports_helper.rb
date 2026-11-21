module ReportsHelper
  # Where accepting a report takes a resource out of. A row read into a
  # service also leaves printouts, which list services.
  def removal_places(document)
    document.service ? "search results and printouts" : "search results"
  end
end
