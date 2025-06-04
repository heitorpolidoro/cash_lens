defmodule CashLensWeb.ParsersLiveHTML do
  use Phoenix.Component
  import SaladUI.Table
  import SaladUI.Button
  import SaladUI.Tooltip
  import SaladUI.Input
  import SaladUI.Form
  import SaladUI.Label

  alias CashLens.Parsers
  alias CashLens.Users.User

  embed_templates "parsers_live_html/*"

end
