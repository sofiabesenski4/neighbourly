module ApplicationHelper
  def administration_page?
    current_user&.admin? && %w[admin users sources documents reports models].include?(controller_name)
  end
end
