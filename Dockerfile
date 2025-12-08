FROM elixir:1.18.4-otp-28-alpine

RUN apk add --no-cache build-base git

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix deps.compile

COPY . .
RUN mix compile

EXPOSE 4000

CMD ["mix", "phx.server"]
