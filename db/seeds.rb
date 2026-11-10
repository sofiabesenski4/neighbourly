# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

category_names = [
  "Meals",
  "Shelters",
  "Harm Reduction Resources",
  "Supervised Consumption",
  "Substance Use Support",
  "Food Banks",
  "Computer & Internet",
  "Showers",
  "Health Care",
  "Clothing",
  "Youth Services",
  "Legal Support",
  "Employment Support",
  "Indigenous Support",
  "Housing Services",
  "Mental Health Support"
]

category_names.each do |name|
  Category.find_or_create_by!(name: name)
end

# Real resource listings to develop against. Not loaded in other environments,
# which get their resources from ingested sources.
load Rails.root.join("db/seeds/greater_victoria_resources.rb") if Rails.env.development?
