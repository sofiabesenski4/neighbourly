module ApplicationHelper
  # A link to an outside website, opened in a new tab. Only an http or https
  # address becomes a link, so a stored "javascript:" value can never run.
  def web_link(url)
    return url unless ApplicationRecord.web_address?(url)

    link_to url, url, target: "_blank", rel: "noopener noreferrer", class: "admin-link"
  end

  # Admin pages, and for an organization's members, the pages for their
  # organization and its services.
  def administration_page?
    return false unless current_user

    pages = current_user.admin? ? %w[admin users organizations services sources documents reports import_conflicts models] : []
    pages += %w[organizations services] if current_user.member?
    pages.include?(controller_name)
  end
end
