# Importar transações via Pluggy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a manual "Importar do Pluggy" path that pulls transactions from the Pluggy Open Finance API into cash_lens, alongside the existing file-based imports, without duplicating data between the two sources.

**Architecture:** A new `CashLens.Pluggy` context (schemas + CRUD for registered items and their account mappings) backs a new `/pluggy` screen for registering `itemId`s and mapping Pluggy accounts to existing cash_lens accounts. A `CashLens.Pluggy.Client` module wraps the three Pluggy HTTP calls we need (auth, list accounts, list transactions). A `CashLens.Pluggy.Sync` module orchestrates one account's sync (fetch → normalize sign → `Transactions.create_transaction/1` → credit-card statement find-or-update) and is triggered by a new button on `/transactions`.

**Tech Stack:** Elixir/Phoenix/LiveView, Ecto/Postgres, `Req` (HTTP client, already a dependency) with `Req.Test` for stubbing in tests, ExUnit.

## Global Constraints

- Sign conversion (from the spec, verified against Pluggy's docs, not assumed):
  - `BANK` account: Pluggy's `amount` is always positive; `type` field says direction. `type == "DEBIT"` → negative in cash_lens. `type == "CREDIT"` → positive in cash_lens.
  - `CREDIT` account: Pluggy's `amount` is already signed but inverted vs. cash_lens (positive = purchase/expense in Pluggy). cash_lens amount = `-pluggy_amount`.
- Before creating a `credit_card_statements` row, always check for an existing one at `(account_id, competencia)` first — update it if found, never insert a second row for the same competência.
- Sync window: `last_synced_at` nil → last 90 days. `last_synced_at` present → from that date to today.
- Pluggy accounts without a mapped `account_id` are silently skipped during "Importar do Pluggy" — not an error.
- One account failing during a bulk sync must not stop the others; report per-account results.
- No scheduled/automatic sync, no forced item update (`PATCH /items/{id}`), no active use of `pluggy_category` beyond storing it, no support for account types other than `BANK`/`CREDIT` — all out of scope per the spec's Não-objetivos.
- `PLUGGY_CLIENT_ID` / `PLUGGY_CLIENT_SECRET` are read from the environment at call time (already set in `.env`, exported the same way as `SECRET_KEY_BASE`) — never hardcoded, never logged.

---

### Task 1: Data model — schemas, migrations, `CashLens.Pluggy` context

**Files:**
- Create: `priv/repo/migrations/20260731120000_create_pluggy_items.exs`
- Create: `priv/repo/migrations/20260731120100_create_pluggy_account_links.exs`
- Create: `priv/repo/migrations/20260731120200_add_pluggy_category_to_transactions.exs`
- Create: `lib/cash_lens/pluggy/item.ex`
- Create: `lib/cash_lens/pluggy/account_link.ex`
- Create: `lib/cash_lens/pluggy.ex`
- Modify: `lib/cash_lens/transactions/transaction.ex`
- Test: `test/cash_lens/pluggy_test.exs`
- Test: `test/support/fixtures/pluggy_fixtures.ex` (new fixtures module)

**Interfaces:**
- Produces: `CashLens.Pluggy.Item` schema (`id`, `item_id`, `label`, timestamps, `has_many :account_links`). `CashLens.Pluggy.AccountLink` schema (`id`, `pluggy_item_id`, `pluggy_account_id`, `pluggy_account_name`, `pluggy_account_type`, `account_id` nullable, `last_synced_at` nullable `:utc_datetime`, `belongs_to :pluggy_item`, `belongs_to :account, CashLens.Accounts.Account`). `CashLens.Pluggy.create_item/1`, `list_items/0`, `get_item!/1`, `upsert_account_link/2`, `list_account_links_for_item/1`, `link_account/2`, `list_linked_account_links/0`, `touch_last_synced_at/1` — exact signatures below. `Transaction` schema gains a `:pluggy_category` string field, cast in the changeset.

- [ ] **Step 1: Write the failing tests**

Create `test/support/fixtures/pluggy_fixtures.ex`:

```elixir
defmodule CashLens.PluggyFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CashLens.Pluggy` context.
  """

  def pluggy_item_fixture(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    {:ok, item} =
      attrs
      |> Enum.into(%{
        item_id: "item-#{unique_id}",
        label: "Item #{unique_id}"
      })
      |> CashLens.Pluggy.create_item()

    item
  end
end
```

Create `test/cash_lens/pluggy_test.exs`:

```elixir
defmodule CashLens.PluggyTest do
  use CashLens.DataCase, async: true

  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy
  alias CashLens.Pluggy.AccountLink

  describe "create_item/1" do
    test "creates an item with an item_id and label" do
      assert {:ok, item} = Pluggy.create_item(%{item_id: "abc-123", label: "Open Finance BB"})
      assert item.item_id == "abc-123"
      assert item.label == "Open Finance BB"
    end

    test "requires item_id" do
      assert {:error, changeset} = Pluggy.create_item(%{label: "no item_id"})
      assert "can't be blank" in errors_on(changeset).item_id
    end
  end

  describe "list_items/0" do
    test "returns all registered items" do
      item = pluggy_item_fixture()
      assert Pluggy.list_items() |> Enum.map(& &1.id) == [item.id]
    end
  end

  describe "upsert_account_link/2" do
    test "creates a new link with account_id nil when none exists" do
      item = pluggy_item_fixture()

      assert {:ok, link} =
               Pluggy.upsert_account_link(item, %{
                 pluggy_account_id: "acc-1",
                 pluggy_account_name: "BANCO DO BRASIL S/A",
                 pluggy_account_type: "BANK"
               })

      assert link.pluggy_item_id == item.id
      assert link.pluggy_account_id == "acc-1"
      assert is_nil(link.account_id)
    end

    test "updates name/type of an existing link without touching account_id" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Old Name",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} = Pluggy.link_account(link, account.id)

      assert {:ok, updated} =
               Pluggy.upsert_account_link(item, %{
                 pluggy_account_id: "acc-1",
                 pluggy_account_name: "New Name",
                 pluggy_account_type: "BANK"
               })

      assert updated.id == linked.id
      assert updated.pluggy_account_name == "New Name"
      assert updated.account_id == account.id
    end
  end

  describe "list_account_links_for_item/1" do
    test "returns only links for the given item" do
      item_a = pluggy_item_fixture()
      item_b = pluggy_item_fixture()

      {:ok, link_a} =
        Pluggy.upsert_account_link(item_a, %{
          pluggy_account_id: "a1",
          pluggy_account_name: "A",
          pluggy_account_type: "BANK"
        })

      {:ok, _link_b} =
        Pluggy.upsert_account_link(item_b, %{
          pluggy_account_id: "b1",
          pluggy_account_name: "B",
          pluggy_account_type: "BANK"
        })

      assert Pluggy.list_account_links_for_item(item_a.id) |> Enum.map(& &1.id) == [link_a.id]
    end
  end

  describe "link_account/2" do
    test "sets the account_id on the link" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      assert {:ok, updated} = Pluggy.link_account(link, account.id)
      assert updated.account_id == account.id
    end
  end

  describe "list_linked_account_links/0" do
    test "returns only links that have an account_id" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, unlinked} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "unlinked",
          pluggy_account_name: "Unlinked",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "linked",
          pluggy_account_name: "Linked",
          pluggy_account_type: "BANK"
        })

      {:ok, linked} = Pluggy.link_account(linked, account.id)

      result_ids = Pluggy.list_linked_account_links() |> Enum.map(& &1.id)
      refute unlinked.id in result_ids
      assert linked.id in result_ids
    end

    test "preloads :account and :pluggy_item" do
      item = pluggy_item_fixture()
      account = account_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "linked",
          pluggy_account_name: "Linked",
          pluggy_account_type: "BANK"
        })

      {:ok, _} = Pluggy.link_account(link, account.id)

      [result] = Pluggy.list_linked_account_links()
      assert %CashLens.Accounts.Account{} = result.account
      assert %CashLens.Pluggy.Item{} = result.pluggy_item
    end
  end

  describe "touch_last_synced_at/1" do
    test "sets last_synced_at to now" do
      item = pluggy_item_fixture()

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta",
          pluggy_account_type: "BANK"
        })

      assert is_nil(link.last_synced_at)
      assert {:ok, updated} = Pluggy.touch_last_synced_at(link)
      assert %DateTime{} = updated.last_synced_at
      assert DateTime.diff(DateTime.utc_now(), updated.last_synced_at, :second) < 5
    end
  end

  describe "unique index on (pluggy_item_id, pluggy_account_id)" do
    test "upsert_account_link never creates a duplicate row for the same pair" do
      item = pluggy_item_fixture()

      {:ok, first} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "First",
          pluggy_account_type: "BANK"
        })

      {:ok, second} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Second",
          pluggy_account_type: "BANK"
        })

      assert first.id == second.id
      assert length(Pluggy.list_account_links_for_item(item.id)) == 1
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/pluggy_test.exs`
Expected: FAIL — `CashLens.Pluggy` doesn't exist yet (`UndefinedFunctionError` / compile error).

- [ ] **Step 3: Create the migrations**

Create `priv/repo/migrations/20260731120000_create_pluggy_items.exs`:

```elixir
defmodule CashLens.Repo.Migrations.CreatePluggyItems do
  use Ecto.Migration

  def change do
    create table(:pluggy_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime)
    end
  end
end
```

Create `priv/repo/migrations/20260731120100_create_pluggy_account_links.exs`:

```elixir
defmodule CashLens.Repo.Migrations.CreatePluggyAccountLinks do
  use Ecto.Migration

  def change do
    create table(:pluggy_account_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :pluggy_item_id, references(:pluggy_items, on_delete: :delete_all, type: :binary_id),
        null: false

      add :pluggy_account_id, :string, null: false
      add :pluggy_account_name, :string
      add :pluggy_account_type, :string

      add :account_id, references(:accounts, on_delete: :nilify_all, type: :binary_id)

      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pluggy_account_links, [:pluggy_item_id, :pluggy_account_id])
    create index(:pluggy_account_links, [:account_id])
  end
end
```

Create `priv/repo/migrations/20260731120200_add_pluggy_category_to_transactions.exs`:

```elixir
defmodule CashLens.Repo.Migrations.AddPluggyCategoryToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :pluggy_category, :string
    end
  end
end
```

- [ ] **Step 4: Create the schemas**

Create `lib/cash_lens/pluggy/item.ex`:

```elixir
defmodule CashLens.Pluggy.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pluggy_items" do
    field :item_id, :string
    field :label, :string

    has_many :account_links, CashLens.Pluggy.AccountLink

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:item_id, :label])
    |> validate_required([:item_id])
  end
end
```

Create `lib/cash_lens/pluggy/account_link.ex`:

```elixir
defmodule CashLens.Pluggy.AccountLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pluggy_account_links" do
    field :pluggy_account_id, :string
    field :pluggy_account_name, :string
    field :pluggy_account_type, :string
    field :last_synced_at, :utc_datetime

    belongs_to :pluggy_item, CashLens.Pluggy.Item
    belongs_to :account, CashLens.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account_link, attrs) do
    account_link
    |> cast(attrs, [
      :pluggy_item_id,
      :pluggy_account_id,
      :pluggy_account_name,
      :pluggy_account_type,
      :account_id,
      :last_synced_at
    ])
    |> validate_required([:pluggy_item_id, :pluggy_account_id])
    |> unique_constraint([:pluggy_item_id, :pluggy_account_id])
    |> foreign_key_constraint(:pluggy_item_id)
    |> foreign_key_constraint(:account_id)
  end
end
```

- [ ] **Step 5: Create the `CashLens.Pluggy` context**

Create `lib/cash_lens/pluggy.ex`:

```elixir
defmodule CashLens.Pluggy do
  @moduledoc """
  Registered Pluggy items (Open Finance connections) and the mapping between
  each Pluggy account inside an item and an existing cash_lens account.
  """
  import Ecto.Query

  alias CashLens.Pluggy.AccountLink
  alias CashLens.Pluggy.Item
  alias CashLens.Repo

  def create_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert()
  end

  def list_items do
    Repo.all(Item)
  end

  def get_item!(id), do: Repo.get!(Item, id)

  @doc """
  Creates a link for `pluggy_account_id` under `item` if none exists yet
  (with `account_id` left nil for the user to fill in), or updates the
  existing link's name/type without touching a already-chosen `account_id`.
  """
  def upsert_account_link(%Item{} = item, attrs) do
    pluggy_account_id = Map.fetch!(attrs, :pluggy_account_id)

    case Repo.get_by(AccountLink,
           pluggy_item_id: item.id,
           pluggy_account_id: pluggy_account_id
         ) do
      nil ->
        %AccountLink{}
        |> AccountLink.changeset(Map.put(attrs, :pluggy_item_id, item.id))
        |> Repo.insert()

      existing ->
        existing
        |> AccountLink.changeset(Map.take(attrs, [:pluggy_account_name, :pluggy_account_type]))
        |> Repo.update()
    end
  end

  def list_account_links_for_item(item_id) do
    from(l in AccountLink, where: l.pluggy_item_id == ^item_id)
    |> Repo.all()
  end

  def link_account(%AccountLink{} = account_link, account_id) do
    account_link
    |> AccountLink.changeset(%{account_id: account_id})
    |> Repo.update()
  end

  @doc """
  Links with an `account_id` already chosen — these are the ones
  `CashLens.Pluggy.Sync` imports transactions for.
  """
  def list_linked_account_links do
    from(l in AccountLink, where: not is_nil(l.account_id))
    |> Repo.all()
    |> Repo.preload([:account, :pluggy_item])
  end

  def touch_last_synced_at(%AccountLink{} = account_link) do
    account_link
    |> AccountLink.changeset(%{last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end
end
```

- [ ] **Step 6: Add `pluggy_category` to the `Transaction` schema**

In `lib/cash_lens/transactions/transaction.ex`, add the field to the schema (place it near `:notes`):

```elixir
    field :notes, :string
    field :pluggy_category, :string
```

And add `:pluggy_category` to the `cast/3` list in `changeset/2` (alongside `:notes`):

```elixir
    |> cast(attrs, [
      :id,
      :date,
      :time,
      :description,
      :amount,
      :category_id,
      :account_id,
      :transfer_key,
      :reimbursement_status,
      :reimbursement_link_key,
      :notes,
      :pluggy_category,
      :installment_group_id,
      :installment_number,
      :occurrence_index,
      :parent_transaction_id,
      :import_batch_id
    ])
```

- [ ] **Step 7: Run migrations and the tests to verify they pass**

Run: `mix ecto.migrate`
Expected: 3 migrations applied.

Run: `mix test test/cash_lens/pluggy_test.exs`
Expected: PASS — all tests green.

- [ ] **Step 8: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS — no failures (the `pluggy_category` column addition must not break any existing `Transaction` changeset test).

- [ ] **Step 9: Format and commit**

```bash
mix format
git add priv/repo/migrations/20260731120000_create_pluggy_items.exs \
        priv/repo/migrations/20260731120100_create_pluggy_account_links.exs \
        priv/repo/migrations/20260731120200_add_pluggy_category_to_transactions.exs \
        lib/cash_lens/pluggy/item.ex \
        lib/cash_lens/pluggy/account_link.ex \
        lib/cash_lens/pluggy.ex \
        lib/cash_lens/transactions/transaction.ex \
        test/cash_lens/pluggy_test.exs \
        test/support/fixtures/pluggy_fixtures.ex
git commit -m "$(cat <<'EOF'
feat(pluggy): add data model for Pluggy items and account links

pluggy_items stores registered item ids; pluggy_account_links maps each
Pluggy account inside an item to an existing cash_lens account (nullable
until the user picks one in the UI). transactions gains a pluggy_category
column to store Pluggy's own categorization as an unused hint for now.
EOF
)"
```

---

### Task 2: `CashLens.Pluggy.Client` — Pluggy API HTTP wrapper

**Files:**
- Create: `lib/cash_lens/pluggy/client.ex`
- Test: `test/cash_lens/pluggy/client_test.exs`

**Interfaces:**
- Consumes: `Req` (already a dependency, `mix.exs`).
- Produces: `CashLens.Pluggy.Client.auth/3` — `(client_id :: String.t(), client_secret :: String.t(), req_options :: keyword()) :: {:ok, api_key :: String.t()} | {:error, term()}`. `list_accounts/3` — `(api_key :: String.t(), item_id :: String.t(), req_options :: keyword()) :: {:ok, [map()]} | {:error, term()}`. `list_transactions/4` — `(api_key :: String.t(), account_id :: String.t(), from_date :: Date.t(), req_options :: keyword()) :: {:ok, [map()]} | {:error, term()}` (transparently follows cursor pagination and returns the full flattened list). `req_options` defaults to `[]` in all three and is merged into `Req.new/1` — Task 3 always calls with `[]` (real HTTP); tests pass `[plug: {Req.Test, CashLens.Pluggy.Client}]` to stub.

- [ ] **Step 1: Write the failing tests**

Create `test/cash_lens/pluggy/client_test.exs`:

```elixir
defmodule CashLens.Pluggy.ClientTest do
  use ExUnit.Case, async: true

  alias CashLens.Pluggy.Client

  setup do
    {:ok, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
  end

  describe "auth/3" do
    test "returns the api key on a 200 response", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/auth"
        Req.Test.json(conn, %{"apiKey" => "test-key"})
      end)

      assert {:ok, "test-key"} = Client.auth("cid", "csecret", req_options)
    end

    test "returns an error tuple on a non-200 response", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "invalid credentials"})
      end)

      assert {:error, {401, %{"message" => "invalid credentials"}}} =
               Client.auth("cid", "wrong", req_options)
    end
  end

  describe "list_accounts/3" do
    test "returns the results list", %{req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/accounts"
        assert conn.query_string =~ "itemId=item-1"

        Req.Test.json(conn, %{
          "results" => [%{"id" => "acc-1", "name" => "Conta", "type" => "BANK"}]
        })
      end)

      assert {:ok, [%{"id" => "acc-1"}]} = Client.list_accounts("api-key", "item-1", req_options)
    end
  end

  describe "list_transactions/4" do
    test "returns results from a single page when there is no next cursor", %{
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.request_path == "/v2/transactions"
        assert conn.query_string =~ "accountId=acc-1"
        assert conn.query_string =~ "from=2026-05-01"

        Req.Test.json(conn, %{
          "results" => [%{"id" => "tx-1"}, %{"id" => "tx-2"}],
          "next" => nil
        })
      end)

      assert {:ok, [%{"id" => "tx-1"}, %{"id" => "tx-2"}]} =
               Client.list_transactions("api-key", "acc-1", ~D[2026-05-01], req_options)
    end

    test "follows the cursor across pages and flattens the results", %{
      req_options: req_options
    } do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        call_number = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        case call_number do
          0 ->
            assert conn.query_string =~ "accountId=acc-1"
            refute conn.query_string =~ "after="
            Req.Test.json(conn, %{"results" => [%{"id" => "tx-1"}], "next" => "cursor-abc"})

          1 ->
            assert conn.query_string =~ "after=cursor-abc"
            Req.Test.json(conn, %{"results" => [%{"id" => "tx-2"}], "next" => nil})
        end
      end)

      assert {:ok, [%{"id" => "tx-1"}, %{"id" => "tx-2"}]} =
               Client.list_transactions("api-key", "acc-1", ~D[2026-05-01], req_options)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/pluggy/client_test.exs`
Expected: FAIL — `CashLens.Pluggy.Client` doesn't exist.

- [ ] **Step 3: Implement the client**

Create `lib/cash_lens/pluggy/client.ex`:

```elixir
defmodule CashLens.Pluggy.Client do
  @moduledoc """
  Thin HTTP wrapper around the three Pluggy API endpoints this app needs:
  authenticate, list a connection's accounts, list an account's
  transactions (following cursor pagination transparently).

  Every function takes a `req_options` keyword list (default `[]`) merged
  into `Req.new/1`, so tests can pass `[plug: {Req.Test, __MODULE__}]` to
  stub responses without touching the network.
  """

  @base_url "https://api.pluggy.ai"

  @doc "Exchanges clientId/clientSecret for a short-lived apiKey."
  def auth(client_id, client_secret, req_options \\ []) do
    [base_url: @base_url]
    |> Keyword.merge(req_options)
    |> Req.new()
    |> Req.post(url: "/auth", json: %{"clientId" => client_id, "clientSecret" => client_secret})
    |> handle_response(fn %{"apiKey" => api_key} -> api_key end)
  end

  @doc "Lists every account inside a Pluggy item."
  def list_accounts(api_key, item_id, req_options \\ []) do
    [base_url: @base_url]
    |> Keyword.merge(req_options)
    |> Req.new()
    |> Req.get(url: "/accounts", headers: [{"X-API-KEY", api_key}], params: [itemId: item_id])
    |> handle_response(fn %{"results" => results} -> results end)
  end

  @doc """
  Lists every transaction for an account on or after `from_date`, following
  the API's cursor pagination (`next` in the response) until exhausted, and
  returning the full flattened list.
  """
  def list_transactions(api_key, account_id, %Date{} = from_date, req_options \\ []) do
    req = Keyword.merge([base_url: @base_url], req_options) |> Req.new()
    fetch_transactions_page(req, api_key, account_id, from_date, nil, [])
  end

  defp fetch_transactions_page(req, api_key, account_id, from_date, after_cursor, acc) do
    base_params = [accountId: account_id, from: Date.to_iso8601(from_date)]
    params = if after_cursor, do: base_params ++ [after: after_cursor], else: base_params

    req
    |> Req.get(url: "/v2/transactions", headers: [{"X-API-KEY", api_key}], params: params)
    |> case do
      {:ok, %{status: 200, body: %{"results" => results} = body}} ->
        acc = acc ++ results

        case next_cursor(body["next"]) do
          nil -> {:ok, acc}
          cursor -> fetch_transactions_page(req, api_key, account_id, from_date, cursor, acc)
        end

      other ->
        handle_response(other, & &1)
    end
  end

  # `next` may be a bare cursor string, or a full URL/query string carrying
  # an `after` param — handle both without assuming which one the API sends.
  defp next_cursor(nil), do: nil

  defp next_cursor(next) when is_binary(next) do
    if String.contains?(next, "after=") do
      next
      |> URI.parse()
      |> Map.get(:query)
      |> then(&(&1 || next))
      |> URI.decode_query()
      |> Map.get("after")
    else
      next
    end
  end

  defp handle_response({:ok, %{status: 200, body: body}}, extract), do: {:ok, extract.(body)}
  defp handle_response({:ok, %{status: status, body: body}}, _extract), do: {:error, {status, body}}
  defp handle_response({:error, reason}, _extract), do: {:error, reason}
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cash_lens/pluggy/client_test.exs`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Wire a test-only default so callers that don't pass `req_options` explicitly still get stubbed in tests**

`Sync.sync_all/0` (Task 3) and the `/pluggy` LiveView (Task 4) call `Client` functions without passing `req_options` — in tests those calls must still resolve to `Req.Test`, not the real network. Add to `config/test.exs` (create the file's Pluggy section near the other test-only config, e.g. near `config :cash_lens, :pdf_converter, ...`):

```elixir
config :cash_lens, :pluggy_req_options, [plug: {Req.Test, CashLens.Pluggy.Client}]
```

This key is read via `Application.get_env(:cash_lens, :pluggy_req_options, [])` by `Sync` (Task 3) and the LiveView (Task 4) wherever they call into `Client` without an explicit `req_options` — the `[]` fallback means dev/prod (where this key is never set) always makes real HTTP calls, exactly as before. `config/dev.exs` and `config/runtime.exs` need no change.

- [ ] **Step 6: Manually verify against the real Pluggy API**

This project already has working Pluggy credentials in `.env` and a known real `itemId` (`4f8078fa-b126-4bc9-9eff-5d293b834721`, the user's Banco do Brasil connection) from earlier testing this session. Confirm the client's pagination and param names actually match the live API (the `after` cursor param name was inferred from Pluggy's docs/community search, not observed directly):

```bash
export $(cat .env | xargs)
mix run -e '
{:ok, api_key} = CashLens.Pluggy.Client.auth(System.fetch_env!("PLUGGY_CLIENT_ID"), System.fetch_env!("PLUGGY_CLIENT_SECRET"))
{:ok, accounts} = CashLens.Pluggy.Client.list_accounts(api_key, "4f8078fa-b126-4bc9-9eff-5d293b834721")
IO.inspect(Enum.map(accounts, & &1["id"]), label: "account ids")
first_account_id = hd(accounts)["id"]
{:ok, txs} = CashLens.Pluggy.Client.list_transactions(api_key, first_account_id, Date.add(Date.utc_today(), -90))
IO.puts("fetched #{length(txs)} transactions")
'
```

Expected: prints account ids and a transaction count with no errors. If the real API returns a different cursor shape than the tests assumed, fix `next_cursor/1` now and re-run Step 4.

- [ ] **Step 7: Commit**

```bash
mix format
git add lib/cash_lens/pluggy/client.ex test/cash_lens/pluggy/client_test.exs config/test.exs
git commit -m "$(cat <<'EOF'
feat(pluggy): add HTTP client for the Pluggy auth/accounts/transactions API

Wraps POST /auth, GET /accounts, and GET /v2/transactions (with
transparent cursor-pagination follow-through). Every function accepts a
req_options override so tests stub via Req.Test instead of the network;
config/test.exs sets the default so callers that don't pass req_options
explicitly (Sync.sync_all/0, the /pluggy LiveView) are stubbed too.
EOF
)"
```

---

### Task 3: `CashLens.Pluggy.Sync` — sign normalization, transaction import, statement dedup

**Files:**
- Modify: `lib/cash_lens/credit_cards.ex`
- Create: `lib/cash_lens/pluggy/sync.ex`
- Test: `test/cash_lens/pluggy/sync_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.Client.list_accounts/3`, `list_transactions/4` (Task 2). `CashLens.Pluggy.list_linked_account_links/0`, `touch_last_synced_at/1` (Task 1). `CashLens.Transactions.create_transaction/1` (existing — returns `{:ok, transaction}` | `{:ok, :duplicate}` | `{:error, changeset}`). `CashLens.Accounting.rebuild_account_balances/1` (existing).
- Produces: `CashLens.CreditCards.get_statement_by_account_and_competencia/2` — `(account_id :: binary(), competencia :: Date.t()) :: Statement.t() | nil`. `CashLens.CreditCards.update_statement/2` — `(Statement.t(), map()) :: {:ok, Statement.t()} | {:error, Ecto.Changeset.t()}`. `CashLens.Pluggy.Sync.normalize_amount/2` — `(account_type :: String.t(), pluggy_transaction :: map()) :: Decimal.t()`. `CashLens.Pluggy.Sync.sync_account_link/3` (arity 2 also exists — third arg `req_options` defaults to `[]`) — `(AccountLink.t(), api_key :: String.t(), req_options :: keyword()) :: {:ok, %{created: integer(), skipped: integer()}} | {:error, term()}`. `CashLens.Pluggy.Sync.sync_all/1` (arity 0 also exists — `req_options` defaults to `[]`) — `(req_options :: keyword()) :: [{AccountLink.t(), {:ok, %{created: integer(), skipped: integer()}} | {:error, term()}}] | {:error, :missing_credentials}` — this is what Task 5's button calls (as `Sync.sync_all()`, arity 0, real HTTP).

- [ ] **Step 1: Write the failing tests for `normalize_amount/2` (the highest-risk logic)**

Create `test/cash_lens/pluggy/sync_test.exs`:

```elixir
defmodule CashLens.Pluggy.SyncTest do
  use CashLens.DataCase, async: false

  import Ecto.Query
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.PluggyFixtures

  alias CashLens.CreditCards
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Sync
  alias CashLens.Repo
  alias CashLens.Transactions.Transaction

  describe "normalize_amount/2 — sign conversion" do
    test "BANK + DEBIT becomes negative" do
      assert Decimal.equal?(
               Sync.normalize_amount("BANK", %{"amount" => 150.0, "type" => "DEBIT"}),
               Decimal.new("-150.0")
             )
    end

    test "BANK + CREDIT stays positive" do
      assert Decimal.equal?(
               Sync.normalize_amount("BANK", %{"amount" => 150.0, "type" => "CREDIT"}),
               Decimal.new("150.0")
             )
    end

    test "CREDIT account inverts Pluggy's positive-means-expense sign" do
      assert Decimal.equal?(
               Sync.normalize_amount("CREDIT", %{"amount" => 89.9}),
               Decimal.new("-89.9")
             )
    end

    test "CREDIT account: a Pluggy negative (payment/credit) becomes positive" do
      assert Decimal.equal?(
               Sync.normalize_amount("CREDIT", %{"amount" => -500.0}),
               Decimal.new("500.0")
             )
    end
  end

  describe "sync_account_link/2" do
    setup do
      category_fixture(%{name: "Rendimento"})
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Conta Corrente", is_credit_card: false})

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta Corrente",
          pluggy_account_type: "BANK"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)

      %{link: link, account: account, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "creates a transaction per Pluggy transaction with the normalized amount", %{
      link: link,
      account: account,
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "tx-1",
              "date" => "2026-07-15T00:00:00.000Z",
              "description" => "MERCADO XYZ",
              "amount" => 42.5,
              "type" => "DEBIT",
              "category" => "Supermarket"
            }
          ],
          "next" => nil
        })
      end)

      assert {:ok, %{created: 1, skipped: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      transaction = Repo.get_by!(Transaction, account_id: account.id, description: "MERCADO XYZ")
      assert Decimal.equal?(transaction.amount, Decimal.new("-42.5"))
      assert transaction.date == ~D[2026-07-15]
      assert transaction.pluggy_category == "Supermarket"
    end

    test "re-syncing the same transactions counts them as skipped, not duplicated", %{
      link: link,
      req_options: req_options
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{
          "results" => [
            %{
              "id" => "tx-1",
              "date" => "2026-07-15T00:00:00.000Z",
              "description" => "MERCADO XYZ",
              "amount" => 42.5,
              "type" => "DEBIT",
              "category" => "Supermarket"
            }
          ],
          "next" => nil
        })
      end)

      assert {:ok, %{created: 1, skipped: 0}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert {:ok, %{created: 0, skipped: 1}} =
               Sync.sync_account_link(link, "fake-api-key", req_options)

      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "updates last_synced_at after a successful sync", %{link: link, req_options: req_options} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        Req.Test.json(conn, %{"results" => [], "next" => nil})
      end)

      assert is_nil(link.last_synced_at)
      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)

      updated = Repo.get!(CashLens.Pluggy.AccountLink, link.id)
      assert %DateTime{} = updated.last_synced_at
    end
  end

  describe "sync_account_link/2 for a CREDIT account — statement find-or-update" do
    setup do
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Ourocard", is_credit_card: true})

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "card-1",
          pluggy_account_name: "OUROCARD",
          pluggy_account_type: "CREDIT"
        })

      {:ok, link} = Pluggy.link_account(link, account.id)
      link = CashLens.Repo.preload(link, :pluggy_item)

      %{link: link, account: account, item: item}
    end

    test "creates a statement on first sync and updates it (not a second row) on a later sync",
         %{link: link, account: account, item: item} do
      req_options = [plug: {Req.Test, CashLens.Pluggy.Client}]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "card-1",
                  "balance" => 1200.0,
                  "creditData" => %{
                    "balanceDueDate" => "2026-08-10",
                    "balanceCloseDate" => "2026-08-03"
                  }
                }
              ]
            })
        end
      end)

      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)

      statement = CreditCards.get_statement_by_account_and_competencia(account.id, ~D[2026-08-01])
      assert Decimal.equal?(statement.total_a_pagar, Decimal.new("1200.0"))
      assert statement.due_date == ~D[2026-08-10]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/v2/transactions" ->
            Req.Test.json(conn, %{"results" => [], "next" => nil})

          "/accounts" ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "id" => "card-1",
                  "balance" => 1450.0,
                  "creditData" => %{
                    "balanceDueDate" => "2026-08-10",
                    "balanceCloseDate" => "2026-08-03"
                  }
                }
              ]
            })
        end
      end)

      refreshed_link =
        Repo.get!(CashLens.Pluggy.AccountLink, link.id) |> Repo.preload(:pluggy_item)

      assert {:ok, _} = Sync.sync_account_link(refreshed_link, "fake-api-key", req_options)

      statements =
        CashLens.Repo.all(
          from s in CashLens.CreditCards.Statement,
            where: s.account_id == ^account.id and s.competencia == ^~D[2026-08-01]
        )

      assert length(statements) == 1
      assert Decimal.equal?(hd(statements).total_a_pagar, Decimal.new("1450.0"))

      _ = item
    end
  end

  describe "sync_account_link/2 — sync window" do
    setup do
      item = pluggy_item_fixture()
      account = account_fixture(%{name: "Conta Corrente"})

      {:ok, link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "acc-1",
          pluggy_account_name: "Conta Corrente",
          pluggy_account_type: "BANK"
        })

      %{item: item, account: account, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "with last_synced_at nil, requests from 90 days ago", %{
      account: account,
      item: item,
      req_options: req_options
    } do
      {:ok, link} = Pluggy.link_account(hd(Pluggy.list_account_links_for_item(item.id)), account.id)
      expected_from = Date.add(Date.utc_today(), -90) |> Date.to_iso8601()

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.query_string =~ "from=#{expected_from}"
        Req.Test.json(conn, %{"results" => [], "next" => nil})
      end)

      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)
    end

    test "with last_synced_at set, requests from that date", %{
      account: account,
      item: item,
      req_options: req_options
    } do
      {:ok, link} = Pluggy.link_account(hd(Pluggy.list_account_links_for_item(item.id)), account.id)

      past = DateTime.new!(~D[2026-05-10], ~T[00:00:00], "Etc/UTC")

      link =
        link
        |> Ecto.Changeset.change(last_synced_at: past)
        |> Repo.update!()

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        assert conn.query_string =~ "from=2026-05-10"
        Req.Test.json(conn, %{"results" => [], "next" => nil})
      end)

      assert {:ok, _} = Sync.sync_account_link(link, "fake-api-key", req_options)
    end
  end

  describe "sync_all/0" do
    test "returns {:error, :missing_credentials} when env vars are unset" do
      System.delete_env("PLUGGY_CLIENT_ID")
      System.delete_env("PLUGGY_CLIENT_SECRET")

      assert Sync.sync_all() == {:error, :missing_credentials}
    end

    test "one account failing does not stop the others from syncing" do
      System.put_env("PLUGGY_CLIENT_ID", "cid")
      System.put_env("PLUGGY_CLIENT_SECRET", "csecret")

      item = pluggy_item_fixture()
      good_account = account_fixture(%{name: "Boa"})
      bad_account = account_fixture(%{name: "Ruim"})

      {:ok, good_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "good",
          pluggy_account_name: "Boa",
          pluggy_account_type: "BANK"
        })

      {:ok, good_link} = Pluggy.link_account(good_link, good_account.id)

      {:ok, bad_link} =
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: "bad",
          pluggy_account_name: "Ruim",
          pluggy_account_type: "BANK"
        })

      {:ok, bad_link} = Pluggy.link_account(bad_link, bad_account.id)

      req_options = [plug: {Req.Test, CashLens.Pluggy.Client}]

      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" ->
            Req.Test.json(conn, %{"apiKey" => "test-key"})

          "/v2/transactions" ->
            if conn.query_string =~ "accountId=bad" do
              conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
            else
              Req.Test.json(conn, %{"results" => [], "next" => nil})
            end
        end
      end)

      results = Sync.sync_all(req_options)

      {_link, good_result} = Enum.find(results, fn {link, _} -> link.id == good_link.id end)
      {_link, bad_result} = Enum.find(results, fn {link, _} -> link.id == bad_link.id end)

      assert good_result == {:ok, %{created: 0, skipped: 0}}
      assert {:error, _reason} = bad_result
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens/pluggy/sync_test.exs`
Expected: FAIL — `CashLens.Pluggy.Sync` doesn't exist, and `CreditCards.get_statement_by_account_and_competencia/2` / `update_statement/2` don't exist yet.

- [ ] **Step 3: Add the two new `CreditCards` functions**

In `lib/cash_lens/credit_cards.ex`, add right after `get_statement!/1`:

```elixir
  def get_statement_by_account_and_competencia(account_id, %Date{} = competencia) do
    Repo.get_by(Statement, account_id: account_id, competencia: competencia)
  end

  def update_statement(%Statement{} = statement, attrs) do
    statement
    |> Statement.changeset(attrs)
    |> Repo.update()
  end
```

- [ ] **Step 4: Implement `CashLens.Pluggy.Sync`**

Create `lib/cash_lens/pluggy/sync.ex`:

```elixir
defmodule CashLens.Pluggy.Sync do
  @moduledoc """
  Orchestrates a Pluggy sync: fetch transactions for one linked account,
  normalize Pluggy's per-account-type sign convention, create them via the
  same `Transactions.create_transaction/1` the rest of the app uses (so
  dedupe, transfer matching, credit-card-payment matching, and balance
  rebuild all come for free), and — for CREDIT accounts — find-or-update
  the current statement instead of ever inserting a second one for the
  same competência.
  """

  alias CashLens.Accounting
  alias CashLens.CreditCards
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client
  alias CashLens.Transactions

  @default_lookback_days 90

  @doc """
  Reads PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET, authenticates once, and syncs
  every account link that already has a cash_lens account chosen. One
  account failing does not stop the others — each result is reported
  individually.
  """
  def sync_all(req_options \\ default_req_options()) do
    with {:ok, client_id} <- fetch_env("PLUGGY_CLIENT_ID"),
         {:ok, client_secret} <- fetch_env("PLUGGY_CLIENT_SECRET"),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options) do
      Pluggy.list_linked_account_links()
      |> Enum.map(fn link -> {link, sync_account_link(link, api_key, req_options)} end)
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, :missing_credentials}
      "" -> {:error, :missing_credentials}
      value -> {:ok, value}
    end
  end

  # Real HTTP by default; config/test.exs overrides this to `[plug: {Req.Test,
  # CashLens.Pluggy.Client}]` (Task 2, Step 5) so callers that don't pass
  # req_options explicitly — sync_all/0 as called by the Transactions page
  # button — still resolve to Req.Test in the test environment.
  defp default_req_options, do: Application.get_env(:cash_lens, :pluggy_req_options, [])

  @doc """
  Syncs one linked account: fetches transactions since its last sync (or the
  last #{@default_lookback_days} days on a first sync), creates them, and —
  for CREDIT accounts — refreshes the current statement.
  """
  def sync_account_link(account_link, api_key, req_options \\ default_req_options()) do
    from_date = from_date(account_link)

    with {:ok, pluggy_transactions} <-
           Client.list_transactions(api_key, account_link.pluggy_account_id, from_date, req_options) do
      results = Enum.map(pluggy_transactions, &import_transaction(account_link, &1))
      created = Enum.count(results, &(&1 == :created))
      skipped = Enum.count(results, &(&1 == :skipped))

      if account_link.pluggy_account_type == "CREDIT" do
        sync_statement(account_link, api_key, req_options)
      end

      {:ok, _} = Pluggy.touch_last_synced_at(account_link)

      {:ok, %{created: created, skipped: skipped}}
    end
  end

  defp from_date(%{last_synced_at: nil}),
    do: Date.add(Date.utc_today(), -@default_lookback_days)

  defp from_date(%{last_synced_at: %DateTime{} = last_synced_at}),
    do: DateTime.to_date(last_synced_at)

  defp import_transaction(account_link, pluggy_transaction) do
    attrs = %{
      account_id: account_link.account_id,
      date: parse_date(pluggy_transaction["date"]),
      description: pluggy_transaction["description"],
      amount: normalize_amount(account_link.pluggy_account_type, pluggy_transaction),
      pluggy_category: pluggy_transaction["category"]
    }

    case Transactions.create_transaction(attrs) do
      {:ok, :duplicate} -> :skipped
      {:ok, _transaction} -> :created
      {:error, _changeset} -> :skipped
    end
  end

  @doc """
  Normalizes a Pluggy transaction's amount to the cash_lens convention
  (negative = expense, positive = income).

    * `"BANK"` accounts: Pluggy's `amount` is always positive; `type`
      (`"DEBIT"` / `"CREDIT"`) says the direction.
    * `"CREDIT"` accounts: Pluggy's `amount` is already signed, but
      inverted (positive = purchase/expense) relative to cash_lens.
  """
  def normalize_amount("BANK", %{"amount" => amount, "type" => "DEBIT"}),
    do: amount |> to_decimal() |> Decimal.negate()

  def normalize_amount("BANK", %{"amount" => amount, "type" => "CREDIT"}),
    do: to_decimal(amount)

  def normalize_amount("CREDIT", %{"amount" => amount}),
    do: amount |> to_decimal() |> Decimal.negate()

  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)
  defp to_decimal(%Decimal{} = amount), do: amount

  defp parse_date(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> Date.from_iso8601!(String.slice(iso8601, 0, 10))
    end
  end

  defp sync_statement(account_link, api_key, req_options) do
    with {:ok, accounts} <-
           Client.list_accounts(api_key, account_link.pluggy_item.item_id, req_options),
         %{"creditData" => credit_data, "balance" => balance} <-
           Enum.find(accounts, &(&1["id"] == account_link.pluggy_account_id)) do
      due_date = Date.from_iso8601!(credit_data["balanceDueDate"])
      competencia = Date.beginning_of_month(due_date)
      total_a_pagar = to_decimal(balance)

      case CreditCards.get_statement_by_account_and_competencia(account_link.account_id, competencia) do
        nil ->
          CreditCards.create_statement(%{
            account_id: account_link.account_id,
            competencia: competencia,
            due_date: due_date,
            total_a_pagar: total_a_pagar,
            source_file: "pluggy"
          })

        existing ->
          CreditCards.update_statement(existing, %{due_date: due_date, total_a_pagar: total_a_pagar})
      end

      Accounting.rebuild_account_balances(account_link.account_id)
    end
  end
end
```

Note: `account_link.pluggy_item.item_id` requires `pluggy_item` to be preloaded — `Pluggy.list_linked_account_links/0` (Task 1) already preloads it, and the CREDIT-account test's setup block (Step 1) already preloads it manually via `CashLens.Repo.preload(link, :pluggy_item)` for the same reason. The BANK-account tests never call `sync_statement/3`, so they don't need it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cash_lens/pluggy/sync_test.exs`
Expected: PASS — all tests green.

- [ ] **Step 6: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS — no failures (the two new `CreditCards` functions and the `Sync` module are additive).

- [ ] **Step 7: Format and commit**

```bash
mix format
git add lib/cash_lens/credit_cards.ex lib/cash_lens/pluggy/sync.ex test/cash_lens/pluggy/sync_test.exs
git commit -m "$(cat <<'EOF'
feat(pluggy): add Sync — sign normalization, transaction import, statement dedup

Reuses Transactions.create_transaction/1 for dedupe/matching/balance
rebuild instead of reinventing it. Adds CreditCards find-or-update-by-
competência so a Pluggy sync never creates a second statement for a
month a TXT import already covered (and vice versa).
EOF
)"
```

---

### Task 4: `/pluggy` screen — register items, sync accounts, map to cash_lens accounts

**Files:**
- Create: `lib/cash_lens_web/live/pluggy_live/index.ex`
- Modify: `lib/cash_lens_web/router.ex`
- Modify: `lib/cash_lens_web/components/layouts/app.html.heex`
- Test: `test/cash_lens_web/live/pluggy_live/index_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.create_item/1`, `list_items/0`, `list_account_links_for_item/1`, `upsert_account_link/2`, `link_account/2` (Task 1). `CashLens.Pluggy.Client.list_accounts/3` (Task 2). `CashLens.Accounts.list_accounts/0` (existing).
- Produces: route `/pluggy` → `CashLensWeb.PluggyLive.Index`. No other task depends on this screen's internals.

- [ ] **Step 1: Write the failing tests**

Create `test/cash_lens_web/live/pluggy_live/index_test.exs`:

```elixir
defmodule CashLensWeb.PluggyLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy

  describe "registering an item" do
    test "creating an item via the form shows it in the list", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "abc-123", label: "Open Finance BB"})
        |> render_submit()

      assert html =~ "Open Finance BB"
      assert Pluggy.list_items() |> Enum.map(& &1.item_id) == ["abc-123"]
    end

    test "item_id is required", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html =
        live
        |> form("#pluggy-item-form", item: %{item_id: "", label: "sem id"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Pluggy.list_items() == []
    end
  end

  describe "syncing an item's accounts" do
    setup do
      System.put_env("PLUGGY_CLIENT_ID", "test-client-id")
      System.put_env("PLUGGY_CLIENT_SECRET", "test-client-secret")
      item = pluggy_item_fixture(item_id: "item-1")
      %{item: item, req_options: [plug: {Req.Test, CashLens.Pluggy.Client}]}
    end

    test "fetches accounts from Pluggy and lists them with an unmapped select", %{
      conn: conn,
      item: item
    } do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" -> Req.Test.json(conn, %{"apiKey" => "test-key"})
          "/accounts" -> Req.Test.json(conn, %{"results" => [%{"id" => "acc-1", "name" => "BANCO DO BRASIL S/A", "type" => "BANK", "balance" => 281.03}]})
        end
      end)

      {:ok, live, _html} = live(conn, ~p"/pluggy")

      html = render_click(live, "sync_accounts", %{"item_id" => item.id})

      assert html =~ "BANCO DO BRASIL S/A"
      assert [link] = Pluggy.list_account_links_for_item(item.id)
      assert link.pluggy_account_id == "acc-1"
      assert is_nil(link.account_id)
    end

    test "choosing an account in the select links it", %{conn: conn, item: item} do
      Req.Test.stub(CashLens.Pluggy.Client, fn conn ->
        case conn.request_path do
          "/auth" -> Req.Test.json(conn, %{"apiKey" => "test-key"})
          "/accounts" -> Req.Test.json(conn, %{"results" => [%{"id" => "acc-1", "name" => "BANCO DO BRASIL S/A", "type" => "BANK", "balance" => 281.03}]})
        end
      end)

      cash_lens_account = account_fixture(%{name: "Conta Corrente"})

      {:ok, live, _html} = live(conn, ~p"/pluggy")
      render_click(live, "sync_accounts", %{"item_id" => item.id})
      [link] = Pluggy.list_account_links_for_item(item.id)

      render_click(live, "link_account", %{"link_id" => link.id, "account_id" => cash_lens_account.id})

      [updated] = Pluggy.list_account_links_for_item(item.id)
      assert updated.account_id == cash_lens_account.id
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cash_lens_web/live/pluggy_live/index_test.exs`
Expected: FAIL — route `/pluggy` doesn't exist (404 / `Phoenix.Router.NoRouteError`).

- [ ] **Step 3: Add the route**

In `lib/cash_lens_web/router.ex`, inside the `live_session :default` block, add after the `/statements` line:

```elixir
      live "/pluggy", PluggyLive.Index, :index
```

- [ ] **Step 4: Implement the LiveView**

Create `lib/cash_lens_web/live/pluggy_live/index.ex`:

```elixir
defmodule CashLensWeb.PluggyLive.Index do
  use CashLensWeb, :live_view

  alias CashLens.Accounts
  alias CashLens.Pluggy
  alias CashLens.Pluggy.Client

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6 space-y-8">
      <.header>
        Pluggy
        <:subtitle>
          Cadastre um itemId de uma conexão Pluggy e associe cada conta dela a uma conta do
          cash_lens. A importação das transações roda pelo botão "Importar do Pluggy" na tela de
          Transações.
        </:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div class="lg:col-span-1">
          <div class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <h2 class="text-sm font-black uppercase opacity-50 mb-4">Novo Item</h2>
              <.form for={@form} id="pluggy-item-form" phx-submit="create_item" class="space-y-4">
                <.input field={@form[:item_id]} type="text" label="Item ID" required />
                <.input field={@form[:label]} type="text" label="Rótulo (opcional)" />
                <button type="submit" class="btn btn-primary w-full rounded-xl">
                  Cadastrar
                </button>
              </.form>
            </div>
          </div>
        </div>

        <div class="lg:col-span-2 space-y-6">
          <div :for={item <- @items} class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="font-bold">{item.label || item.item_id}</h2>
                <button
                  type="button"
                  phx-click="sync_accounts"
                  phx-value-item_id={item.id}
                  class="btn btn-outline btn-sm"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Sincronizar contas
                </button>
              </div>

              <table :if={@links_by_item[item.id]} class="table table-sm w-full">
                <thead>
                  <tr>
                    <th>Conta Pluggy</th>
                    <th>Tipo</th>
                    <th>Conta cash_lens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={link <- @links_by_item[item.id]}>
                    <td>{link.pluggy_account_name}</td>
                    <td>{link.pluggy_account_type}</td>
                    <td>
                      <form phx-change="link_account">
                        <input type="hidden" name="link_id" value={link.id} />
                        <select name="account_id" class="select select-bordered select-sm">
                          <option value="">— selecione —</option>
                          <option
                            :for={account <- @accounts}
                            value={account.id}
                            selected={link.account_id == account.id}
                          >
                            {account.name} ({account.bank})
                          </option>
                        </select>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pluggy")
     |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
     |> assign(:accounts, Accounts.list_accounts())
     |> load_items()}
  end

  @impl true
  def handle_event("create_item", %{"item" => item_params}, socket) do
    case Pluggy.create_item(item_params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"item_id" => "", "label" => ""}, as: :item))
         |> load_items()
         |> put_flash(:success, "Item cadastrado.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :item))}
    end
  end

  @impl true
  def handle_event("sync_accounts", %{"item_id" => item_id}, socket) do
    item = Pluggy.get_item!(item_id)
    client_id = System.get_env("PLUGGY_CLIENT_ID")
    client_secret = System.get_env("PLUGGY_CLIENT_SECRET")
    req_options = Application.get_env(:cash_lens, :pluggy_req_options, [])

    with true <- is_binary(client_id) and is_binary(client_secret),
         {:ok, api_key} <- Client.auth(client_id, client_secret, req_options),
         {:ok, accounts} <- Client.list_accounts(api_key, item.item_id, req_options) do
      Enum.each(accounts, fn account ->
        Pluggy.upsert_account_link(item, %{
          pluggy_account_id: account["id"],
          pluggy_account_name: account["name"],
          pluggy_account_type: account["type"]
        })
      end)

      {:noreply, socket |> load_items() |> put_flash(:success, "Contas sincronizadas.")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configurados.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao buscar contas no Pluggy.")}
    end
  end

  @impl true
  def handle_event("link_account", %{"link_id" => link_id, "account_id" => account_id}, socket) do
    account_id = if account_id == "", do: nil, else: account_id
    link = CashLens.Repo.get!(CashLens.Pluggy.AccountLink, link_id)
    {:ok, _} = Pluggy.link_account(link, account_id)

    {:noreply, load_items(socket)}
  end

  defp load_items(socket) do
    items = Pluggy.list_items()

    links_by_item =
      Map.new(items, fn item -> {item.id, Pluggy.list_account_links_for_item(item.id)} end)

    socket
    |> assign(:items, items)
    |> assign(:links_by_item, links_by_item)
  end
end
```

- [ ] **Step 5: Add a sidebar link**

In `lib/cash_lens_web/components/layouts/app.html.heex`, inside the "Cadastros" `<ul>`, add a new `<li>` right after the `/statements` one:

```heex
              <li>
                <a
                  href="/pluggy"
                  class="font-bold rounded-lg hover:bg-base-200 transition-all py-2.5 px-3 flex items-center gap-3"
                >
                  <.icon name="hero-building-library" class="size-5" />
                  <span class="menu-text">Pluggy</span>
                </a>
              </li>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/cash_lens_web/live/pluggy_live/index_test.exs`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 7: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS — the new route and sidebar link must not break any existing layout/router test.

- [ ] **Step 8: Format and commit**

```bash
mix format
git add lib/cash_lens_web/live/pluggy_live/index.ex \
        lib/cash_lens_web/router.ex \
        lib/cash_lens_web/components/layouts/app.html.heex \
        test/cash_lens_web/live/pluggy_live/index_test.exs
git commit -m "$(cat <<'EOF'
feat(pluggy): add /pluggy screen to register items and map accounts

Register an itemId, sync its accounts from Pluggy, and pick which
cash_lens account each one maps to via a plain select per row.
EOF
)"
```

---

### Task 5: "Importar do Pluggy" button on the Transactions screen

**Files:**
- Modify: `lib/cash_lens_web/live/transaction_live/index.html.heex`
- Modify: `lib/cash_lens_web/live/transaction_live/index.ex`
- Test: `test/cash_lens_web/live/transaction_live/pluggy_import_test.exs`

**Interfaces:**
- Consumes: `CashLens.Pluggy.Sync.sync_all/0` (Task 3, calling the arity-0 form so it hits the real Pluggy API) — returns `[{AccountLink.t(), {:ok, %{created: integer(), skipped: integer()}} | {:error, term()}}] | {:error, :missing_credentials}`.
- Produces: LiveView event `import_pluggy` on `CashLensWeb.TransactionLive.Index`. No other task depends on it — this is the last task in the plan.

- [ ] **Step 1: Write the failing test**

Create `test/cash_lens_web/live/transaction_live/pluggy_import_test.exs`:

```elixir
defmodule CashLensWeb.TransactionLive.PluggyImportTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy

  setup do
    item = pluggy_item_fixture()
    account = account_fixture(%{name: "Conta Corrente"})

    {:ok, link} =
      Pluggy.upsert_account_link(item, %{
        pluggy_account_id: "acc-1",
        pluggy_account_name: "Conta Corrente",
        pluggy_account_type: "BANK"
      })

    {:ok, _link} = Pluggy.link_account(link, account.id)

    %{account: account}
  end

  test "clicking Importar do Pluggy without credentials configured flashes an error", %{
    conn: conn
  } do
    System.delete_env("PLUGGY_CLIENT_ID")
    System.delete_env("PLUGGY_CLIENT_SECRET")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    html = render_click(live, "import_pluggy", %{})

    assert html =~ "PLUGGY_CLIENT_ID" or html =~ "não configuradas" or
             html =~ "não configurado"
  end

  test "the button is present in the actions menu", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/transactions")

    assert has_element?(live, "button[phx-click='import_pluggy']")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cash_lens_web/live/transaction_live/pluggy_import_test.exs`
Expected: FAIL — no `import_pluggy` button/handler exists yet.

- [ ] **Step 3: Add the button**

In `lib/cash_lens_web/live/transaction_live/index.html.heex`, inside the actions dropdown `<ul>`, add a new `<li>` right after the "Importar em Lote" one:

```heex
            <li>
              <button type="button" phx-click="import_pluggy">
                <.icon name="hero-building-library" class="size-4" /> Importar do Pluggy
              </button>
            </li>
```

- [ ] **Step 4: Add the handler**

In `lib/cash_lens_web/live/transaction_live/index.ex`, add `alias CashLens.Pluggy.Sync` near the top (alongside the existing aliases), and add the handler near the other `open_import`/`open_batch_import` handlers:

```elixir
  @impl true
  def handle_event("import_pluggy", _params, socket) do
    case Sync.sync_all() do
      {:error, :missing_credentials} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "PLUGGY_CLIENT_ID/PLUGGY_CLIENT_SECRET não configuradas no .env."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Falha ao autenticar no Pluggy.")}

      results ->
        {successes, failures} =
          Enum.split_with(results, fn {_link, result} -> match?({:ok, _}, result) end)

        created = successes |> Enum.map(fn {_link, {:ok, %{created: c}}} -> c end) |> Enum.sum()
        skipped = successes |> Enum.map(fn {_link, {:ok, %{skipped: s}}} -> s end) |> Enum.sum()

        message =
          "Pluggy: #{created} transações novas, #{skipped} já existiam" <>
            if(failures == [], do: ".", else: ", #{length(failures)} conta(s) falharam.")

        socket =
          socket
          |> assign(:page, 1)
          |> assign(:end_of_list?, false)
          |> assign(:pending_count, Transactions.count_pending_transactions())
          |> calculate_summary()
          |> stream(
            :transactions,
            Transactions.list_transactions(map_filters(socket.assigns.filters), 1),
            reset: true
          )

        {:noreply, put_flash(socket, :success, message)}
    end
  end
```

This mirrors exactly the reload block the existing `handle_info({:batch_import_finished, result}, socket)` clause already uses (same file, `lib/cash_lens_web/live/transaction_live/index.ex`) — `calculate_summary/1` and `map_filters/1` are already private functions in this module, no new helper needed.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/cash_lens_web/live/transaction_live/pluggy_import_test.exs`
Expected: PASS — 2 tests, 0 failures.

- [ ] **Step 6: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS — all tests green, no warnings.

- [ ] **Step 7: Format and commit**

```bash
mix format
git add lib/cash_lens_web/live/transaction_live/index.html.heex \
        lib/cash_lens_web/live/transaction_live/index.ex \
        test/cash_lens_web/live/transaction_live/pluggy_import_test.exs
git commit -m "$(cat <<'EOF'
feat(pluggy): add "Importar do Pluggy" button on the transactions screen

Runs Sync.sync_all/0 for every linked account in one click and flashes a
created/skipped/failed summary; missing credentials or an auth failure
surface as a flash instead of a crash.
EOF
)"
```

---

## Manual Verification (after all tasks)

1. Confirm `.env` has real `PLUGGY_CLIENT_ID`/`PLUGGY_CLIENT_SECRET` (already set earlier this session) and start the server: `export $(cat .env | xargs) && mix phx.server`.
2. Open `/pluggy`, register the known real item (`item_id: 4f8078fa-b126-4bc9-9eff-5d293b834721`, label "Open Finance BB").
3. Click "Sincronizar contas" — confirm the 3 real accounts appear (2 BANK "BANCO DO BRASIL S/A", 1 CREDIT "OUROCARD INFINITE VISA ESTILO").
4. Map the two BANK accounts (check balances against `/accounts` to tell them apart — R$281,03 vs R$24.299,55) to the correct existing cash_lens accounts, and the CREDIT one to "Ourocard".
5. Go to `/transactions`, click "Importar do Pluggy". Confirm the flash shows created/skipped counts, and the imported transactions appear in the list with the right sign (an expense shows negative, income positive) for both the BANK and CREDIT accounts.
6. Check `/statements` — confirm the Ourocard's current-month statement reflects the Pluggy-sourced due date/total, and that re-clicking "Importar do Pluggy" a second time does not create a second statement row for the same month (`credit_card_statements` count for that account/competência stays at 1).
7. Check `/accounts` — confirm the "Saldo Atual" for the synced accounts reflects the newly imported transactions.
