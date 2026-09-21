FROM elixir:1.18.4-otp-28-alpine

# Install build dependencies, watching tools and PDF tools.
#
# nodejs and npm are required and must stay: esbuild and tailwind ship as
# standalone native binaries and need no Node runtime, but the bundle they build
# does have npm dependencies. assets/js/app.js imports chart.js, dompurify and
# flatpickr, and esbuild resolves those bare imports from assets/node_modules
# (esbuild runs with `cd: assets`, see config/config.exs). assets/node_modules is
# gitignored and nothing provisions it automatically, so a fresh clone must run
# `npm install --prefix assets` before the bundle can build — npm is here for that.
RUN apk add --no-cache python3 make g++ build-base git inotify-tools coreutils poppler-utils nodejs npm

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
