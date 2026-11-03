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

By default, the app uses `claude-haiku-4-5` for chat and `text-embedding-3-small` for embeddings. Chat uses `ANTHROPIC_API_KEY`, and embeddings use `OPENAI_API_KEY`. You can change the models with `DEFAULT_MODEL` and `EMBEDDING_MODEL`.

### AI Playground

To use UVic's AI Playground locally, add these settings to your `.env` file:

```
OPENAI_API_KEY=<your_playground_api_key>
OPENAI_API_BASE=<your_playground_api_base_url>
DEFAULT_MODEL=qwen3-6-35b-a3b-vllm
EMBEDDING_MODEL=nomic-embed-text-cpu
MODEL_REGISTRY_FILE=config/uvic_models.json
```

Use the API base URL provided by the playground, including its API version path. The playground uses an OpenAI-compatible API, so its key goes in `OPENAI_API_KEY`. You do not need an Anthropic key when both models use the playground.

After setting up the database, load the model registry:

```
bin/rails ruby_llm:load_models
```

Restart the app after changing environment variables.

### Production

On Heroku, set the environment variables in the app's Config Vars. The app reads them directly; it does not load your local `.env` file in production.

For the default chat and embedding models, use:

```
ANTHROPIC_API_KEY=<your_anthropic_api_key>
OPENAI_API_KEY=<your_openai_api_key>
DEFAULT_MODEL=claude-haiku-4-5
EMBEDDING_MODEL=text-embedding-3-small
```

Remove `OPENAI_API_BASE` and `MODEL_REGISTRY_FILE` from the Heroku config when using these providers. This restores the direct OpenAI endpoint and the default `models.json` registry. Keep the playground settings in your local environment.

In production and staging, also set `APP_HOST` to the domain the app is served from, such as `example.org`. The app only accepts requests for that domain and sends mail from `no-reply@` that domain.

The Heroku release command runs migrations and loads the model registry automatically. After deploying, check that:

- The release completed and the model registry loaded successfully.
- A new chat streams a reply, and a follow-up message works in the same conversation.
- A chat with "Search local resources" enabled retrieves a known document and cites its source.

### Changing Models

Chat and embedding models are configured separately. Changing only the chat model does not require rebuilding document embeddings. Start a new chat to use the new default model; existing chats keep their selected model.

Keep development and production databases separate when they use different embedding models. Stored document embeddings and search query embeddings must use the same model. Padding the playground's smaller vectors to fit the database does not make them compatible with OpenAI embeddings.

Before changing the embedding model on a populated database, plan to regenerate all affected document embeddings. The app does not rebuild them automatically, and ingesting unchanged content does not regenerate them. If you cannot confirm which model generated the existing embeddings, rebuild them before using resource lookup with the new model.

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
