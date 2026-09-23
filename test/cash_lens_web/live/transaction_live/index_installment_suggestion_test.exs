defmodule CashLensWeb.TransactionLive.IndexInstallmentSuggestionTest do
  @moduledoc """
  Guards the on-demand installment suggestion on the transactions index.

  Rendering a page of transactions must not touch `installment_groups` once per
  row: the suggestion is resolved only when the row's "Grupo de Parcelamento"
  menu is opened, and memoized afterwards.
  """

  use CashLensWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures

  alias CashLens.Installments
  alias CashLens.Repo
  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  # Counts every Repo query whose SQL mentions `installment_groups`, which is
  # exactly the work this task moves off the render path.
  defp attach_installment_group_query_counter do
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:cash_lens, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        query = Map.get(metadata, :query, "")

        if is_binary(query) and String.contains?(query, "installment_groups") do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    counter
  end

  defp query_count(counter), do: :counters.get(counter, 1)

  defp reset(counter), do: :counters.put(counter, 1, 0)

  defp installment_button(live, tx), do: element(live, "#installment-menu-#{tx.id}")

  setup do
    {:ok, in_progress} =
      Installments.create_installment_group(%{
        description_pattern: "ACADEMIA",
        total_amount: "300.00",
        installments: 3,
        start_date: Date.utc_today()
      })

    matching = transaction_fixture(%{amount: "-100.00", description: "ACADEMIA MENSALIDADE"})

    %{in_progress: in_progress, matching: matching}
  end

  # A group whose parcels are all linked already: it must never be suggested.
  # Kept out of the shared setup so the pages under the zero-query assertions
  # carry no transaction linked to a group, and therefore no association
  # preload either.
  defp completed_group_transaction do
    {:ok, completed} =
      Installments.create_installment_group(%{
        description_pattern: "COMPLETO",
        total_amount: "200.00",
        installments: 2,
        start_date: Date.utc_today()
      })

    for description <- ["COMPLETO a", "COMPLETO b"] do
      paid = transaction_fixture(%{amount: "-100.00", description: description})

      Repo.update_all(
        from(t in Transaction, where: t.id == ^paid.id),
        set: [installment_group_id: completed.id]
      )
    end

    transaction_fixture(%{amount: "-100.00", description: "COMPLETO c"})
  end

  describe "installment suggestion on the transactions index" do
    test "a full render of the page issues no installment_groups query", %{
      conn: conn,
      matching: matching
    } do
      counter = attach_installment_group_query_counter()
      {:ok, live, _html} = live(conn, ~p"/transactions")

      # The static `@installment_groups` list is loaded once in `mount/3`; what
      # this task removes is the per-row query, so the counter is reset and a
      # full re-render of every row is then forced.
      reset(counter)
      html = render_click(live, "clear_filters", %{})

      assert html =~ matching.description
      assert query_count(counter) == 0
    end

    test "the render cost does not grow with the number of matching rows", %{conn: conn} do
      counter = attach_installment_group_query_counter()

      {:ok, _live, _html} = live(conn, ~p"/transactions")
      one_row = query_count(counter)

      for n <- 1..10 do
        transaction_fixture(%{amount: "-100.00", description: "ACADEMIA MENSALIDADE #{n}"})
      end

      reset(counter)
      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ "ACADEMIA MENSALIDADE 10"
      assert query_count(counter) == one_row
    end

    test "opening the menu resolves the suggestion and matches suggest_installment_link/1", %{
      conn: conn,
      matching: matching
    } do
      counter = attach_installment_group_query_counter()
      {:ok, live, _html} = live(conn, ~p"/transactions")
      reset(counter)

      refute render(live) =~ "Vincular a"

      html = render_click(installment_button(live, matching))

      suggestion = Transactions.suggest_installment_link(matching)

      assert html =~
               "Vincular a #{suggestion.group_name}? (#{suggestion.next_installment}/#{suggestion.total_installments})"

      assert html =~ "Vincular a ACADEMIA? (1/3)"
      assert query_count(counter) > 0
    end

    test "a transaction matching a completed group gets no suggestion", %{conn: conn} do
      completed_tx = completed_group_transaction()
      {:ok, live, _html} = live(conn, ~p"/transactions")

      html = render_click(installment_button(live, completed_tx))

      refute html =~ "Vincular a"
    end

    test "opening the same menu twice issues no further installment_groups query", %{
      conn: conn,
      matching: matching
    } do
      counter = attach_installment_group_query_counter()
      {:ok, live, _html} = live(conn, ~p"/transactions")

      render_click(installment_button(live, matching))
      after_first_open = query_count(counter)
      assert after_first_open > 0

      html = render_click(installment_button(live, matching))

      assert html =~ "Vincular a ACADEMIA? (1/3)"
      assert query_count(counter) == after_first_open
    end
  end
end
