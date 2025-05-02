# Use an official Elixir image as a base
FROM elixir:1.15-alpine AS build

# Install dependencies
RUN apk add --no-cache build-base git

# Set up the application directory
WORKDIR /app

# Install Hex and Rebar (Elixir build tools)
RUN mix local.hex --force && mix local.rebar --force

# Copy the mix configuration and dependencies files
COPY mix.exs mix.lock ./

# Fetch dependencies
RUN mix deps.get

# Copy the entire application into the container
COPY . .

# Compile the application
RUN mix compile

# Create a release
RUN mix release

# Use a smaller image for runtime
FROM alpine:latest AS runtime

# Install runtime dependencies
RUN apk add --no-cache libstdc++ ncurses-libs openssl

# Set the working directory for the app
WORKDIR /app

# Copy the release from the build stage
COPY --from=build /app/_build/prod/rel/cash_lens ./

# Set environment variables (optional)
ENV PORT=4000 MIX_ENV=prod

# Expose the app's port
EXPOSE 4000

# Command to run the application
CMD ["bin/cash_lens", "start"]
