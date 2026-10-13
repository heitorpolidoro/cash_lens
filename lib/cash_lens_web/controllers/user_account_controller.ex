defmodule CashLensWeb.UserAccountController do
  use CashLensWeb, :controller

  alias CashLens.Privacy

  def show(conn, _params) do
    render(conn, :show, layout: {CashLensWeb.Layouts, :app})
  end

  def export(conn, _params) do
    body = conn.assigns.current_user |> Privacy.export() |> Jason.encode!(pretty: true)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="cash_lens_account.json"))
    |> send_resp(200, body)
  end

  def delete(conn, params) do
    password = get_in(params, ["account", "password"])

    case Privacy.delete_account(conn.assigns.current_user, password) do
      {:ok, _} ->
        conn
        |> configure_session(drop: true)
        |> redirect(to: ~p"/users/log_in")

      {:error, _} ->
        conn
        |> put_flash(:error, "Wrong password. Nothing was deleted.")
        |> redirect(to: ~p"/account")
    end
  end
end
