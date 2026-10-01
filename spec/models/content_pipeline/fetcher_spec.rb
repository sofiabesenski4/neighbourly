require "rails_helper"

RSpec.describe ContentPipeline::Fetcher do
  let(:source) { Source.new(name: "Test", url: "https://example.com/data.json", source_type: "api") }
  let(:fetcher) { described_class.new(source) }

  # Resolution is stubbed rather than left to real DNS so the suite neither
  # needs the network nor depends on what a public hostname happens to
  # resolve to today.
  def resolves_to(*addresses)
    allow(Resolv).to receive(:getaddresses).and_return(addresses)
  end

  before { resolves_to("93.184.216.34") }

  describe "#call" do
    it "returns the response body on success" do
      stub_request(:get, "https://example.com/data.json")
        .to_return(status: 200, body: '{"shelters": []}')

      expect(fetcher.call).to eq('{"shelters": []}')
    end

    it "raises FetchError on non-success HTTP status" do
      stub_request(:get, "https://example.com/data.json")
        .to_return(status: 404, body: "Not Found")

      expect { fetcher.call }.to raise_error(
        ContentPipeline::Fetcher::FetchError, /HTTP 404/
      )
    end
  end

  describe "refusing addresses that are not publicly routable" do
    {
      "loopback" => "127.0.0.1",
      "private class A" => "10.0.0.5",
      "private class B" => "172.16.4.9",
      "private class C" => "192.168.1.1",
      "cloud instance metadata" => "169.254.169.254",
      "carrier-grade NAT" => "100.64.0.1",
      "reserved" => "240.0.0.1",
      "IPv6 loopback" => "::1",
      "IPv6 unique local" => "fd00::1"
    }.each do |description, address|
      it "refuses a host resolving to #{description}" do
        resolves_to(address)

        expect { fetcher.call }.to raise_error(
          ContentPipeline::Fetcher::FetchError, /non-public address/
        )
      end
    end

    it "refuses when any resolved address is internal, not just the first" do
      resolves_to("93.184.216.34", "127.0.0.1")

      expect { fetcher.call }.to raise_error(
        ContentPipeline::Fetcher::FetchError, /non-public address/
      )
    end

    it "refuses a host that does not resolve at all" do
      resolves_to

      expect { fetcher.call }.to raise_error(
        ContentPipeline::Fetcher::FetchError, /did not resolve/
      )
    end

    it "makes no request when the address is refused" do
      resolves_to("127.0.0.1")
      stub = stub_request(:get, "https://example.com/data.json")

      expect { fetcher.call }.to raise_error(ContentPipeline::Fetcher::FetchError)
      expect(stub).not_to have_been_requested
    end
  end

  describe "refusing schemes other than http and https" do
    ["file:///etc/passwd", "ftp://example.com/data", "gopher://example.com"].each do |url|
      it "refuses #{url.split(":").first}" do
        source.url = url

        expect { fetcher.call }.to raise_error(
          ContentPipeline::Fetcher::FetchError, /only http and https/
        )
      end
    end

    it "allows plain http" do
      source.url = "http://example.com/data.json"
      stub_request(:get, "http://example.com/data.json").to_return(status: 200, body: "ok")

      expect(fetcher.call).to eq("ok")
    end
  end
end
