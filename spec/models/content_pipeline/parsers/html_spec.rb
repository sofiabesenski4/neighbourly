require "rails_helper"

RSpec.describe ContentPipeline::Parsers::Html do
  let(:source) { Source.new(name: "Harbour Street", url: "https://example.com/meals", source_type: "html") }
  let(:parser) { described_class.new(source) }

  let(:simple_html) do
    <<~HTML
      <html>
        <head><title>Meals at Harbour Street</title></head>
        <body>
          <nav>Navigation stuff</nav>
          <main class="content">
            <h1>Free Meals</h1>
            <p>We serve breakfast, lunch, and dinner every day.</p>
            <p>Located at 100 Harbour St, Victoria BC.</p>
          </main>
          <footer>Footer stuff</footer>
          <script>var x = 1;</script>
        </body>
      </html>
    HTML
  end

  describe "#parse" do
    it "extracts text content and removes non-content elements" do
      chunks = parser.parse(simple_html)

      expect(chunks).not_to be_empty
      combined = chunks.map { |c| c[:content] }.join(" ")

      expect(combined).to include("Free Meals")
      expect(combined).to include("breakfast, lunch, and dinner")
      expect(combined).not_to include("Navigation stuff")
      expect(combined).not_to include("Footer stuff")
      expect(combined).not_to include("var x = 1")
    end

    it "sets the page title from the <title> tag" do
      chunks = parser.parse(simple_html)
      expect(chunks.first[:title]).to eq("Meals at Harbour Street")
    end

    it "generates deterministic external_ids based on URL and chunk index" do
      chunks = parser.parse(simple_html)
      expected_prefix = Digest::SHA256.hexdigest(source.url)

      expect(chunks.first[:external_id]).to eq("#{expected_prefix}_0")
    end

    it "stores url and chunk_index in metadata" do
      chunks = parser.parse(simple_html)
      expect(chunks.first[:metadata][:url]).to eq(source.url)
      expect(chunks.first[:metadata][:chunk_index]).to eq(0)
    end

    context "with a css_selector configured" do
      let(:source) { Source.new(name: "Harbour Street", url: "https://example.com/meals", source_type: "html", css_selector: "main.content") }

      it "extracts only content matching the selector" do
        chunks = parser.parse(simple_html)
        combined = chunks.map { |c| c[:content] }.join(" ")

        expect(combined).to include("Free Meals")
        expect(combined).to include("100 Harbour St")
      end
    end

    context "with long content" do
      let(:long_html) do
        paragraphs = 10.times.map { |i| "<p>#{"Sentence number #{i}. " * 20}</p>" }.join
        "<html><head><title>Long Page</title></head><body>#{paragraphs}</body></html>"
      end

      it "splits into multiple overlapping chunks" do
        chunks = parser.parse(long_html)
        expect(chunks.size).to be > 1

        # Verify overlap: end of one chunk should appear in start of next
        chunks[0][:content][-100..]
        chunks[1][:content][0..200]
        # The overlap means some text from the end of chunk 0 appears in chunk 1
        overlap_text = chunks[0][:content][-200..]
        expect(chunks[1][:content]).to include(overlap_text[0..50])
      end
    end

    it "formats table content with headers as labeled values" do
      html = <<~HTML
        <html><head><title>Services</title></head>
        <body>
          <table>
            <thead><tr><th>Service</th><th>Hours</th><th>Location</th></tr></thead>
            <tbody>
              <tr><td>Free Meals</td><td>11am - 1pm</td><td>100 Harbour St</td></tr>
              <tr><td>Shelter Beds</td><td>7pm - 7am</td><td>200 Lantern Way</td></tr>
            </tbody>
          </table>
        </body></html>
      HTML

      chunks = parser.parse(html)
      combined = chunks.map { |c| c[:content] }.join(" ")

      expect(combined).to include("Service: Free Meals | Hours: 11am - 1pm | Location: 100 Harbour St")
      expect(combined).to include("Service: Shelter Beds | Hours: 7pm - 7am | Location: 200 Lantern Way")
    end

    it "returns empty array for blank content" do
      html = "<html><body><script>only scripts</script></body></html>"
      expect(parser.parse(html)).to be_empty
    end
  end
end
