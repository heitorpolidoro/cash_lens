defmodule CashLensWeb.AccountsLive do
  use CashLensWeb, :live_view
  import CashLensWeb.BaseLive
  use CashLensWeb.BaseLive
  on_mount CashLensWeb.BaseLive

  alias CashLens.Accounts.Account
  alias CashLens.Parsers

  def render(assigns) do
    ~H"""
      <.crud {assigns}
        target={Account}
        formatter={
          %{
            parser: &Parsers.format_parser/1,
            type: :capitalize
          }
        }
        default_value={%{user_id: assigns.current_user.id}}
        hidden_fields={[:user_id]}
      />
    """
  end
end
