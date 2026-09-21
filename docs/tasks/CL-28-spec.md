# CL-28 — Remove the Gemini CLI leftovers from the dev image

## Scope

Remove the Gemini CLI from the development container image and the Docker state that
supported it: the global `npm install -g @google/gemini-cli` layer in `Dockerfile`, the
`gemini_data:/root/.gemini` mount and the `gemini_data` volume declaration in
`docker-compose.yml`, and the orphaned `cash_lens_gemini_data` Docker volume.

This task is infrastructure only. It touches no Elixir source, no migration and no test
file, so **no `mix quality_check`, `credo --strict` or test-suite gate applies** — there is
no Elixir change for such a gate to evaluate. **There is no UI, so no HTML mockup is
produced for this task.**

Two premises carried on the board are wrong, and this spec resolves them against evidence
rather than repeating them (see *Findings that change the task*, below): `nodejs npm` must
**stay** in the `apk` line, and the `cash_lens_gemini_data` volume holds **no credential**.

## Findings that change the task

**1. `nodejs`/`npm` are still required — do not remove them from `Dockerfile:4`.**
The premise was that assets build purely through the esbuild and tailwind Elixir wrappers.
The wrappers are indeed standalone native binaries and need no Node *runtime* — but the
bundle they build has real npm dependencies:

- `assets/js/app.js` lines 5–7 import `chart.js/auto`, `dompurify` and `flatpickr`.
- `assets/package.json` declares those three as `dependencies`.
- esbuild is configured with `cd: assets` (`config/config.exs`), so it resolves those bare
  imports from `assets/node_modules` on the filesystem.
- `assets/node_modules` is gitignored (`.gitignore:39`) and **nothing in the repo ever
  installs it** — there is no `npm install` in any script, alias, compose command or
  workflow. The only `npm install` in the whole repo is the gemini-cli line being deleted.
- `docker-compose.yml` bind-mounts `.:/app`, so the container reads the host's
  `assets/node_modules`. It works today only because that directory happens to be populated
  out of band.

Removing `npm` from the image would leave a fresh clone with no way to populate
`assets/node_modules` and no way to diagnose why the bundle fails. So `npm` stays, and this
task converts the currently accidental dependency into an explicit, enforced one.

**2. The `cash_lens_gemini_data` volume is empty — there is no credential to revoke.**
Inspected read-only; `/root/.gemini` inside the volume contains nothing, no
`oauth_creds.json`. Removing it is ordinary disk cleanup, not credential disposal. The
implementer must re-verify immediately before deleting (below) and, **only if a credential
has appeared in the meantime**, revoke it on Google's side first — deleting a volume does
not invalidate a token.

**3. `workspace_gemini_data` does not exist.** `docker volume ls` lists exactly one matching
volume, `cash_lens_gemini_data`. The board criterion naming a second one is stale; no action.

**4. `GEMINI.md` is out of scope — explicitly.** The surviving references live in
`.github/copilot-instructions.md` (lines 44, 45, 55, 62, 78) and describe an *agent
instruction file*, not the CLI. `GEMINI.md` and `.gemini/agents/*` are already deleted in the
working tree by unrelated in-flight work. Cleaning up that stale prose is a different
concern and is **not** done here. Consequently the grep criterion is scoped to the three
CLI-specific patterns, not to the word "gemini".

## Approach

**Behavior once done.** The image no longer contains the Gemini CLI or its global npm tree,
and no container path or volume is reserved for `/root/.gemini`. Both start modes still
bring the app up on http://localhost:4444, and the asset bundle still builds with its three
npm dependencies resolved. The image is measurably smaller.

**Files touched.**

- `Dockerfile` — delete the `# Install Gemini CLI` comment and the
  `RUN npm install -g @google/gemini-cli --unsafe-perm` line (lines 6–7). Keep `nodejs npm`
  on the `apk` line (line 4) and add a short comment there recording *why* they are kept
  (`assets/js/app.js` imports chart.js/dompurify/flatpickr from `assets/node_modules`), so
  the next reader does not repeat this investigation.
- `docker-compose.yml` — delete the `- gemini_data:/root/.gemini` mount from the `app`
  service (line 42) and the `gemini_data:` entry from the `volumes:` block (line 48).
  **Leave the `app` `command` alone.** An earlier draft of this spec had it provision
  `assets/node_modules` on every start. That was tried and reverted: `.:/app` is a bind
  mount with no anonymous volume for `assets/node_modules`, so the install ran against the
  host working tree, and `npm ci --omit=dev` deleted `playwright` — which
  `scripts/extract_mercado_livre.js:5` loads by hard-coded path. Nothing provisions
  `assets/node_modules` today and nothing does after this task either; that gap is
  pre-existing, needs its own design decision (anonymous volume plus build-time install
  versus a runtime install), and belongs in its own task. This one is a removal.

**Order of operations.** Volume deletion is destructive and irreversible, so it comes last,
after the app is proven healthy:

