require "rails_helper"
require "rake"

RSpec.describe "resources rake tasks" do
  before(:all) do
    # Load only this file: loading every task again would define the
    # sources tasks twice when spec/tasks/sources_spec.rb runs later.
    load Rails.root.join("lib/tasks/resources.rake").to_s unless Rake::Task.task_defined?("resources:categorize")
  end

  let(:source) { Source.create!(name: "Test", url: "https://example.com/api", source_type: "api") }
  let(:task) { Rake::Task["resources:categorize"] }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
  end

  describe "resources:categorize" do
    it "sets resource categories from each document's labels" do
      labelled = source.documents.create!(content: "Drop-in", external_id: "1", metadata: {categories: ["Meals", "Showers"]})
      unlabelled = source.documents.create!(content: "Page chunk", external_id: "2", metadata: {url: "https://example.com"})

      expect { task.execute }.to output(/Updated resource categories on 1 document$/).to_stdout

      expect(labelled.reload.metadata["resource_categories"]).to eq(["food", "hygiene"])
      expect(unlabelled.reload.metadata).not_to have_key("resource_categories")
    end

    it "keeps the categories picked on the resource form" do
      picked = source.documents.create!(
        content: "Form entry", external_id: "1",
        metadata: {categories: ["Food", "Shelter & housing"], resource_categories: ["food", "shelter"]}
      )

      expect { task.execute }.to output(/Updated resource categories on 0 documents/).to_stdout

      expect(picked.reload.metadata["resource_categories"]).to eq(["food", "shelter"])
    end

    it "does not re-embed documents" do
      source.documents.create!(content: "Drop-in", external_id: "1", metadata: {categories: ["Meals"]})

      expect { task.execute }.to output.to_stdout

      expect(ContentPipeline::Embedder).to have_received(:embed).once
    end
  end
end
