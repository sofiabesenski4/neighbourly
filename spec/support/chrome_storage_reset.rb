require "capybara/selenium/driver"

# Chrome 158 rejects the wildcard origin Capybara 3.40 passes to
# Storage.clearDataForOrigin when it resets a session, which fails every
# browser spec. Clear cookies for the whole browser and storage for the origin
# the spec was on instead.
module ChromeStorageReset
  def reset!
    @origin_to_clear = origin_of_current_page if @browser
    super
  ensure
    @origin_to_clear = nil
  end

  private

  def execute_cdp(cmd, params = {})
    return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

    super("Network.clearBrowserCookies")
    super(cmd, params.merge(origin: @origin_to_clear)) if @origin_to_clear
  end

  def origin_of_current_page
    uri = URI.parse(current_url.to_s)
    "#{uri.scheme}://#{uri.host}:#{uri.port}" if %w[http https].include?(uri.scheme)
  rescue URI::InvalidURIError, Selenium::WebDriver::Error::WebDriverError
    nil
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageReset)