1. Record the baseline: `docker images cash_lens-app` (current: 1.64GB disk usage /
   352MB content size).
2. Edit `Dockerfile` and `docker-compose.yml`.
3. Rebuild and verify **both** modes (below).
4. Re-verify the volume is still empty:
   `docker run --rm -v cash_lens_gemini_data:/g:ro alpine ls -laR /g`. If anything is
   present, capture what it is first; if it is an OAuth credential, revoke it at
   https://myaccount.google.com/permissions **before** deleting.
5. Only then `docker volume rm cash_lens_gemini_data`.
6. Record the new `docker images cash_lens-app`.

**Verification that the node/npm decision is safe — run this, do not assume it.** After
rebuilding, confirm the bundle actually resolves its three npm imports inside the container:

- `docker compose exec app mix assets.build` exits 0, and
- `docker compose exec app grep -c "chart.js" priv/static/assets/js/app.js` returns non-zero
  (proving chart.js was bundled, not silently externalized).

A stricter check of the `npm install` line: `docker compose exec app rm -rf assets/node_modules`,
then `docker compose restart app`, then re-run the two commands above. They must still pass —
that is what proves the compose command repopulates the directory rather than relying on
whatever the host left behind.

**Verification.** There is now a single mode: the compose stack runs the app and its own
Postgres. (An earlier draft of this spec described a second `poli-runner` mode; that was
removed from the repository, and with it `poli-runner.yml`.)

- `docker compose up -d --build`, then `curl -s -o /dev/null -w '%{http_code}' http://localhost:4444/`
  returns `200`.
- `./run` still starts the app natively against the same named volume, and the app answers
  on the same port.

Tests run inside the app container:

```sh
docker compose exec app mix test
```

Postgres listens on 5432 on the compose network only — the port is deliberately not
published, so host-side `mix` cannot reach the database. `./run` publishes it for as long
as it runs, which is the one way to exercise the suite from the host.

**Rollback.** Everything except step 5 is a two-file text change with no migration and no
persistent state, so the revert is `git checkout -- Dockerfile docker-compose.yml` followed by
`docker compose up -d --build`. Step 5 is the only irreversible action and is deliberately
sequenced after the app is confirmed healthy; since the volume is empty there is nothing to
restore, and if the CLI were ever reinstalled it would simply re-authenticate. Do not proceed
past step 3 while either mode is failing.

## Expected Results

- [ ] `Dockerfile` contains no `@google/gemini-cli` install line and no `# Install Gemini CLI` comment.
- [ ] `Dockerfile`'s `apk` line still installs `nodejs npm`, carrying a comment that states they are required because `assets/js/app.js` imports `chart.js`, `dompurify` and `flatpickr` from `assets/node_modules`, and that says `assets/node_modules` is gitignored and not provisioned automatically, so a fresh clone must run `npm install --prefix assets`.
- [ ] `docker-compose.yml` has no `gemini_data:/root/.gemini` mount on the `app` service and no `gemini_data` entry in the `volumes:` block.
- [ ] `docker-compose.yml`'s `app` command is unchanged (`mix deps.get && mix phx.server`): asset provisioning is explicitly out of scope for this removal, and `git diff` on that file shows only the two Gemini deletions.
- [ ] `grep -ri 'gemini-cli\|/root/\.gemini\|gemini_data' .` excluding `_build`, `deps`,
      `node_modules`, `.git`, `.meridian` **and `docs/`** returns no matches. `docs/` must be
      excluded: this spec file itself quotes all three patterns, so without that exclusion the
      criterion can never pass, however perfect the implementation. The substantive check is
      that `Dockerfile` and `docker-compose.yml` carry none of the three.
- [ ] `docker compose up -d --build` brings the app to HTTP 200 on http://localhost:4444/.
- [ ] `./run` brings the app to HTTP 200 on http://localhost:4444/ natively, against the same
      named volume, and removes its Postgres container on exit. (The former `poli-runner`
      mode is gone from the repository along with `poli-runner.yml`, so it is not a criterion.)
- [ ] After `rm -rf assets/node_modules` and a container restart, `mix assets.build` exits 0 in the container and the emitted `priv/static/assets/js/app.js` contains bundled `chart.js` code.
- [ ] `docker volume ls` no longer lists `cash_lens_gemini_data`, and the volume was confirmed empty immediately before deletion.
- [ ] `docker images cash_lens-app` reports a smaller image than the recorded baseline of 1.64GB disk usage / 352MB content size, with before/after values recorded on the task.

## Out of Scope

- Removing or rewriting `GEMINI.md` references in `.github/copilot-instructions.md`.
- Removing `nodejs`/`npm` from the image (shown above to be still required).
- `workspace_gemini_data` (does not exist).
- Any change to the profile/passthrough arrangement introduced by `ab72fa6`.
- Any Elixir source, test or migration change; no code-quality gate applies.
