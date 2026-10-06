web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq
release: bundle exec rails db:migrate && bundle exec rake ruby_llm:load_models
