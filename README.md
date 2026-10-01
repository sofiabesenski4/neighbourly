# Neighbourly Resources

A chat app that helps people find shelter and community resources near them.

These instructions assume macOS, which Sofia programs on. If you are running Linux or (god forbid) Windows, your mileage may vary.

## Local Dependencies

Install [Homebrew](https://brew.sh/).

To run this app locally, you need PostgreSQL installed and running.

```
brew install postgresql@18
brew services start postgresql@18
```

You also need the `pgvector` extension to encode our dataset.

```
brew install pgvector
```

You need Ruby installed. We recommend using `rbenv` to manage your Ruby versions.

```
brew install rbenv
brew install ruby-build
rbenv install 4.0.4 # Or the version in .ruby-version
rbenv local 4.0.4
```

## Environment Variables

Add a `.env` file to the root of the repo with your API keys:

```
OPENAI_API_KEY=<your_openai_api_key>
ANTHROPIC_API_KEY=<your_anthropic_api_key>
BASIC_AUTH_ENABLED=false
```

In production and staging, also set `APP_HOST` to the domain the app is served from, such as `example.org`. The app only accepts requests for that domain and sends mail from `no-reply@` that domain.

## App Setup

Install dependencies.

```
bundle install
yarn install
```

Set up the database.

```
bin/rails db:setup
```

Run the migrations.

```
bin/rails db:migrate
```

Start the server. This watches for CSS and JS changes and runs the server on port 3000.

```
bin/dev
```

You can now access the app at `http://localhost:3000`.

## Developing

We use linters and formatters to maintain code quality. We also scan for secrets so no credentials leak to our GitHub repo.

These all run in pre-commit hooks, which `yarn install` should set up. If they aren't working, you may need to configure the following locally:

- eslint for linting JS files
- prettier for autoformatting JS files
- standardrb for autoformatting Ruby files
- lint-staged for linting files before they are committed
- husky for pre-commit hooks
- trufflehog for ensuring credentials aren't committed to the repo
- lint-scss for SCSS files
- herb for ERB analysis

## Testing

We use RSpec on this project.

```
bundle exec rspec
```

Before you submit PRs or push a branch, make sure all tests pass. Don't just use Claude to stub out specs that were failing. We need to make sure regressions do not occur.

## Libraries

- Devise for authentication
- Pundit for authorization
- RubyLLM for AI toolkits
- pgvector for embedding our dataset
- RSpec for testing

*More coming soon*

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). Please do not open a public issue.

## License

Neighbourly Resources is free software, licensed under the GNU General Public
License version 2. See [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Sofia Besenski

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

---

Written by Claude ✅, Approved by Sofia ❌
