module ApplicationHelper
  # A link to an outside website, opened in a new tab. Only an http or https
  # address becomes a link, so a stored "javascript:" value can never run.
  def web_link(url)
    return url unless url.to_s.match?(ApplicationRecord::WEB_ADDRESS)

    link_to url, url, target: "_blank", rel: "noopener noreferrer", class: "admin-link"
  end

  def administration_page?
    current_user&.admin? && %w[admin users organizations services sources documents reports models].include?(controller_name)
  end
end
