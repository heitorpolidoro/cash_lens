defmodule CashLens.AuditTest do
  use CashLens.DataCase, async: true

  import CashLens.UsersFixtures
  alias CashLens.Audit

  test "records and lists attempts, nil user allowed" do
    user = user_fixture()
    Audit.record_login_attempt(user, user.email, true, "1.2.3.4")
    Audit.record_login_attempt(nil, "ghost@example.com", false, "127.0.0.1")

    attempts = Audit.list_login_attempts()
    assert length(attempts) == 2
    assert Enum.find(attempts, &(&1.email == "ghost@example.com")).user_id == nil
    assert Enum.find(attempts, &(&1.email == user.email)).success
  end
end
