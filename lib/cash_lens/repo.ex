defmodule CashLens.Repo do
  use Ecto.Repo,
    otp_app: :cash_lens,
    adapter: Ecto.Adapters.Postgres
end
