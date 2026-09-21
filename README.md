# CashLens

<div>
<!-- GitHub CI & Sponsors -->
<a href="https://github.com/heitorpolidoro/cash_lens/actions/workflows/ci.yml"><img src="https://github.com/heitorpolidoro/cash_lens/actions/workflows/ci.yml/badge.svg" alt="CI Status"></a>
<a href="https://github.com/sponsors/heitorpolidoro"><img src="https://img.shields.io/github/sponsors/heitorpolidoro?color=ea4aaa" alt="GitHub Sponsors"></a>
<br>

<!-- GitHub Stats -->
<a href="https://github.com/heitorpolidoro/cash_lens/releases/latest"><img src="https://img.shields.io/github/v/release/heitorpolidoro/cash_lens?label=Latest%20Version" alt="Latest Version"></a>
<img src="https://img.shields.io/github/release-date/heitorpolidoro/cash_lens" alt="GitHub Release Date">
<img src="https://img.shields.io/github/commits-since/heitorpolidoro/cash_lens/latest" alt="GitHub commits since latest release">
<img src="https://img.shields.io/github/last-commit/heitorpolidoro/cash_lens" alt="GitHub last commit">
<br>

<!-- GitHub Activity -->
<a href="https://github.com/heitorpolidoro/cash_lens/issues"><img src="https://img.shields.io/github/issues/heitorpolidoro/cash_lens" alt="GitHub issues"></a>
<a href="https://github.com/heitorpolidoro/cash_lens/pulls"><img src="https://img.shields.io/github/issues-pr/heitorpolidoro/cash_lens" alt="GitHub pull requests"></a>
<br>

<!-- SonarCloud -->
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=alert_status" alt="SonarCloud Quality Gate"></a>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=coverage" alt="SonarCloud Coverage"></a>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=security_rating" alt="SonarCloud Security Rating"></a>
<br>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=bugs" alt="SonarCloud Bugs"></a>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=vulnerabilities" alt="SonarCloud Vulnerabilities"></a>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=code_smells" alt="SonarCloud Code Smells"></a>
<a href="https://sonarcloud.io/summary/new_code?id=heitorpolidoro_cash_lens"><img src="https://sonarcloud.io/api/project_badges/measure?project=heitorpolidoro_cash_lens&metric=sqale_rating" alt="SonarCloud Maintainability"></a>
</div>

## Running locally

`cp .env.example .env` first, then:

```sh
docker compose up
```

That starts the app on [`localhost:4444`](http://localhost:4444) together with its own
Postgres on `:5432`. The database lives in the Docker named volume `cash_lens_pgdata`;
`docker compose down -v` drops it.

## Running with Elixir directly

`./run` starts this repo's Postgres (`docker compose up -d --wait db`) and then the Phoenix
server on the host, pointed at `localhost:5432`:

```sh
./run          # mix phx.server
./run --iex    # inside an IEx shell
```

`DATABASE_HOST`, `DATABASE_PORT` and `DATABASE_NAME` set in the environment override the
defaults. Run `mix setup` once first, to install dependencies.

Either way the app is at [`localhost:4444`](http://localhost:4444).

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Importing statements from folders

Import statements in bulk from the command line, routing each folder to the right account:

```sh
mix cash_lens.import <path>
```

Each account folder must contain a `.account` marker file identifying the
destination account (bank + name, case-insensitive):

```
bank: Banco do Brasil
account: Conta Corrente
```

- If `<path>` has a `.account`, it is imported as a single account.
- Otherwise each immediate subfolder with a `.account` is imported; subfolders
  without one are skipped with a warning.
- Only files matching the account's parser format are imported (e.g. `.csv` for
  `bb_csv`); mismatched files are skipped with a warning.
- Files are left in place; re-running is safe — already-imported transactions are
  deduplicated and reported as skipped.
- Output is clean (Ecto query logs are suppressed during import); in an interactive
  terminal a progress bar is shown per account plus an overall bar.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
