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
Postgres, which listens on `5432` **inside the compose network only** — the port is not
published, so nothing on the host can reach the database. The data lives in the Docker
named volume `cash_lens_pgdata`; `docker compose down -v` drops it.

Because the port is not published, host-side `mix` cannot connect. Run it in the container:

```sh
docker compose exec app mix test
docker compose exec app iex -S mix
```

## Running with Elixir directly

`./run` runs the Phoenix server natively on the host, against the same data:

```sh
./run          # mix phx.server
./run --iex    # inside an IEx shell
```

It starts its own Postgres container on the **same named volume** the compose `db` uses, so
what you import through the container is there when you run natively and vice versa. The
port is published only while `./run` is running, and the container is removed when it exits.

The compose `app` and `db` are stopped first: the app would clash on port 4444, and two
Postgres processes must never open one data directory. Bring them back with
`docker compose up -d`.

`DATABASE_HOST`, `DATABASE_PORT` and `DATABASE_NAME` set in the environment override the
defaults. Run `mix setup` once first, to install dependencies.

Either way the app is at [`localhost:4444`](http://localhost:4444).

### Importing from a Google Drive folder

The monitored statement folder normally lives in a Google Drive CloudStorage
directory. **Import from it with `./run`, not from the container.**

Drive stores those files as placeholders that macOS materialises on demand
through the FileProvider framework. A Docker bind mount cannot trigger that
materialisation, so inside the container the directory lists but reading a
statement fails with an I/O error — sometimes on the first read and not the
second, which is more confusing than failing outright. The folder is therefore
deliberately not mounted into the app container.

Running natively, the app reads the folder directly and the whole flow works.

### A note on the test suite

The app container runs as root, and root ignores file permission bits. One test asserts the
importer skips a file it cannot read, which cannot be true for root, so it is tagged
`:requires_unprivileged_user` and excluded automatically when the suite runs privileged.
Running the suite on the host exercises it for real.

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
