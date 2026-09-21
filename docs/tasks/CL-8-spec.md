# CL-8 — Redesenhar Central de Importação Inteligente (/imports)

## Scope

CL-8 was split into CL-21..CL-27, all `done`. This respec covers **only the
integration seams the split left between children**, plus the cross-child
invariant nobody asserted. It is a small, PR-sized closing task.

Two seams:

1. **Installment regrouping is lost on the new path.** The deleted legacy modal
   (`import_modal_component.ex:129`) and `directory_importer.ex:98` both call
   `CashLens.Installments.scan_and_apply_all/0` after importing. The `/imports`
   confirm path calls `Ingestor.import_file/3` directly and never does, so a
   statement imported on the redesigned screen leaves "PARC x/y" purchases
   ungrouped until the operator remembers Admin → Database or `mix
   cash_lens.import`. CL-27 named this as a deliberate follow-up because it is
   a removal task; it belongs to the parent, which owns parity with what the
   redesign replaced.
2. **The reverse staging leak.** `handle_event("inspect", …)` assigns
   `@inspect` without calling `discard_drop/1`, so opening a folder inspection
   while a drop drawer is open leaves the drop's staging directory on disk and
   `@drop` assigned. The symmetric direction (a drop replacing a folder
   inspection) is fixed and tested; this one is a CL-24 × CL-25 seam.

Everything else the seven children shipped is verified present and is **not**
re-specified here: the route and monitored-folder card, the
Novo/Atualizado/Sincronizado labelling, the Pre-write Inspection drawer with
new-vs-duplicate counters, the universal content-detecting dropzone, the recent
history panel, and the removal of the legacy modals.

### Decision on "Forçar Download/Atualizar do Drive"

The original expected result names work that does not exist and should not be
built. There is **no Google Drive API integration anywhere in the project** —
the only two occurrences of "Drive" in `lib/` are prose (`imports.ex:17` and an
error hint in `index.ex:155`). The monitored root is a locally synced Drive
mount: the Drive client syncs it, so a "force download" would have nothing to
call. The operator-facing intent — *re-read the folder and pick up whatever
arrived* — is exactly what the shipped `#rescan-button` does, and is already
covered by a passing test. The criterion is therefore **satisfied by the rescan
button** and reworded, not implemented.

## Out of Scope — each wants its own task

- **Bulk multi-file upload.** CL-25 deliberately sets `max_entries: 1`; raising
  it changes that screen's one-detection-one-confirmation design.
- **One-shot folder-wide import from the UI.** Still available via `mix
  cash_lens.import`. It is also the missing consumer for
  `DirectoryImporter.Result.cycle_warnings`, so the two travel together.
- **Provisioning `assets/node_modules`** (no `npm install` exists anywhere) —
  build infrastructure, unrelated to this screen.
- `Reescanear` discarding an unsaved typed path (CL-23 review, non-blocking UX).
- The vacuous/imprecise assertions logged against CL-24, CL-25 and CL-26.

## Approach

**Behavior.** After a confirmed import on `/imports` that wrote at least one new
transaction — folder entry and dropped file alike — the screen runs the same
installment regrouping the replaced flows ran, and the success flash reports how
many transactions were grouped in addition to the imported/skipped counts. A
confirm that imported nothing does not run the scan and its flash carries no
installment clause.

**The flash wording is fixed, and it must not attribute the grouped count to this
file.** `Installments.scan_and_apply_all/0` is **global**: it regroups every
ungrouped transaction in the database, so its return can exceed what this import
contributed. Copy such as "N parcelas deste arquivo agrupadas" would be false
whenever older ungrouped rows exist. The clause is appended to the existing
message as:

> ` • N transações agrupadas em parcelamentos`

and is **omitted entirely when N is zero**, so results 2 and 3 are exact string
assertions rather than judgement calls. Note also the cost this puts in the
confirm handler: the regrouping re-dates parcels and rebuilds account balances,
so it is not free on a large database. Independently, opening a folder inspection while a drop
drawer is open discards the drop first, leaving no staging directory and no
`@drop` assign, exactly as a drop replacing a folder inspection already does.

**Files touched.**

- `lib/cash_lens_web/live/import_live/index.ex` — run the regrouping on the
  successful arm shared by `run_real_import/3` and `run_drop_import/3`, guarded
  on `imported > 0`; extend `imported_message/1` with the grouped count; call
  `discard_drop/1` in the `"inspect"` handler.
- `test/cash_lens_web/live/import_live_test.exs` — tests for the four criteria
  below.
- `docs/tasks/CL-8-spec.md` — this file.

**Test criteria.** A CSV fixture carrying a `PARC 03/10` description imported
through the drawer leaves its transaction with a non-nil `installment_group_id`
and an `InstallmentGroup` row; re-confirming an already-synced file imports 0
and creates no group; a folder `inspect` click issued while a staged drop exists
leaves `File.exists?/1` false for that staging directory; and one test asserts
the drawer's `#preview-new-count` / `#preview-skipped-count` equal the
`imported_count` / `skipped_count` of the `import_runs` row the same confirm
produces.

## Expected Results

- [ ] Confirming an import on `/imports` that writes at least one transaction
      runs `CashLens.Installments.scan_and_apply_all/0`: a confirmed CSV
      containing a `PARC 03/10` line leaves that transaction with a non-nil
      `installment_group_id` and creates the matching `InstallmentGroup` row.
      Holds for a folder entry and for a dropped file.
- [ ] The success flash after such an import appends exactly
      ` • N transações agrupadas em parcelamentos` to the imported/skipped
      message, with wording that does not attribute N to this file —
      `scan_and_apply_all/0` is global and its count can exceed this import's own
      contribution.
- [ ] A confirmed import that writes zero new transactions creates no
      `InstallmentGroup` row, does not run the scan, and its flash omits the
      installment clause entirely.
- [ ] Clicking `Inspecionar` on a folder entry while a dropped file's drawer is
      open discards the drop: its staging directory no longer exists, the `@drop`
      assign is `nil`, and the folder inspection renders normally.
- [ ] For a single confirmed import, the drawer's `#preview-new-count` and
      `#preview-skipped-count` equal the `imported_count` and `skipped_count` of
      the `import_runs` row it produces.
- [ ] `#rescan-button` re-reads the monitored folder and lists a file created
      after mount — the folder-refresh capability the "Forçar Download do Drive"
      criterion asked for; no Google Drive API client is added.
- [ ] `docker compose exec app mix test` passes (0 failures),
      `mix format --check-formatted` is clean, and `mix credo` reports no new
      findings in the touched files.
