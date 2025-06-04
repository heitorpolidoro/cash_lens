#!/bin/sh
# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL..."
while ! nc -z $POSTGRES_HOST $POSTGRES_PORT; do
  sleep 1
done
echo "PostgreSQL started"

#mix deps.get
# Create, migrate, and seed the database
echo "Setting up the database..."
mix ecto.setup || mix ecto.create && mix ecto.migrate

# Start the Phoenix server with code reloading
echo "Starting Phoenix server..."
mix phx.server
