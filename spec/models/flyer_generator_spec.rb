require "rails_helper"

RSpec.describe FlyerGenerator do
  it "returns nil when no resources match, without rendering a blank PDF" do
    section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: [])
    allow(CategorySearch).to receive(:call).with(categories: ["17"], origin: nil).and_return([section])
    expect(FlyerPdf).not_to receive(:new)

    expect(described_class.call(categories: ["17"])).to be_nil
  end

  it "passes the grouped resources, print time and site URL to the PDF renderer" do
    sections = [CategorySearch::Section.new(category: Category.new(name: "Food"), resources: [Service.new])]
    time = Time.current
    allow(CategorySearch).to receive(:call).with(categories: ["17"], origin: nil).and_return(sections)
    renderer = instance_double(FlyerPdf, render: "%PDF-real")
    site_url = "https://guide.example.test/"
    expect(FlyerPdf).to receive(:new).with(sections: sections, origin: nil, printed_at: time, detail_level: "detailed", site_url: site_url).and_return(renderer)

    expect(described_class.call(categories: ["17"], printed_at: time, site_url: site_url)).to eq("%PDF-real")
  end

  it "passes the place to measure distances from to the PDF renderer" do
    sections = [CategorySearch::Section.new(category: Category.new(name: "Food"), resources: [Service.new])]
    origin = FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.42, lng: -123.35))
    allow(CategorySearch).to receive(:call).with(categories: [], origin: origin).and_return(sections)
    renderer = instance_double(FlyerPdf, render: "%PDF-real")
    expect(FlyerPdf).to receive(:new).with(hash_including(origin: origin)).and_return(renderer)

    described_class.call(categories: [], origin: origin)
  end
end
