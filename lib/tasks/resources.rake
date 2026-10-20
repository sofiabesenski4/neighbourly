namespace :resources do
  desc "Set each document's resource categories from its category labels"
  task categorize: :environment do
    updated = 0

    Document.find_each do |document|
      metadata = document.metadata || {}
      keys = ResourceCategory.keys_for(metadata["categories"])
      next if Array(metadata["resource_categories"]) == keys

      # Only metadata changes, so the document is not re-embedded.
      document.update!(metadata: metadata.merge("resource_categories" => keys))
      updated += 1
    end

    puts "Updated resource categories on #{updated} #{"document".pluralize(updated)}"
  end
end
