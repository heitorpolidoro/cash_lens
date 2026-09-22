# A few tests assert that the app copes with a file it cannot read. Root ignores
# file permission bits, so `File.chmod(path, 0o000)` does not make a file
# unreadable for it and those tests can never pass — the app container runs as
# root, the host normally does not. Exclude them when privileged rather than
# leaving a test that fails for a reason unrelated to the code.
euid =
  case System.cmd("id", ["-u"]) do
    {out, 0} -> out |> String.trim() |> String.to_integer()
    _ -> nil
  end

privileged_exclusions = if euid == 0, do: [:requires_unprivileged_user], else: []

# :real_statements is excluded UNCONDITIONALLY, unlike :requires_unprivileged_user
# above. The two tags are excluded for different reasons: that one is about
# privilege, this one is about opt-in. :real_statements reads the operator's
# Google Drive folder through CASH_LENS_MP_PDF_DIR, which the container does not
# mount and which no other machine has, so it must stay off by default even on
# the host. Run it with `mix test --include real_statements`.
ExUnit.start(exclude: [:real_statements | privileged_exclusions])
Mox.defmock(CashLens.Parsers.PDFConverterMock, for: CashLens.Parsers.PDFConverter)
Mox.defmock(CashLens.Transactions.RepoMock, for: CashLens.Transactions.RepoBehaviour)
Ecto.Adapters.SQL.Sandbox.mode(CashLens.Repo, :manual)
