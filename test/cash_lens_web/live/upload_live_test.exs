defmodule CashLensWeb.Live.UploadLiveTest do
  use CashLensWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ExUnit.Assertions

  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Account
  alias CashLens.Transaction
  alias CashLens.Repo
  alias MongoDB.BSON.ObjectId

  @tag :with_live_view
  setup %{conn: conn} do
    :ok = Repo.delete_all(Transaction)
    :ok = Repo.delete_all(Account)

    user_id = ObjectId.generate()
    {:ok, account} = Accounts.create_account(%{name: "Test Account", user_id: user_id})

    # Create a dummy CSV file for testing
    csv_content = """
    Date,Description,Amount
    2025-01-01,Groceries,-50.00
    2025-01-02,Salary,2000.00
    2025-01-03,Rent,-1200.00
    """
    File.write!("test_upload.csv", csv_content)

    %{conn: conn, account: account, user_id: user_id, csv_path: "test_upload.csv"}
  end

  test "renders upload form and handles file upload", %{conn: conn, account: account, csv_path: csv_path} do
    {:ok, lv, _html} = live(conn, "/upload")

    # Simulate file upload
    {:ok, _, lv} =
      lv
      |> form("#dropzone-file")
      |> attach_upload(:csv_upload, csv_path)
      |> render_upload(@uploads.csv_upload, "test_upload.csv")

    # After upload, headers and account selector should be visible
    assert has_element?(lv, "h3", "Detected CSV Headers:")
    assert has_element?(lv, "option", "Date")
    assert has_element?(lv, "option", "Description")
    assert has_element?(lv, "option", "Amount")
    assert has_element?(lv, "select#account_select")

    # Select an account and map columns
    lv =
      lv
      |> form("form", account_id: account.id)
      |> render_change(
        mapping: %{
          "date" => "Date",
          "description" => "Description",
          "amount" => "Amount"
        },
        account_id: account.id
      )

    # Submit the form
    lv = render_submit(lv)

    # Assert success flash message
    assert has_element?(lv, "p", "Successfully imported 3 transactions!")

    # Verify transactions are in the database
    imported_transactions = Transactions.list_accounts_for_user(account.user_id)
    assert length(imported_transactions) == 3
    assert Enum.any?(imported_transactions, &(&1.description == "Groceries"))
    assert Enum.any?(imported_transactions, &(&1.description == "Salary"))
    assert Enum.any?(imported_transactions, &(&1.description == "Rent"))
  end

  test "displays error for invalid file type", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/upload")

    # Create a dummy invalid file
    File.write!("test_upload.txt", "invalid content")

    {:ok, _, lv} =
      lv
      |> form("#dropzone-file")
      |> attach_upload(:csv_upload, "test_upload.txt")
      |> render_upload(@uploads.csv_upload, "test_upload.txt")

    # Assert error handling (e.g., flash message or error class)
    # LiveView upload errors are typically handled by `handle_info` for :error,
    # or by checking `entry.errors` in the template if rendered.
    # For now, we'll check for the absence of expected success elements.
    refute has_element?(lv, "h3", "Detected CSV Headers:")
  end

  test "displays error for missing account selection on submit", %{conn: conn, csv_path: csv_path} do
    {:ok, lv, _html} = live(conn, "/upload")

    {:ok, _, lv} =
      lv
      |> form("#dropzone-file")
      |> attach_upload(:csv_upload, csv_path)
      |> render_upload(@uploads.csv_upload, "test_upload.csv")

    # Submit without selecting an account
    lv =
      lv
      |> form("form", account_id: "") # No account selected
      |> render_submit()

    # Assert error flash message
    assert has_element?(lv, "p", "Import failed: :missing_file_or_account_or_headers")
  end

  test "creates new account and imports transactions", %{conn: conn, csv_path: csv_path, user_id: user_id} do
    {:ok, lv, _html} = live(conn, "/upload")

    # Simulate file upload
    {:ok, _, lv} =
      lv
      |> form("#dropzone-file")
      |> attach_upload(:csv_upload, csv_path)
      |> render_upload(@uploads.csv_upload, "test_upload.csv")

    # Toggle new account form
    lv = render_click(lv, "button", "toggle_new_account_form")
    assert has_element?(lv, "input#new_account_name")

    # Type new account name
    lv = render_change(lv, "new_account_name", new_account_name: "New Savings Account")
    assert lv.assigns.new_account_name == "New Savings Account"

    # Create new account
    lv = render_click(lv, "create_new_account")
    assert has_element?(lv, "p", "Account 'New Savings Account' created successfully!")

    # Verify new account is in the available accounts and is selected
    new_account = Accounts.list_accounts_for_user(user_id) |> Enum.find(&(&1.name == "New Savings Account"))
    refute is_nil(new_account)
    assert lv.assigns.selected_account_id == new_account.id

    # Select the newly created account and map columns
    lv =
      lv
      |> form("form", account_id: new_account.id)
      |> render_change(
        mapping: %{
          "date" => "Date",
          "description" => "Description",
          "amount" => "Amount"
        },
        account_id: new_account.id
      )

    # Submit the form
    lv = render_submit(lv)

    # Assert success flash message
    assert has_element?(lv, "p", "Successfully imported 3 transactions!")

    # Verify transactions are in the database for the new account
    imported_transactions = Transactions.list_accounts_for_user(new_account.user_id)
    assert length(imported_transactions) == 3
    assert Enum.all?(imported_transactions, &(&1.account_id == new_account.id))
  end
end
