require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#web_link" do
    it "links a web address in a new tab" do
      link = Nokogiri::HTML.fragment(helper.web_link("https://example.org")).at_css("a")

      expect(link["href"]).to eq("https://example.org")
      expect(link["target"]).to eq("_blank")
      expect(link["rel"]).to eq("noopener noreferrer")
    end

    it "shows anything else as plain text, so it can't run" do
      expect(helper.web_link("javascript:alert(1)")).to eq("javascript:alert(1)")
      expect(helper.web_link("https://example.org\njavascript:alert(1)")).not_to include("<a")
      expect(helper.web_link("https://:443")).to eq("https://:443")
    end
  end
end
