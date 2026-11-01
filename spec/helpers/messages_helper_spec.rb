require "rails_helper"

RSpec.describe MessagesHelper, type: :helper do
  describe "#reference_source_url" do
    ["https://example.com/resources?q=food", "http://example.com/resources"].each do |url|
      it "links to #{url}" do
        expect(helper.reference_source_url(Source.new(url: url))).to eq(url)
      end
    end

    [nil, "", "javascript:alert(1)", "data:text/html,test", "/resources", "https://", "https://invalid host"].each do |url|
      it "does not link to #{url.inspect}" do
        expect(helper.reference_source_url(Source.new(url: url))).to be_nil
      end
    end
  end
end
