namespace :categories do
  desc "Remove categories from document metadata"
  task remove_metadata: :environment do
    updated_count = Document.where("metadata ? 'categories'")
      .update_all("metadata = metadata - 'categories'")

    puts "Removed metadata.categories from #{updated_count} documents"
  end
end
