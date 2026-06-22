defmodule CashLens.Transactions.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "transactions" do
    field :date, :date
    field :time, :time
    field :description, :string
    field :amount, :decimal
    field :transfer_key, Ecto.UUID
    field :reimbursement_status, :string
    field :reimbursement_link_key, Ecto.UUID
    field :fingerprint, :string
    # The un-hashed dedupe base key: "account_id|date|cents|normalized_description".
    # Persisted (not just hashed) so the occurrence-index can be computed with a
    # cheap, exact `GROUP BY dedup_key` against already-stored rows. See the
    # moduledoc-level notes on `dedup_key/1` and `fingerprint/2`.
    field :dedup_key, :string
    # Virtual: the 0-based occurrence index among otherwise-identical rows
    # (same dedup_key). Callers that know the index (the importer, the single
    # create path, the mirror insert) set it so the fingerprint is computed
    # against it. Defaults to 0.
    field :occurrence_index, :integer, virtual: true, default: 0
    # Virtual: on-the-fly category suggestion derived from how identical
    # (normalized) descriptions were categorized in the past. Filled by
    # CategorySuggester.annotate/1; never persisted.
    field :suggested_category, :map, virtual: true
    field :notes, :string
    field :installment_number, :integer
    belongs_to :account, CashLens.Accounts.Account
    belongs_to :category, CashLens.Categories.Category
    belongs_to :installment_group, CashLens.Installments.InstallmentGroup

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
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
      :installment_group_id,
      :installment_number,
      :occurrence_index
    ])
    |> validate_required([:date, :description, :amount, :account_id])
    |> put_dedup_key()
    |> generate_fingerprint()
    |> unique_constraint(:fingerprint)
  end

  defp identity_attrs(changeset) do
    %{
      date: get_field(changeset, :date),
      time: get_field(changeset, :time),
      description: get_field(changeset, :description),
      amount: get_field(changeset, :amount),
      account_id: get_field(changeset, :account_id)
    }
  end

  defp identity_changed?(changeset) do
    Enum.any?(
      [:date, :time, :description, :amount, :account_id],
      &Map.has_key?(changeset.changes, &1)
    )
  end

  defp put_dedup_key(changeset) do
    if identity_changed?(changeset) or is_nil(get_field(changeset, :dedup_key)) do
      case dedup_key(identity_attrs(changeset)) do
        nil -> changeset
        key -> put_change(changeset, :dedup_key, key)
      end
    else
      changeset
    end
  end

  defp generate_fingerprint(changeset) do
    if identity_changed?(changeset) or is_nil(get_field(changeset, :fingerprint)) do
      index = get_field(changeset, :occurrence_index) || 0

      case fingerprint(identity_attrs(changeset), index) do
        nil -> changeset
        hash -> put_change(changeset, :fingerprint, hash)
      end
    else
      changeset
    end
  end

  @doc """
  Builds the un-hashed dedupe base key for a transaction.

  The base key is the stable *identity* of a charge, independent of how many
  times that identical charge legitimately occurs:

      "account_id|YYYY-MM-DD|HH:MM:SS|integer_cents|normalized_description"

  Returns `nil` when any *required* identity-bearing field is missing
  (`date`, `description`, `amount`, `account_id`). `time` is optional in the
  input map and is always normalized to a stable value (see below).

  Why these inputs (and not others):

    * **`time` is a discriminator, but always normalized to ONE stable form.**
      It is normalized in a single place (`normalize_time/1`): a real time is
      rendered as zero-padded `HH:MM:SS`, while an absent/unparseable time
      (e.g. credit-card "fatura" postings whose Ourocard OFX `DTPOSTED` is
      date-only, and CSV/PDF exports with no time) ALWAYS maps to the fixed
      constant `00:00:00`. The fixed constant is the crucial part: it removes
      the original root cause of duplication, where an absent time could flip
      between "value" and "empty" across re-exports and produce two different
      fingerprints for the same charge. Debit-card transactions carry reliable
      distinct times, so two same-day same-amount same-merchant debits at
      different times get distinct base keys and are both preserved. Two
      genuinely distinct same-day credit purchases both normalize to `00:00:00`,
      share a base key, and are kept apart by the occurrence-index instead.

    * **`amount` is canonicalized to integer cents.** `Decimal.to_string/1` is
      scale-sensitive ("100" vs "100.00" render differently), so two exports of
      the same charge with different trailing zeros must not diverge.

    * **`description` is canonicalized** (whitespace collapsed, trimmed,
      upcased, diacritics stripped) so the OFX/CSV/PDF spellings of one merchant
      converge. Installments self-disambiguate because the raw memo carries the
      "PARC xx/yy" marker, which survives normalization and lands in the key
      (the merchant-base cleanup in `Installments.link_and_clean/4` runs *after*
      insert via `update_all`, deliberately not recomputing the fingerprint).
  """
  @spec dedup_key(map()) :: String.t() | nil
  def dedup_key(%{date: date, description: desc, amount: amount, account_id: account_id} = attrs)
      when not is_nil(date) and not is_nil(desc) and not is_nil(amount) and not is_nil(account_id) do
    [
      normalize_account_id(account_id),
      normalize_date(date),
      normalize_time(Map.get(attrs, :time)),
      normalize_amount(amount),
      normalize_description(desc)
    ]
    |> Enum.join("|")
  end

  def dedup_key(_attrs), do: nil

  # Accepts a Date struct or an ISO-8601 string (form params arrive as strings
  # before the changeset casts them).
  defp normalize_date(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_date(date) when is_binary(date), do: date

  # The single, canonical place where the time component of the dedupe key is
  # produced. An absent or unparseable time ALWAYS collapses to the fixed
  # constant @default_time ("00:00:00") so it can never flip between "value" and
  # "empty" across re-exports (the original duplication root cause). A real time
  # is rendered as zero-padded HH:MM:SS (seconds truncated), giving one canonical
  # string regardless of microsecond precision or source format.
  @default_time "00:00:00"

  defp normalize_time(%Time{} = time) do
    time
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  defp normalize_time(time) when is_binary(time) do
    case Time.from_iso8601(time) do
      {:ok, parsed} -> normalize_time(parsed)
      _ -> @default_time
    end
  end

  defp normalize_time(_), do: @default_time

  @doc """
  Computes the dedupe fingerprint for a transaction at a given occurrence index.

  The fingerprint is a SHA-256 hex string over `"<dedup_key>|<occurrence_index>"`.

  The `occurrence_index` is the 0-based ordinal of this row among otherwise
  identical rows (same `dedup_key`). It makes the scheme both:

    * **stable on re-import** — re-importing the exact same statement reproduces
      the same ordinals, so the N identical lines dedupe and zero duplicates are
      created; and
    * **preserving** — two genuinely distinct but identical same-day purchases
      get ordinals 0 and 1, so both survive the unique index.

  The caller is responsible for choosing the correct index (existing matching
  rows in the DB + position within the incoming batch). See
  `CashLens.Parsers.Ingestor` for the batch computation.

  Returns `nil` when any identity-bearing field is missing.
  """
  @spec fingerprint(map(), non_neg_integer()) :: String.t() | nil
  def fingerprint(attrs, occurrence_index \\ 0)

  def fingerprint(attrs, occurrence_index) do
    case dedup_key(attrs) do
      nil -> nil
      key -> :crypto.hash(:sha256, "#{key}|#{occurrence_index}") |> Base.encode16()
    end
  end

  @doc """
  Canonical description normalization shared everywhere the dedupe key is built.

  Collapses internal whitespace, trims, upcases and strips diacritics so the
  different parser spellings of the same charge converge.
  """
  @spec normalize_description(String.t()) :: String.t()
  def normalize_description(desc) do
    desc
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.upcase()
    |> strip_diacritics()
    |> String.replace(~r/(.{3,})\s*BR$/u, "\\1")
    |> String.trim()
  end

  # Decomposes accented characters (NFD) and drops the combining marks, e.g.
  # "SÃO JOSÉ" -> "SAO JOSE".
  defp strip_diacritics(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  # Scale-stable amount: integer cents as a string. Accepts Decimal or any value
  # Decimal.new/1 understands (e.g. a numeric string from a parser).
  defp normalize_amount(%Decimal{} = amount) do
    amount
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> Integer.to_string()
  end

  defp normalize_amount(amount), do: amount |> Decimal.new() |> normalize_amount()

  # binary_id may arrive as a raw 16-byte binary or as a UUID string.
  defp normalize_account_id(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp normalize_account_id(account_id), do: account_id
end
