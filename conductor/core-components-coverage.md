# Implementation Plan: 100% Coverage for CoreComponents

## Objective
Reach 100% test coverage for `lib/cash_lens_web/components/core_components.ex`. This module contains the foundational UI building blocks, many of which use complex Phoenix slots.

## Proposed Strategy
Instead of calling component functions directly with `render_component(&func/1, assigns)`, we will use the `~H` macro within a test context or helper to ensure slots are properly initialized by the Phoenix compiler.

## Targeted Components & Scenarios

### 1. Flash (`flash/1`)
- [ ] Render `:info` kind.
- [ ] Render `:error` kind.
- [ ] Render with a custom `title`.
- [ ] Render using the `inner_block` slot vs the `@flash` map.

### 2. Button (`button/1`)
- [ ] Render variants: `primary`, `outline`, `white`.
- [ ] Render as a link using `href`.
- [ ] Render as a LiveView link using `navigate` and `patch`.
- [ ] Render as a standard `<button>`.

### 3. Input (`input/1`)
- [ ] Render standard `text` input.
- [ ] Render `checkbox` (verify `checked` logic).
- [ ] Render `select` with `options` and a `prompt`.
- [ ] Render `textarea`.
- [ ] Render with `field` (`Phoenix.HTML.FormField`) for auto-initialization.
- [ ] Render with a list of `errors` (exercises `translate_error`).

### 4. Header (`header/1`)
- [ ] Render with only the title (default slot).
- [ ] Render with `subtitle` slot.
- [ ] Render with `actions` slot.

### 5. Table (`table/1`)
- [ ] Render with a standard list of maps/structs.
- [ ] Render with a `Phoenix.LiveView.LiveStream`.
- [ ] Render with `action` slots.
- [ ] Exercise `row_click` attribute.

### 6. Modal (`modal/1`)
- [ ] Render in `show={true}` and `show={false}` states.
- [ ] Verify `on_cancel` attribute rendering.

### 7. Helper Functions
- [ ] `icon/1`: Verify name/class rendering.
- [ ] `list/1`: Render multiple `item` slots.
- [ ] `translate_error/1`: Test via `input` component with plural/singular errors.
- [ ] `show/2` and `hide/2`: Verify JS command generation.

## Verification
- Run `mix test test/cash_lens_web/components/core_components_test.exs`.
- Run `mix test --cover` and verify `lib/cash_lens_web/components/core_components.ex` hits 100%.
- Ensure 0 warnings and 0 failures.
