defmodule CashLensWeb.ModalDefaultActionTest do
  @moduledoc """
  Guards the Enter-fires-the-primary-action behaviour of the shared modal.

  The `ModalEnter` JS hook clicks whatever element inside the open modal carries
  `data-modal-default`. The behaviour therefore lives in two halves: the hook
  (JavaScript, exercised in the browser) and the markup that opts a button in.
  These tests own the markup half, which is the half that decides whether a
  stray Enter can destroy data.
  """

  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  # Every place in lib/ allowed to carry `data-modal-default`, and why. A modal
  # whose primary action is destructive is deliberately absent: the operator
  # chose that Enter must never delete. A modal offering several equally primary
  # actions is absent too, because there is no single action for Enter to mean.
  @allowed_marks %{
    "lib/cash_lens_web/live/transaction_live/index.html.heex" => 2,
    "lib/cash_lens_web/live/reimbursement_live/index.ex" => 1,
    "lib/cash_lens_web/live/import_live/index.ex" => 1,
    "lib/cash_lens_web/live/credit_card_statement_live/index.ex" => 1
  }

  describe "the shared modal component" do
    test "installs the ModalEnter hook so Enter can reach a primary action", %{conn: conn} do
      transaction = transaction_fixture(%{description: "Consulta Dr. Roberto"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      html =
        live
        |> element("#transactions-#{transaction.id} button[phx-click='confirm_delete']")
        |> render_click()

      assert html =~ ~s(phx-hook="ModalEnter"),
             "the shared modal must carry the hook, or Enter does nothing anywhere"
    end
  end

  describe "destructive confirmations" do
    test "the delete-transaction modal marks no default action", %{conn: conn} do
      transaction = transaction_fixture(%{description: "Consulta Dr. Roberto"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("#transactions-#{transaction.id} button[phx-click='confirm_delete']")
      |> render_click()

      # The button exists and is reachable by click (CL-10) -- it simply must
      # not be what Enter fires.
      assert has_element?(live, "#confirm-delete-transaction-btn")

      refute has_element?(live, "#confirm-modal [data-modal-default]"),
             "Enter would delete a transaction"
    end

    test "the delete-category modal marks no default action", %{conn: conn} do
      category = category_fixture(%{name: "Mercado"})
      {:ok, live, _html} = live(conn, ~p"/categories")

      live
      |> element("button[phx-click='confirm_delete'][phx-value-id='#{category.id}']")
      |> render_click()

      refute has_element?(live, "#confirm-modal [data-modal-default]"),
             "Enter would delete a category"
    end

    test "the delete-account modal marks no default action", %{conn: conn} do
      account = account_fixture(%{name: "Conta de Teste"})
      {:ok, live, _html} = live(conn, ~p"/accounts")

      live
      |> element("button[phx-click='confirm_delete'][phx-value-id='#{account.id}']")
      |> render_click()

      refute has_element?(live, "#confirm-modal [data-modal-default]"),
             "Enter would delete an account"
    end
  end

  describe "safe modals" do
    test "the notes modal marks its save button as the default action", %{conn: conn} do
      transaction = transaction_fixture(%{description: "Consulta Dr. Roberto"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("button[phx-click='open_notes'][phx-value-id='#{transaction.id}']")
      |> render_click()

      assert has_element?(live, "#notes-modal button[type='submit'][data-modal-default]")
    end
  end

  describe "the opt-in allowlist" do
    # A runtime test can only cover the modals it can open, and the dangerous
    # change is someone adding the attribute somewhere new -- most of all onto a
    # destructive button in a modal no test here opens. This counts every
    # occurrence in lib/ against the list above, so a new one fails until it is
    # added deliberately.
    test "no file carries an unaccounted data-modal-default" do
      found =
        "lib/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.map(fn path ->
          count =
            path
            |> File.read!()
            |> then(&Regex.scan(~r/data-modal-default/, &1))
            |> length()

          {path, count}
        end)
        |> Enum.reject(fn {_path, count} -> count == 0 end)
        |> Map.new()

      assert found == @allowed_marks, """
      The set of data-modal-default marks changed.

      Found:    #{inspect(found, pretty: true)}
      Allowed:  #{inspect(@allowed_marks, pretty: true)}

      Enter fires whatever carries this attribute. Before updating the list,
      confirm the newly marked button is not destructive and is genuinely the
      modal's single primary action.
      """
    end
  end
end
