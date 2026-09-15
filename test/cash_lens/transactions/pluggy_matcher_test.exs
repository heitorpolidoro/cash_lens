defmodule CashLens.Transactions.PluggyMatcherTest do
  use ExUnit.Case, async: true

  alias CashLens.Pluggy.LivePreview.Entry
  alias CashLens.Transactions.PluggyMatcher
  alias CashLens.Transactions.Transaction

  @account_id "00000000-0000-0000-0000-000000000001"
  @other_account_id "00000000-0000-0000-0000-000000000002"

  describe "annotate/3" do
    test "returns transactions untouched when entries list or map is empty or nil" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "MERCADO"
      }

      assert PluggyMatcher.annotate([tx], []) == [tx]
      assert PluggyMatcher.annotate([tx], nil) == [tx]
      assert PluggyMatcher.annotate([tx], %{}) == [tx]

      assert PluggyMatcher.annotate([], [
               %Entry{
                 id: "1",
                 account_id: @account_id,
                 date: ~D[2026-08-10],
                 amount: Decimal.new("-50.00"),
                 description: "MERCADO"
               }
             ]) == []
    end

    test "matches exact transaction (same account, amount, date) and sets pluggy_category" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-45.50"),
        description: "IFOOD *RESTAURANTE",
        pluggy_category: nil
      }

      entry = %Entry{
        id: "pluggy-1",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-45.50"),
        description: "IFOOD BRASIL",
        pluggy_category: "Restaurants"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry])
      assert annotated.pluggy_category == "Restaurants"
    end

    test "matches transaction within day tolerance (default ±4 days) and picks smallest day distance" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-100.00"),
        description: "POSTO IPIRANGA",
        pluggy_category: nil
      }

      entry_far = %Entry{
        id: "pluggy-far",
        account_id: @account_id,
        date: ~D[2026-08-13],
        amount: Decimal.new("-100.00"),
        description: "AUTO POSTO",
        pluggy_category: "Far Category"
      }

      entry_close = %Entry{
        id: "pluggy-close",
        account_id: @account_id,
        date: ~D[2026-08-11],
        amount: Decimal.new("-100.00"),
        description: "AUTO POSTO",
        pluggy_category: "Automotive"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry_far, entry_close])
      assert annotated.pluggy_category == "Automotive"
    end

    test "tie-breaks by description similarity when day distance is equal" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-30.00"),
        description: "UBER TRIP",
        pluggy_category: nil
      }

      entry_generic = %Entry{
        id: "pluggy-generic",
        account_id: @account_id,
        date: ~D[2026-08-11],
        amount: Decimal.new("-30.00"),
        description: "PAGAMENTO DIVERSO",
        pluggy_category: "Services"
      }

      entry_match_desc = %Entry{
        id: "pluggy-match",
        account_id: @account_id,
        date: ~D[2026-08-11],
        amount: Decimal.new("-30.00"),
        description: "UBER *TRIP SAO PAULO",
        pluggy_category: "Transport"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry_generic, entry_match_desc])
      assert annotated.pluggy_category == "Transport"
    end

    test "does not match across different accounts" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry = %Entry{
        id: "pluggy-diff-acc",
        account_id: @other_account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: "Shopping"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry])
      assert is_nil(annotated.pluggy_category)
    end

    test "does not match when amount differs" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry = %Entry{
        id: "pluggy-diff-amt",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.01"),
        description: "COMPRA",
        pluggy_category: "Shopping"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry])
      assert is_nil(annotated.pluggy_category)
    end

    test "does not match beyond tolerance window" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry = %Entry{
        id: "pluggy-too-far",
        account_id: @account_id,
        date: ~D[2026-08-15],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: "Shopping"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry], day_tolerance: 4)
      assert is_nil(annotated.pluggy_category)
    end

    test "skips entries with empty or nil pluggy_category" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry_nil = %Entry{
        id: "pluggy-nil",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry_empty = %Entry{
        id: "pluggy-empty",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: ""
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry_nil, entry_empty])
      assert is_nil(annotated.pluggy_category)
    end

    test "does not overwrite existing pluggy_category on transaction" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: "Already Set"
      }

      entry = %Entry{
        id: "pluggy-1",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: "New Category"
      }

      [annotated] = PluggyMatcher.annotate([tx], [entry])
      assert annotated.pluggy_category == "Already Set"
    end

    test "handles entries provided as a map of account_id => [entries]" do
      tx = %Transaction{
        id: Ecto.UUID.generate(),
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: nil
      }

      entry = %Entry{
        id: "pluggy-map",
        account_id: @account_id,
        date: ~D[2026-08-10],
        amount: Decimal.new("-50.00"),
        description: "COMPRA",
        pluggy_category: "From Map"
      }

      [annotated] = PluggyMatcher.annotate([tx], %{@account_id => [entry]})
      assert annotated.pluggy_category == "From Map"
    end
  end
end
