#!/usr/bin/env python3
"""Unit tests for vault_to_import.py on inline fixtures (no vault needed).

Run: python3 Tools/nutrition/test_vault_to_import.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vault_to_import as v  # noqa: E402


class PortionTests(unittest.TestCase):
    def test_vault_pipeline_forms(self):
        cases = {"": 1.0, "½ ": 0.5, "1½ ": 1.5, "1 1/2 ": 1.5, "1/2 ": 0.5, "0.5 ": 0.5,
                 "2 ": 2.0, "2× ": 2.0, "2x ": 2.0, "¼": 0.25, "¾ ": 0.75}
        for prefix, want in cases.items():
            with self.subTest(prefix=prefix):
                self.assertAlmostEqual(v.portion_multiplier(prefix), want)

    def test_unparsable_prefix_reads_as_one_and_is_flagged(self):
        self.assertEqual(v.portion_multiplier("some "), 1.0)
        self.assertFalse(v.portion_is_parsable("some "))
        self.assertTrue(v.portion_is_parsable("½ "))
        self.assertTrue(v.portion_is_parsable(""))

    def test_resolve_row_uses_link_and_prefix(self):
        conv = v.Converter(Path("/nonexistent"))
        conv.recipes["quest-cookies-and-cream"] = {"kcal": 190}
        conv.by_lower["quest-cookies-and-cream"] = "quest-cookies-and-cream"
        row = {"meal": "Snack", "item": "½ [[Quest-Cookies-and-Cream]]", "kcal": "95"}
        self.assertEqual(conv.resolve_row(row, "t"), ("recipe", "quest-cookies-and-cream", 0.5))
        missing = {"meal": "Snack", "item": "[[no-such]]", "kcal": "50"}
        self.assertEqual(conv.resolve_row(missing, "t")[0], "typed")
        placeholder = {"meal": "_EDIT — snacks / fruit / other_", "item": ""}
        self.assertEqual(conv.resolve_row(placeholder, "t")[0], "skip")


class TimeTests(unittest.TestCase):
    def test_labels(self):
        cases = {
            "Morning (fasted, ~10:00)": 600,
            "Coffee (11 AM–3 PM)": 660,
            "Lunch (1:30 PM)": 810,
            "Office smoothie — whey + 4 frozen strawberries (~3–4 PM)": 930,
            "Kefir smoothie (7:00 PM, post-workout)": 1140,
            "Dinner (~8:00 PM) — salad": 1200,
            "Dinner — main (rotates, see below)": None,
            "Snack": None,
            "Late snack (9 pm)": 1260,
            "Brunch (11:30 AM)": 690,
        }
        for label, want in cases.items():
            with self.subTest(label=label):
                self.assertEqual(v.parse_minute_of_day(label), want)

    def test_dinner_inherits_previous_dinner_time(self):
        m, last = v.Converter._minute("Dinner (~8:00 PM) — salad", None)
        self.assertEqual((m, last), (1200, 1200))
        self.assertEqual(v.Converter._minute("Dinner — main", last)[0], 1200)
        self.assertIsNone(v.Converter._minute("Snack", last)[0])

    def test_clean_label(self):
        cases = {
            "Morning (fasted, ~10:00)": "Morning",
            "Office smoothie — whey + 4 frozen strawberries (~3–4 PM)": "Office smoothie",
            "Dinner (~8:00 PM) — salad": "Dinner — salad",
            "Dinner — main (rotates, see below)": "Dinner — main",
            "Snack — ¼ earlier + remaining ¾ later": "Snack",
            "**Lunch** (1:30 PM)": "Lunch",
        }
        for label, want in cases.items():
            with self.subTest(label=label):
                self.assertEqual(v.clean_label(label), want)


class MacroTableTests(unittest.TestCase):
    STANDARD = """
## Macros

| component | kcal | protein_g | carbs_g | fiber_g | sugar_g | fat_g | sat_fat_g |
|-----------|------|-----------|---------|---------|---------|-------|-----------|
| 2 whole eggs | 144 | 12.6 | 0.8 | 0 | 0.4 | 9.6 | 3.2 |
| **Daal** 1 cup | ~150 | 9 | 20 | 6 | 2 | 2 | 0.5 |
| **Total** | **~294** | **21.6** | **20.8** | **6** | **2.4** | **11.6** | **3.7** |
| _+ Papaya ½ cup (optional)_ | _+30_ | _+0.5_ | _+8_ | _+1.3_ | _+6_ | _+0.1_ | _0_ |
"""
    SHORT_HEADERS = """
| ingredient | kcal | protein | carb | sugar | fat (sat) | source |
|---|---|---|---|---|---|---|
| whey, 30 g | 120 | 27 | 1.3 | 0.3 | 0.8 (0.4) | label |
| vanilla essence | ~0 | 0 | 0 | 0 | 0 | no sugar |
"""
    LABEL_PANEL = """
|kcal|protein|carb|sugars|fat|saturated fat|
|---|---|---|---|---|---|
|**28.42**|**0.39 g**|**3.68 g**|**0 g**|**1.35 g**|**0.10 g**|
"""

    def test_full_table_skips_total_and_optional(self):
        parts, skipped = v.parse_parts_table(self.STANDARD)
        self.assertEqual([p["name"] for p in parts], ["2 whole eggs", "Daal 1 cup"])
        self.assertEqual(parts[1]["kcal"], 150)
        self.assertEqual(parts[0]["satFatG"], 3.2)
        self.assertEqual(skipped, ["+ Papaya ½ cup (optional)"])

    def test_short_headers_and_combined_fat_column(self):
        parts, _ = v.parse_parts_table(self.SHORT_HEADERS)
        whey = parts[0]
        self.assertEqual((whey["proteinG"], whey["carbsG"], whey["fatG"], whey["satFatG"]),
                         (27, 1.3, 0.8, 0.4))
        self.assertEqual(whey["fiberG"], 0)  # missing column -> 0
        self.assertIsNone(whey["sodiumMg"])
        self.assertEqual(parts[1]["kcal"], 0)

    def test_label_panel_has_no_parts(self):
        self.assertEqual(v.parse_parts_table(self.LABEL_PANEL), ([], []))

    def test_recipe_note_round_trip(self):
        note = "---\ntype: recipe\nkcal: 294\nprotein_g: 21.6\nserving: 1 bowl\nsodium_mg: 78\n---\n\n" \
               "# Eggs & Daal\n\nIntro.\n" + self.STANDARD + "\n## Notes\n\nmore\n"
        fm, body = v.parse_frontmatter(note)
        self.assertEqual(fm["kcal"], "294")
        self.assertTrue(body.lstrip().startswith("# Eggs & Daal"))
        parts, _ = v.parse_parts_table(v.recipe_parts_table(body))
        self.assertEqual(len(parts), 2)
        rec = {"parts": parts, **{k: 0 for k in v.MACRO_KEYS}}
        rec.update(kcal=294, proteinG=21.6, carbsG=20.8, fiberG=6, sugarG=2.4, fatG=11.6, satFatG=3.7)
        self.assertEqual(v.parts_mismatches(rec), [])
        rec["kcal"] = 400
        self.assertEqual(len(v.parts_mismatches(rec)), 1)

    def test_slugify(self):
        self.assertEqual(v.slugify("Americano ×3 (no sugar, no milk)"), "americano-x3-no-sugar-no-milk")
        self.assertEqual(v.slugify("½ pear (~85–90 g)"), "1-2-pear-85-90-g")
        self.assertEqual(v.slugify("Dinner Sautéed Veg"), "dinner-sauteed-veg")


if __name__ == "__main__":
    unittest.main()
