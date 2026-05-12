ExUnit.start()
Mox.defmock(CashLens.Parsers.PDFConverterMock, for: CashLens.Parsers.PDFConverter)
Mox.defmock(CashLens.Transactions.RepoMock, for: CashLens.Transactions.RepoBehaviour)
Ecto.Adapters.SQL.Sandbox.mode(CashLens.Repo, :manual)
