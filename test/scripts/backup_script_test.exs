defmodule CashLens.BackupScriptTest do
  # Drives scripts/backup.sh with stand-ins for `pg_dump` and `age` on the PATH,
  # so it needs neither a database nor an age install. The real-age round trip
  # runs only where `age` and `age-keygen` exist.
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/backup.sh", __DIR__)
  @marker "PLAINTEXT-DUMP-MARKER"
  @now "20261013_120000"

  setup do
    root = Path.join(System.tmp_dir!(), "backup_test_#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    dir = Path.join(root, "backups")
    File.mkdir_p!(bin)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(root) end)

    write_exe(bin, "pg_dump", "#!/bin/sh\necho #{@marker}\n")

    # Stand-in for age: records the recipient, "encrypts" stdin into the -o file.
    write_exe(bin, "age", """
    #!/bin/sh
    recipient=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -r) recipient="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    { echo "age-encryption.org/v1 fake recipient=$recipient"; base64; } > "$out"
    """)

    %{root: root, bin: bin, dir: dir}
  end

  defp write_exe(bin, name, content) do
    path = Path.join(bin, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp run(ctx, env \\ []) do
    base = [
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"BACKUP_DIR", ctx.dir},
      {"BACKUP_TEST_NOW", @now},
      {"BACKUP_AGE_RECIPIENT", "age1testrecipient"},
      {"BACKUP_DATABASE_URL", nil},
      {"MIGRATION_DATABASE_URL", nil}
    ]

    System.cmd("bash", [@script],
      env: Enum.uniq_by(env ++ base, &elem(&1, 0)),
      stderr_to_stdout: true
    )
  end

  defp files(dir), do: dir |> File.ls!() |> Enum.sort()

  test "aborts without BACKUP_AGE_RECIPIENT and leaves nothing behind", ctx do
    {out, status} = run(ctx, [{"BACKUP_AGE_RECIPIENT", nil}])

    assert status != 0
    assert out =~ "BACKUP_AGE_RECIPIENT"
    assert files(ctx.dir) == []
  end

  test "an empty BACKUP_AGE_RECIPIENT aborts too", ctx do
    {_out, status} = run(ctx, [{"BACKUP_AGE_RECIPIENT", ""}])
    assert status != 0
    assert files(ctx.dir) == []
  end

  test "writes one encrypted .dump.age with mode 600 and no plaintext", ctx do
    {out, 0} = run(ctx)

    assert files(ctx.dir) == ["cash_lens_backup_#{@now}.dump.age"]
    path = Path.join(ctx.dir, hd(files(ctx.dir)))

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    content = File.read!(path)
    assert content =~ "recipient=age1testrecipient"
    refute content =~ @marker
    refute out =~ @marker
  end

  test "a failing pg_dump fails the run and leaves no file at all", ctx do
    write_exe(ctx.bin, "pg_dump", "#!/bin/sh\necho partial\nexit 3\n")

    {_out, status} = run(ctx)

    assert status != 0
    assert files(ctx.dir) == []
  end

  test "a failing age fails the run and leaves no file at all", ctx do
    write_exe(ctx.bin, "age", "#!/bin/sh\ncat >/dev/null\nexit 4\n")

    {_out, status} = run(ctx)

    assert status != 0
    assert files(ctx.dir) == []
  end

  test "an ecto:// URL is handed to pg_dump as postgresql://", ctx do
    write_exe(
      ctx.bin,
      "pg_dump",
      "#!/bin/sh\nfor a; do echo \"$a\" >> \"$0.args\"; done\necho x\n"
    )

    {_out, 0} = run(ctx, [{"MIGRATION_DATABASE_URL", "ecto://owner:pw@db.example/cash_lens"}])

    args = File.read!(Path.join(ctx.bin, "pg_dump.args"))
    assert args =~ "-Fc"
    assert args =~ "postgresql://owner:pw@db.example/cash_lens"
  end

  describe "retention" do
    # `@now` is 2026-10-13, a Tuesday.
    defp stamp(date), do: Calendar.strftime(date, "%Y%m%d") <> "_030000"
    defp name(date), do: "cash_lens_backup_#{stamp(date)}.dump.age"
    defp today, do: ~D[2026-10-13]

    defp touch(ctx, date) do
      File.write!(Path.join(ctx.dir, name(date)), "x")
      name(date)
    end

    test "keeps 7 daily, 4 weekly (Sunday), 6 monthly (1st) and prunes the rest", ctx do
      assert Date.day_of_week(today()) == 2

      daily_kept = for n <- 0..6, do: touch(ctx, Date.add(today(), -n))
      # 7 days old: no longer a daily backup. 2026-10-06 is a Tuesday.
      daily_pruned = touch(ctx, Date.add(today(), -7))
      assert Date.day_of_week(Date.add(today(), -7)) == 2

      sunday_kept = touch(ctx, ~D[2026-09-27])
      sunday_pruned = touch(ctx, ~D[2026-09-13])
      assert Date.day_of_week(~D[2026-09-27]) == 7
      assert Date.day_of_week(~D[2026-09-13]) == 7

      monthly_kept = [touch(ctx, ~D[2026-08-01]), touch(ctx, ~D[2026-05-01])]
      monthly_pruned = touch(ctx, ~D[2026-04-01])

      # Not a backup name: left alone.
      File.write!(Path.join(ctx.dir, "notes.txt"), "keep")
      File.write!(Path.join(ctx.dir, "old_plaintext.dump"), "keep")

      {out, 0} = run(ctx)

      remaining = files(ctx.dir)
      today_file = "cash_lens_backup_#{@now}.dump.age"

      for kept <- daily_kept ++ [sunday_kept | monthly_kept] ++ [today_file] do
        assert kept in remaining, "#{kept} should have been kept"
      end

      for pruned <- [daily_pruned, sunday_pruned, monthly_pruned] do
        refute pruned in remaining, "#{pruned} should have been pruned"
        assert out =~ "pruned #{pruned}"
      end

      assert "notes.txt" in remaining
      assert "old_plaintext.dump" in remaining
    end

    test "a 6 day old backup is daily; a 10 day old weekday backup is not", ctx do
      six = touch(ctx, ~D[2026-10-07])
      ten = touch(ctx, ~D[2026-10-03])
      assert Date.day_of_week(~D[2026-10-03]) == 6

      {_out, 0} = run(ctx)
      remaining = files(ctx.dir)

      assert six in remaining
      refute ten in remaining
    end
  end

  describe "with the real age" do
    @describetag skip:
                   if(System.find_executable("age") && System.find_executable("age-keygen"),
                     do: false,
                     else: "age / age-keygen not installed"
                   )

    test "the backup decrypts back to the dump with the private key", ctx do
      {keygen, 0} = System.cmd("age-keygen", [])
      [_, public] = Regex.run(~r/Public key: (age1\w+)/, keygen)
      key_file = Path.join(ctx.root, "key.txt")
      File.write!(key_file, keygen)

      File.rm!(Path.join(ctx.bin, "age"))

      {_out, 0} =
        System.cmd("bash", [@script],
          env: [
            {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
            {"BACKUP_DIR", ctx.dir},
            {"BACKUP_AGE_RECIPIENT", public}
          ]
        )

      [file] = files(ctx.dir)
      refute File.read!(Path.join(ctx.dir, file)) =~ @marker

      {plain, 0} = System.cmd("age", ["-d", "-i", key_file, Path.join(ctx.dir, file)])
      assert plain =~ @marker
    end
  end
end
