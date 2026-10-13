defmodule CashLens.Audit do
  @moduledoc "Login audit log."
  import Ecto.Query

  alias CashLens.Audit.LoginAttempt
  alias CashLens.Repo

  @doc "Records one login attempt. `user` is nil when the email is unknown."
  def record_login_attempt(user, email, success, ip) do
    Repo.insert!(%LoginAttempt{
      user_id: user && user.id,
      email: email |> to_string() |> String.slice(0, 160),
      success: success,
      ip: to_string(ip)
    })
  end

  def list_login_attempts(limit \\ 100) do
    Repo.all(from a in LoginAttempt, order_by: [desc: a.inserted_at], limit: ^limit)
  end
end
