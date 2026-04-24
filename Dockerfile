FROM elixir:1.18.4-otp-28-alpine

# Install build dependencies, watching tools and PDF tools
RUN apk add --no-cache python3 make g++ build-base git inotify-tools coreutils poppler-utils nodejs npm

# Install Gemini CLI
RUN npm install -g @google/gemini-cli --unsafe-perm

# Create a dummy watchman script to silence Phoenix/Tailwind errors
RUN echo -e '#!/bin/sh\nexit 0' > /usr/bin/watchman && \
    chmod +x /usr/bin/watchman

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app

# Copy dependency files first to leverage Docker cache
COPY mix.exs mix.lock ./
RUN mix deps.get

# We don't COPY the rest of the code here because we will use Volumes 
# in docker-compose for development to enable hot-swap.

CMD ["mix", "phx.server"]
