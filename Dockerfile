FROM elixir:1.14-alpine

# Install build dependencies
RUN apk add --no-cache  \
    build-base  \
    git  \
    inotify-tools \
    netcat-openbsd \
    npm  \
    python3

# Set environment variables
ENV MIX_ENV=dev \
    PORT=4000 \
    # Enable code reloading
    PHX_SERVER=true \
    # Disable build cache for development
    ERL_AFLAGS="-kernel shell_history enabled"

# Create app directory and copy the Elixir project into it
WORKDIR /app

# Copy mix.exs and mix.lock files to install dependencies
#COPY mix.exs mix.lock ./

# Install hex package manager and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
#RUN mix deps.get

# Copy the rest of the application code
COPY . .

# Update dependencies to ensure lock file is in sync
RUN mix deps.get && \
# Install and setup assets
  mix assets.setup && \
  mix assets.deploy && \
  mix esbuild.install && \
  mix tailwind.install

# Expose port
EXPOSE 4000

# Copy the entrypoint script and make it executable
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Set the default command to run the startup script
CMD ["/app/entrypoint.sh"]
