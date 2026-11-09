# Nutrition tracking (nikhil/custom)

Calories in vs calories out, built on recipes. Decided in a grill-me session on 2026-11-09. Branch
`nikhil/custom` only. The app becomes the source of truth for food; the HealthVault reads it from the
nightly `.noopbak` backup, the way it already reads workouts.

## Decisions

**Source of truth.** The app owns recipes, the standard day and each day's food. Everything lives in the
app's SQLite database (new GRDB migration), not UserDefaults, so it rides in the `.noopbak` backup.

**Recipe.** 7 numbers (kcal, protein, carbs, fibre, sugar, fat, saturated fat), a serving label, optional
sodium, a parts table (each part with the same 7 numbers; editing a part re-totals), free-text notes, and
the source text / photos it was estimated from. `oneOff` flag: recipes created while logging a day are
one-offs, hidden from the list and picker but found by search; using one again (or "Keep as recipe")
makes it regular. Typing a name that matches an existing recipe offers that recipe first.

**Making a recipe.** Text and/or photos → one structured LLM call using the coach's provider and key →
name, serving, parts with numbers, totals, assumption notes. Review-and-edit before save; a correction
note can be sent back for a re-estimate. Default model Sonnet (latest); "Re-estimate with Opus" button.
Image input added to the Anthropic and OpenAI providers (only Gemini has it today). Packaged foods: photo
of the label panel. No key / offline: manual entry of parts or totals.

**Standard day.** Ordered slots: label, time of day, recipe, portion (½, 1, 1½, 2, custom), and swap
options (alternative recipes offered first for that slot). Versioned: each edit stores a dated copy so
an untouched past day resolves to the standard day as it was then.

**A day.** Untouched → it *is* the standard day (as of that date). First edit → the day gets its own rows
and stops following the standard. Rows: slot label, time, recipe, portion. Swaps keep the slot's time;
added food takes the time it was added (editable). "Didn't track" marks a day as no data (excluded from
ledger and expenditure estimates, not counted as the standard). No days before tracking starts except
the imported vault history.

**Today card — two bars, same scale.**
- IN: full planned day (standard segment, shrunk by removals; faint tick at the full standard length) +
  extras segment (usually absent) + deficit segment.
- OUT: RMR for the full day (setting, 1,217) + TEF (10% of planned intake) + active energy so far
  (average of Apple active energy and strap whole-day energy minus RMR accrued; whichever exists if only one).
- Deficit = OUT − planned intake, the real gap. Tick at the target (setting, −800…+1,000, default −300).
  Green past the tick, amber short of it; surplus shows as a red segment on the OUT bar.
- One line under the bars naming both levers: "235 to go: burn it, or drop ½ kefir smoothie (−95)" /
  "Target hit, 140 to spare".
- One line for the Mon–Sun ledger: "Week: −1,250 of −2,100".
- No macro display (protein / fibre / sat fat / sodium are stored for the vault, not shown).

**Nutrition screen.** Today's rows grouped by slot; swap (slot's options first), portion, swipe-remove,
add (recent / frequent / search / new from text-photo → one-off). Evening top-up list (bridge foods,
protein/fibre first); after 21:00 the gap goes to the ledger instead. The + menu gets "Add food".
History of past days is editable here too.

**Journal.** "Yesterday's food" section *below* the main journal: rows, the two bars as final numbers,
result vs target, same edit controls. Filled the next morning. Finishing the journal, or the day ending
with it unfilled, locks yesterday with whatever it holds (defaults count).

**Settings.** Nutrition toggle, off by default (Rashmi unaffected). Nutrition plan sheet: deficit target,
RMR, TEF %, model. No Apple Health writes.

**Import (one-time, Mac-side).** A script converts the HealthVault into one import file: the 29 recipes
(`Nutrition/Recipes/*.md`: frontmatter + parts table + notes), the current `Standard Daily Meals.md`
(slots, times from labels, swap options from the notes), and every Daily `## Meals` table as history
(recipe links matched incl. portion prefixes; typed rows → one-offs; the Americano rows → small regular
recipes). Validated on the Mac before handing over; the app imports it from Files; re-import updates by
slug, never duplicates. Archived cut-phase plan: not imported as a standard day.

**Vault pipeline.** `ingest_noop.py` / `nutrition.py` read the day's food from the backup and write
`## Meals` / `## Nutrition` from it; stop seeding from `Standard Daily Meals.md`; point the
`food-logging` skill at the new source. The vault keeps its own ledger.

## Phases (tracer bullets)

1. **Data model + import.** Migration (recipe, recipePart, standardDay versions + slots, dayFood rows,
   day state), repository API, the vault-to-JSON converter script and its validation, in-app import.
   Tests: day resolution (untouched / edited / versioned standard / didn't-track), portion scaling,
   re-import idempotence.
2. **Today card.** Bars, deficit maths, active-energy averaging, ledger line, settings + toggle.
3. **Nutrition screen + LLM recipes.** Editing, picker, one-offs, + menu, image support in providers,
   estimate / review / re-estimate flow, top-up list.
4. **Journal.** Yesterday's food section, locking rules.
5. **Vault pipeline.** Ingest + nutrition scripts, food-logging skill.

## Import file format (`noop-nutrition-import.json`, version 1)

Written by `Tools/nutrition/vault_to_import.py`, read by the app's importer. All numbers per ONE
serving / portion 1. Recipe ids are the vault note's file stem (`standard-lunch`); generated one-offs use
`oneoff-<yyyy-mm-dd>-<slug>`. Macro keys everywhere: `kcal, proteinG, carbsG, fiberG, sugarG, fatG,
satFatG` (numbers; missing → 0) and optional `sodiumMg`.

```json
{
  "version": 1,
  "generatedAt": "2026-11-09T12:00:00Z",
  "recipes": [
    { "id": "standard-lunch", "name": "Standard Lunch", "serving": "1 lunch", "category": null,
      "kcal": 552, "proteinG": 34, "carbsG": 62, "fiberG": 16, "sugarG": 29, "fatG": 18, "satFatG": 4.5,
      "sodiumMg": null, "oneOff": false, "notes": "markdown body after the frontmatter",
      "parts": [ { "name": "2 whole eggs", "kcal": 144, "proteinG": 12.6, "carbsG": 0.8, "fiberG": 0,
                   "sugarG": 0.4, "fatG": 9.6, "satFatG": 3.2, "sodiumMg": null } ] }
  ],
  "standard": {
    "effectiveDay": "2026-11-09",
    "slots": [ { "label": "Lunch", "minuteOfDay": 810, "recipeId": "standard-lunch", "portion": 1,
                 "swaps": [] } ]
  },
  "days": [
    { "day": "2026-07-14", "state": "edited",
      "items": [ { "label": "Lunch", "minuteOfDay": 810, "recipeId": "standard-lunch", "portion": 0.5 } ] }
  ]
}
```

- `standard.effectiveDay` is the tracking start: a day before the earliest standard version with no
  stored row is "no data", never the standard day.
- `days[].state`: `edited` (explicit rows) or `untracked`.
- `parts` totals should match the recipe totals; the converter reports any recipe off by > 2%.
