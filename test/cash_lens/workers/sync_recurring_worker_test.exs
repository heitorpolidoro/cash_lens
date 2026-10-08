defmodule CashLens.Workers.SyncRecurringWorkerTest do
  use CashLens.DataCase, async: false
  use Oban.Testing, repo: CashLens.Repo

  alias CashLens.Forecast
  alias CashLens.Workers.SyncRecurringWorker

  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  defp history_date(months_back, day) do
    today = Date.utc_today()
    month = today.month - months_back
    {year, month} = if month <= 0, do: {today.year - 1, month + 12}, else: {today.year, month}
    Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  test "perform/1 derives the registered accounts from history" do
    category = category_fixture(%{type: "fixed", name: "Luz"})
    account = account_fixture()

    for n <- 0..2 do
      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(n, 14),
        amount: "-334.16"
      })
    end

    assert :ok = perform_job(SyncRecurringWorker, %{})

    assert [item] = Forecast.list_recurring_items()
    assert item.label == "Luz"
    assert item.day_of_month == 14
  end

  test "perform/1 announces what it did, so the screen in front of someone says so" do
    # The run happens seconds after the import, in another process. Without the
    # broadcast its result reaches nobody.
    category = category_fixture(%{type: "fixed", name: "Luz"})
    account = account_fixture()

    for n <- 0..2 do
      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: history_date(n, 14),
        amount: "-334.16"
      })
    end

    Phoenix.PubSub.subscribe(CashLens.PubSub, CashLensWeb.RecurringSyncFlash.topic())

    assert :ok = perform_job(SyncRecurringWorker, %{})

    assert_receive {:recurring_synced, %{created: 1, updated: 0, deactivated: 0}}
  end

  test "perform/1 with nothing to derive still succeeds" do
    assert :ok = perform_job(SyncRecurringWorker, %{})
    assert Forecast.list_recurring_items() == []
  end

  test "enqueue/0 queues one job" do
    assert :ok = SyncRecurringWorker.enqueue()
    assert_enqueued(worker: SyncRecurringWorker)
  end

  test "the job waits a few seconds, so the rest of a batch can join it" do
    # The two numbers are different things: this delay is how long to wait for
    # the rest of an import, the uniqueness period is how far back to look for a
    # request already waiting.
    assert :ok = SyncRecurringWorker.enqueue()

    assert [job] = Repo.all(Oban.Job)
    assert job.state == "scheduled"

    # The bound is written out rather than read from the worker: comparing the
    # constant against itself would accept any value, including the minutes that
    # would make the forecast look broken to whoever just imported.
    waited = DateTime.diff(job.scheduled_at, DateTime.utc_now())
    assert waited > 0
    assert waited <= 30
    assert SyncRecurringWorker.delay_seconds() <= 30
  end

  test "a second request while the first is still waiting is the same request" do
    # The delay is what makes this bite on a real import: without it the first
    # job ran and finished between two files, and every file queued its own.
    assert :ok = SyncRecurringWorker.enqueue()
    assert :ok = SyncRecurringWorker.enqueue()

    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "a request made after a run is a new request" do
    # Otherwise the last file of a batch would go unaccounted for: a finished
    # job never saw the rows written after it.
    assert :ok = SyncRecurringWorker.enqueue()
    Oban.drain_queue(queue: :default, with_scheduled: true)
    assert :ok = SyncRecurringWorker.enqueue()

    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "a request made while a run is in flight is not swallowed by it" do
    # A job that has already started cannot see rows written after it started,
    # so it must not stand in for a later request.
    assert :ok = SyncRecurringWorker.enqueue()

    [job] = Repo.all(Oban.Job)
    {:ok, _} = job |> Ecto.Changeset.change(state: "executing") |> Repo.update()

    assert :ok = SyncRecurringWorker.enqueue()
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "enqueue/0 never fails the import that called it" do
    # An import that wrote its rows has done its job: a projection that
    # refreshes on the next import is the smaller problem.
    defmodule MockObanError do
      def insert(_changeset), do: {:error, :boom}
    end

    Application.put_env(:cash_lens, :oban_module, MockObanError)
    on_exit(fn -> Application.delete_env(:cash_lens, :oban_module) end)

    assert :ok = SyncRecurringWorker.enqueue()
    refute_enqueued(worker: SyncRecurringWorker)
  end
end
