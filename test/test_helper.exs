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

exclusions = if euid == 0, do: [exclude: [:requires_unprivileged_user]], else: []

ExUnit.start(exclusions)
Mox.defmock(CashLens.Parsers.PDFConverterMock, for: CashLens.Parsers.PDFConverter)
Mox.defmock(CashLens.Transactions.RepoMock, for: CashLens.Transactions.RepoBehaviour)
Ecto.Adapters.SQL.Sandbox.mode(CashLens.Repo, :manual)
