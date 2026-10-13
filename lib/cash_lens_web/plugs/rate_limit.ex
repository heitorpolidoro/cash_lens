defmodule CashLensWeb.Plugs.RateLimit do
  @moduledoc """
  Fixed-window rate limiter for the credential endpoints, backed by a public
  ETS table (no external infrastructure).

      plug CashLensWeb.Plugs.RateLimit, bucket: :login

  Only `POST` requests are counted. Each bucket is limited per client IP; the
  `:login` bucket is additionally limited per submitted email (case-insensitive)
  so a distributed guessing run against one account is throttled too. Over the
  limit the plug answers `429` with a `retry-after` header (seconds until the
  window ends).

  Limits come from `config :cash_lens, #{inspect(__MODULE__)}`, read on every
  request: `login: [limit: n, window_seconds: s]`, `register: [...]` and
  `trust_proxy_headers`. When true the client IP is the last
  `x-forwarded-for` entry, i.e. the address the trusted proxy itself appended;
  earlier entries are client-controlled and ignored. Enable it only behind a
  reverse proxy.
  """
  @behaviour Plug

  import Plug.Conn

  @table __MODULE__

  ## Plug

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :bucket)

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, bucket) do
    settings = Application.fetch_env!(:cash_lens, __MODULE__)
    limits = Keyword.fetch!(settings, bucket)
    limit = Keyword.fetch!(limits, :limit)
    window = Keyword.fetch!(limits, :window_seconds)

    ip = client_ip(conn, Keyword.get(settings, :trust_proxy_headers, false))
    subjects = [{:ip, ip} | email_subject(bucket, conn)]

    case Enum.find_value(subjects, &exceeded(bucket, &1, limit, window)) do
      nil -> conn
      retry_after -> reject(conn, retry_after)
    end
  end

  def call(conn, _bucket), do: conn

  defp email_subject(:login, %{params: %{"user" => %{"email" => email}}}) when is_binary(email),
    do: [{:email, email |> String.trim() |> String.downcase()}]

  defp email_subject(_bucket, _conn), do: []

  # Counts the hit; returns the seconds to wait when it is over the limit.
  defp exceeded(bucket, subject, limit, window) do
    now = System.system_time(:second)
    slot = div(now, window)
    key = {bucket, subject, slot}
    expires_at = (slot + 1) * window
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at})

    if count > limit, do: expires_at - now
  end

  defp reject(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many attempts. Try again later.")
    |> halt()
  end

  defp client_ip(conn, true) do
    case get_req_header(conn, "x-forwarded-for") do
      [] -> remote_ip(conn)
      values -> values |> Enum.join(",") |> String.split(",") |> List.last() |> String.trim()
    end
  end

  defp client_ip(conn, _), do: remote_ip(conn)

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  @doc "Forgets every counter. Used by tests."
  def reset, do: :ets.delete_all_objects(@table)
end

defmodule CashLensWeb.Plugs.RateLimit.Store do
  @moduledoc "Owns the ETS table of `CashLensWeb.Plugs.RateLimit` and sweeps expired counters."
  use GenServer

  @table CashLensWeb.Plugs.RateLimit
  @sweep_interval :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # Drops counters whose window is over.
  defp sweep do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
