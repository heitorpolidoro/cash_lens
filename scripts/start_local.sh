#!/bin/bash
# Script to start the Postgres database via workspace docker-compose and run the application locally.

set -e

# Path to the workspace docker-compose file
COMPOSE_FILE="$HOME/workspace/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: Workspace docker-compose.yml not found at $COMPOSE_FILE"
  exit 1
fi

echo "🚀 Starting Postgres database via workspace docker-compose..."
docker compose -f "$COMPOSE_FILE" up postgres -d

echo "⏳ Waiting for Postgres to be ready..."
# Loop until Postgres is ready
until docker compose -f "$COMPOSE_FILE" exec postgres pg_isready -U postgres >/dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo ""
echo "✅ Postgres is ready!"

echo "💻 Starting Phoenix application locally..."
DATABASE_HOST=localhost iex -S mix phx.server
