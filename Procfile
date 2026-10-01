web: bundle exec puma -C config/puma.rb
release: bundle exec rails db:migrate && bundle exec rake ruby_llm:load_models
