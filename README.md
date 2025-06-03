# CashLens

## Local Development

To start your Phoenix server locally:

  * Run `mix setup` to install and setup dependencies
  * Make sure `inotify-tools` is installed for file system monitoring (required for live reloading)
    * See https://github.com/rvoicilas/inotify-tools/wiki for installation instructions
    * If `inotify-tools` is installed but not found, set the path using the `FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE` environment variable
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Docker Development Environment

To start the application using Docker:

  * Make sure you have Docker and Docker Compose installed
  * Run `docker-compose up` to start the PostgreSQL database and the Phoenix application
  * The application will be available at [`localhost:4000`](http://localhost:4000)

### Code Reloading with Docker

The Docker setup is configured for development with code reloading:

  * Changes to Elixir code will be automatically reloaded
  * Changes to assets (CSS, JS) will trigger automatic rebuilds
  * Database migrations will be run automatically on startup
  * `inotify-tools` is pre-installed in the Docker environment for file system monitoring

### Docker Commands

  * Start the environment: `docker-compose up`
  * Start in detached mode: `docker-compose up -d`
  * Stop the environment: `docker-compose down`
  * Rebuild the application: `docker-compose build app`
  * View logs: `docker-compose logs -f app`
  * Run commands in the container: `docker-compose exec app mix <command>`

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
