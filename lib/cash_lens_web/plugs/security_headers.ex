defmodule CashLensWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Sets the browser security headers: a Content-Security-Policy with a
  per-request script nonce, `x-content-type-options`, `referrer-policy`,
  `permissions-policy` and the Phoenix defaults.

  The nonce is exposed as `conn.assigns.csp_nonce`; the root layout puts it on
  its inline script, so no `unsafe-inline` is needed for scripts. Styles keep
  `unsafe-inline` because LiveView and the component library emit inline
  `style` attributes. Assets are all served from the same origin, and the
  LiveView websocket is same-origin (`connect-src 'self'`).
  """
  import Plug.Conn

  @behaviour Plug

  @permissions "camera=(), microphone=(), geolocation=(), payment=(), usb=()"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> Phoenix.Controller.put_secure_browser_headers(%{
      "content-security-policy" => policy(nonce),
      "permissions-policy" => @permissions,
      "referrer-policy" => "strict-origin-when-cross-origin"
    })
  end

  @doc "The policy string for a given script nonce."
  def policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'"
      ],
      "; "
    )
  end
end
