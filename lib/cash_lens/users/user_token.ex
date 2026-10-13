defmodule CashLens.Users.UserToken do
  @moduledoc """
  Single-use email tokens (`confirm` and `reset_password`). Only the SHA-256
  hash is stored; the raw token exists only in the emailed link.
  """
  use Ecto.Schema
  import Ecto.Query

  @rand_size 32
  @confirm_validity_days 7
  @reset_validity_hours 1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_tokens" do
    field :token, :binary, redact: true
    field :context, :string
    field :sent_to, :string
    belongs_to :user, CashLens.Users.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Returns `{url_safe_raw_token, %UserToken{}}` for `user` and `context`."
  def build(user, context) when context in ["confirm", "reset_password"] do
    raw = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(raw, padding: false),
     %__MODULE__{
       token: hash(raw),
       context: context,
       sent_to: user.email,
       user_id: user.id
     }}
  end

  @doc "Query for `{user, token}` a raw token resolves to, or `:error` for a malformed one."
  def verify_query(raw, context) when is_binary(raw) do
    case Base.url_decode64(raw, padding: false) do
      {:ok, decoded} ->
        {:ok,
         from(t in by_token_and_context(hash(decoded), context),
           join: u in assoc(t, :user),
           where: t.inserted_at > ^cutoff(context) and t.sent_to == u.email,
           select: {u, t}
         )}

      :error ->
        :error
    end
  end

  def verify_query(_raw, _context), do: :error

  def by_token_and_context(hashed, context),
    do: from(t in __MODULE__, where: t.token == ^hashed and t.context == ^context)

  def by_user_and_contexts(user_id, contexts),
    do: from(t in __MODULE__, where: t.user_id == ^user_id and t.context in ^contexts)

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  defp cutoff("confirm"), do: DateTime.add(DateTime.utc_now(), -@confirm_validity_days, :day)

  defp cutoff("reset_password"),
    do: DateTime.add(DateTime.utc_now(), -@reset_validity_hours, :hour)
end
