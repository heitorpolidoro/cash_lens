defmodule CashLens.Users.UserNotifier do
  @moduledoc "Delivers the account emails (confirmation and password reset)."
  import Swoosh.Email

  alias CashLens.Mailer

  defp deliver(recipient, subject, body) do
    from = Application.get_env(:cash_lens, :mail_from, {"CashLens", "noreply@example.com"})

    email =
      new()
      |> to(recipient)
      |> from(from)
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email), do: {:ok, email}
  end

  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your CashLens account", """

    Hi #{user.email},

    Confirm your account by visiting the link below:

    #{url}

    If you did not create an account, ignore this email.
    """)
  end

  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset your CashLens password", """

    Hi #{user.email},

    Reset your password by visiting the link below (valid for one hour):

    #{url}

    If you did not request this, ignore this email.
    """)
  end
end
