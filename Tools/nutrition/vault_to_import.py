#!/usr/bin/env python3
"""Convert the Obsidian HealthVault nutrition data into one NOOP import file.

Reads, under the vault root (the "Obsidian NS Health" folder):
  Nutrition/Recipes/*.md            recipes (YAML frontmatter + optional "## Macros" parts table)
  Nutrition/Standard Daily Meals.md the standard day (first pipe table + swap notes below it)
  Daily/<yyyy-mm-dd>.md             each day's "## Meals" table, as edited history

Writes `noop-nutrition-import.json` (version 1) as specified in plans/nutrition-tracking.md,
"Import file format", and prints a validation report.

Portion prefixes and recipe-link resolution follow the vault pipeline's own rules
(HealthVault/scripts/nutrition.py: `_portion_multiplier`, `parse_meals`), so imported days
total the same as the vault's `## Nutrition` blocks.

Standard library only; Python 3.9+.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from datetime import date, datetime, timezone
from pathlib import Path

DEFAULT_VAULT = (Path.home() / "Library/Mobile Documents/iCloud~md~obsidian/Documents"
                 / "HealthVault/Obsidian NS Health")
DEFAULT_OUT = Path("/private/tmp/claude-501/-Users-nikhilsama-Coding/"
                   "fafe716c-278d-40e6-accc-826ca89364e0/scratchpad/noop-nutrition-import.json")

# Vault macro column -> import key. Order is the output order.
MACROS = [("kcal", "kcal"), ("protein_g", "proteinG"), ("carbs_g", "carbsG"),
          ("fiber_g", "fiberG"), ("sugar_g", "sugarG"), ("fat_g", "fatG"),
          ("sat_fat_g", "satFatG")]
MACRO_KEYS = [k for _, k in MACROS]

# Day rows whose vault cells were overwritten by the pipeline: a typed row that mentions a [[recipe]] in its
# commentary got that recipe's full numbers. The right numbers are the ones written in the commentary.
# Keyed by (day, text the item contains) -> (name, vault-keyed macros).
CORRECTIONS = {
    ("2026-09-17", "minus 2 egg whites"): ("Standard lunch minus 2 egg whites", {
        "kcal": 518, "protein_g": 26.8, "carbs_g": 61.6, "fiber_g": 16, "sugar_g": 28.6, "fat_g": 17.9,
        "sat_fat_g": 4.5}),
    ("2026-09-17", "Epigamia Natural Greek Yogurt"): ("Epigamia Natural Greek Yogurt 85 g + salt + chaat masala", {
        "kcal": 55, "protein_g": 6.1, "carbs_g": 4, "fiber_g": 0, "sugar_g": 4, "fat_g": 1.9, "sat_fat_g": 1.2}),
    ("2026-09-29", "Plain oatmeal"): ("Plain oatmeal, ¼ cup dry oats", {
        "kcal": 73, "protein_g": 2.6, "carbs_g": 12.5, "fiber_g": 1.9, "sugar_g": 0.2, "fat_g": 1.3,
        "sat_fat_g": 0.2}),
}


def corrected(day: str, row: dict) -> dict:
    """The row with its commentary's numbers when it is one of CORRECTIONS, as a typed row (no link)."""
    for (cday, needle), (name, cells) in CORRECTIONS.items():
        if cday == day and needle in row.get("item", ""):
            return {**row, "item": name, **{k: str(v) for k, v in cells.items()}}
    return row


# Swap fallbacks if they cannot be read from the notes under the standard table.
FALLBACK_SWAPS = {
    "dinner-main": ["chicken-keema", "grilled-chicken-breast", "salmon-ochazuke"],
    "afternoon": ["banana-oatmeal", "honey-oatmeal", "office-smoothie"],
}

LINK_RE = re.compile(r"\[\[([^\]|]+)")


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def num(x):
    """First number in a cell ("~345", "**0.4 g**", "+30") or None. Same as nutrition.py `_num`."""
    if x is None:
        return None
    m = re.search(r"-?\d+(?:\.\d+)?", str(x).replace(",", ""))
    return float(m.group()) if m else None


def strip_markup(s: str) -> str:
    """Remove bold/italic markers and wiki-link brackets from a cell."""
    s = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", s)  # [[target|alias]] -> alias
    s = s.replace("[[", "").replace("]]", "")
    s = re.sub(r"(\*\*|__|\*|(?<!\w)_|_(?!\w))", "", s)
    return s.strip()


def clean_number(x):
    """Round for output and print integral values as ints."""
    if x is None:
        return None
    x = round(float(x), 3)
    return int(x) if x == int(x) else x


def slugify(text: str, max_len: int = 60) -> str:
    """ASCII slug: lowercase, alnum runs joined by '-'. '×' -> 'x', '½' -> '1-2'."""
    text = unicodedata.normalize("NFKD", text.replace("×", "x"))
    text = "".join(c for c in text if not unicodedata.combining(c))  # é -> e
    text = re.sub(r"[^\x00-\x7f]", "-", text).lower()  # dashes, fraction slash -> separators
    slug = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    if len(slug) > max_len:
        slug = slug[:max_len].rsplit("-", 1)[0] if "-" in slug[:max_len] else slug[:max_len]
    return slug or "item"


def read_table(text: str) -> list:
    """Parse the first pipe table in `text` into dicts keyed by lowercased header.
    Same behaviour as nutrition.py `_read_table` (which the vault pipeline uses)."""
    rows, header = [], None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            if header is not None:
                break  # table ended
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if set("".join(cells)) <= set("-: "):  # |---|---| separator
            continue
        if header is None:
            header = [c.lower() for c in cells]
            continue
        if len(cells) < len(header):
            cells += [""] * (len(header) - len(cells))
        rows.append(dict(zip(header, cells)))
    return rows


def section(text: str, heading_re: str) -> str:
    """Body of the first `## ` section whose heading matches `heading_re` (up to the next `## `)."""
    m = re.search(rf"^##\s+{heading_re}.*$", text, re.MULTILINE | re.IGNORECASE)
    if not m:
        return ""
    rest = text[m.end():]
    nxt = re.search(r"^##\s", rest, re.MULTILINE)
    return rest[:nxt.start()] if nxt else rest


# ---------------------------------------------------------------------------
# Portions (exact copy of nutrition.py `_portion_multiplier` rules)
# ---------------------------------------------------------------------------
UNICODE_FRAC = {
    "½": 0.5, "⅓": 1 / 3, "⅔": 2 / 3, "¼": 0.25, "¾": 0.75,
    "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8, "⅙": 1 / 6, "⅚": 5 / 6,
    "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
}


def portion_multiplier(prefix: str) -> float:
    """Leading quantity before a [[recipe]] link -> scale factor. Supports '½', '1½',
    '1 1/2', '1/2', '0.5', '2', '2x'/'2×'. Default 1.0 (whole)."""
    s = re.sub(r"[x×]\s*$", "", prefix.strip()).strip()
    if not s:
        return 1.0
    frac_cls = "".join(UNICODE_FRAC)
    m = re.match(r"^(\d+)\s+(\d+)\s*/\s*(\d+)", s)          # mixed ASCII: "1 1/2"
    if m:
        return int(m.group(1)) + int(m.group(2)) / int(m.group(3))
    m = re.match(r"^(\d+)\s*/\s*(\d+)", s)                  # ASCII fraction: "1/2"
    if m:
        return int(m.group(1)) / int(m.group(2))
    m = re.match(rf"^(\d+)\s*([{frac_cls}])", s)            # whole + unicode: "1½"
    if m:
        return int(m.group(1)) + UNICODE_FRAC[m.group(2)]
    if s[0] in UNICODE_FRAC:                               # unicode fraction: "½"
        return UNICODE_FRAC[s[0]]
    m = re.match(r"^(\d+(?:\.\d+)?)", s)                    # decimal / integer: "0.5", "2"
    if m:
        return float(m.group(1))
    return 1.0


def portion_is_parsable(prefix: str) -> bool:
    """False when there is prefix text the pipeline silently reads as 1.0 (e.g. 'some [[x]]')."""
    s = re.sub(r"[x×]\s*$", "", strip_markup(prefix)).strip()
    return not s or s[0].isdigit() or s[0] in UNICODE_FRAC


# ---------------------------------------------------------------------------
# Meal labels: time of day and a short display name
# ---------------------------------------------------------------------------
_T = r"(\d{1,2})(?::(\d{2}))?"
_MER = r"\s*([ap])\.?m\.?\b"
RANGE_RE = re.compile(_T + r"\s*(?:" + _MER + r")?\s*[–—-]\s*" + _T + _MER, re.IGNORECASE)
CLOCK_RE = re.compile(r"(\d{1,2}):(\d{2})(?:" + _MER + r")?", re.IGNORECASE)
HOUR_RE = re.compile(r"(\d{1,2})" + _MER, re.IGNORECASE)


def _to_minutes(h, m, mer):
    h, m = int(h), int(m or 0)
    if mer:
        mer = mer.lower()
        if mer == "p" and h < 12:
            h += 12
        if mer == "a" and h == 12:
            h = 0
    elif h < 8:  # bare "7:00" inside an eating window is evening
        h += 12
    if not (0 <= h < 24 and 0 <= m < 60):
        return None
    return h * 60 + m


def parse_minute_of_day(label: str):
    """Minute of day from a meal label, or None.
    Ranges: a short one (<= 2 h, e.g. "~3–4 PM") gives its midpoint (930); a long window
    ("11 AM–3 PM") gives its start (660). A range's start takes the end's AM/PM when it has none."""
    m = RANGE_RE.search(label)
    if m:
        h1, m1, mer1, h2, m2, mer2 = m.groups()
        end = _to_minutes(h2, m2, mer2)
        start = _to_minutes(h1, m1, mer1 or mer2)
        if start is not None and end is not None:
            if end < start and not mer1:   # e.g. "11–1 PM": start is AM
                start = _to_minutes(h1, m1, "a")
            if 0 <= end - start <= 120:
                return (start + end) // 2
            return start
    m = CLOCK_RE.search(label)
    if m:
        return _to_minutes(m.group(1), m.group(2), m.group(3))
    m = HOUR_RE.search(label)
    if m:
        return _to_minutes(m.group(1), 0, m.group(2))
    return None


def clean_label(meal: str) -> str:
    """'Dinner (~8:00 PM) — salad' -> 'Dinner — salad'; 'Office smoothie — whey + ... (~3–4 PM)'
    -> 'Office smoothie'. Parentheticals go; a ' — suffix' is kept only when it is 1–2 words."""
    s = strip_markup(meal)
    s = re.sub(r"\s*\([^)]*\)", "", s)
    parts = [p.strip() for p in re.split(r"\s+[—–]\s+|\s+-\s+", s) if p.strip()]
    if not parts:
        return s.strip()
    if len(parts) > 1 and len(parts[1].split()) <= 2:
        return f"{parts[0]} — {parts[1]}"
    return parts[0]


# ---------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------
def parse_frontmatter(text: str):
    """(dict of lowercase key -> raw string, body after the closing ---)."""
    m = re.match(r"^---\n(.*?)\n---[ \t]*\n?", text, re.DOTALL)
    if not m:
        return {}, text
    fm = {}
    for ln in m.group(1).splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            fm[k.strip().lower()] = v.strip().strip("\"'")
    return fm, text[m.end():]


def _column_kind(header: str):
    """Map a parts-table header to a macro key, 'fat+sat', 'sodiumMg' or None."""
    h = strip_markup(header).lower().strip()
    if h in ("kcal", "calories", "energy", "cal"):
        return "kcal"
    if h.startswith("protein"):
        return "proteinG"
    if h.startswith("carb"):
        return "carbsG"
    if h.startswith("fib"):
        return "fiberG"
    if h.startswith("sugar"):
        return "sugarG"
    if re.match(r"^fat\s*\(sat", h):
        return "fat+sat"
    if h.startswith("sat") or h.startswith("saturated"):
        return "satFatG"
    if h.startswith("fat"):
        return "fatG"
    if h.startswith("sodium"):
        return "sodiumMg"
    return None


def parse_parts_table(table_md: str):
    """Parts from a recipe's macros table -> (parts, skipped_row_names).

    The first column names the part; macro columns are matched by header ('protein',
    'protein_g', 'fibre', 'fat (sat)' as "0.8 (0.4)", ...). Missing macros -> 0. The bold
    Total row and optional '+ add-on' rows are skipped. A table whose first column is itself
    a macro (a nutrition-label panel) has no parts."""
    rows = read_table(table_md)
    if not rows:
        return [], []
    headers = list(rows[0].keys())
    if not headers or _column_kind(headers[0]) is not None:
        return [], []
    kinds = {h: _column_kind(h) for h in headers[1:]}
    if not any(k in MACRO_KEYS or k == "fat+sat" for k in kinds.values()):
        return [], []
    parts, skipped = [], []
    for r in rows:
        name = strip_markup(r.get(headers[0], ""))
        low = name.lower()
        if not name or low.startswith("total"):
            continue
        if low.startswith("+") or "optional" in low:
            skipped.append(name)
            continue
        part = {"name": name}
        part.update({k: 0 for k in MACRO_KEYS})
        part["sodiumMg"] = None
        for h, kind in kinds.items():
            cell = r.get(h, "")
            if kind == "fat+sat":
                nums = re.findall(r"-?\d+(?:\.\d+)?", cell.replace(",", ""))
                if nums:
                    part["fatG"] = float(nums[0])
                if len(nums) > 1:
                    part["satFatG"] = float(nums[1])
            elif kind:
                v = num(cell)
                if v is not None:
                    part[kind] = v
        parts.append(part)
    return parts, skipped


def recipe_parts_table(body: str) -> str:
    """Raw text of the '## Macros…' section (its first table is the parts table)."""
    return section(body, r"Macros")


def load_recipe(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    fm, body = parse_frontmatter(text)
    h1 = re.search(r"^#\s+(.+?)\s*$", body, re.MULTILINE)
    parts, skipped = parse_parts_table(recipe_parts_table(body))
    rec = {"id": path.stem, "name": h1.group(1).strip() if h1 else path.stem,
           "serving": fm.get("serving") or "1 serving", "category": fm.get("category") or None}
    for vault_key, key in MACROS:
        rec[key] = num(fm.get(vault_key)) or 0
    rec["sodiumMg"] = num(fm.get("sodium_mg"))
    rec["oneOff"] = False
    rec["notes"] = body.strip("\n")
    rec["parts"] = parts
    rec["_skippedParts"] = skipped
    return rec


def typed_recipe(rid: str, name: str, row: dict, one_off: bool, note: str) -> dict:
    """A recipe made from a meal row's typed macro cells."""
    rec = {"id": rid, "name": name, "serving": "1 serving", "category": None}
    for vault_key, key in MACROS:
        rec[key] = num(row.get(vault_key)) or 0
    rec["sodiumMg"] = num(row.get("sodium_mg"))
    rec.update({"oneOff": one_off, "notes": note, "parts": []})
    return rec


def row_has_numbers(row: dict) -> bool:
    return any(num(row.get(k)) is not None for k, _ in MACROS)


# ---------------------------------------------------------------------------
# Converter
# ---------------------------------------------------------------------------
class Converter:
    def __init__(self, vault: Path):
        self.vault = vault
        self.recipes = {}           # id -> recipe (regular + typed + one-off)
        self.by_lower = {}          # lowercased file stem -> id (the pipeline matches case-insensitively)
        self.typed_by_text = {}     # exact item text -> id of a regular typed recipe (the Americanos)
        self.unresolved = []        # (where, link, what happened)
        self.bad_portions = []      # (where, item)
        self.multi_links = []       # (where, item)
        self.skipped_days = []      # (day, reason)
        self.skipped_rows = []      # (where, item, reason)
        self.cell_mismatch = []     # (day, item, cell kcal, link kcal)
        self.typed_reuse_diff = []  # (day, item) reused a regular typed recipe but numbers differ
        self.swaps_source = ""
        self.oneoff_by_key = {}     # (item text, macros...) -> one-off id, to reuse across days
        self.oneoff_reused = 0

    # -- recipes ------------------------------------------------------------
    def load_recipes(self):
        rdir = self.vault / "Nutrition" / "Recipes"
        for path in sorted(rdir.glob("*.md")):
            if path.stem.lower() == "readme":
                continue
            rec = load_recipe(path)
            self.recipes[rec["id"]] = rec
            self.by_lower[rec["id"].lower()] = rec["id"]

    def resolve_row(self, row: dict, where: str):
        """('recipe', id, portion) | ('typed', None, None) | ('skip', None, reason)."""
        item = row.get("item", "")
        links = LINK_RE.findall(item)
        m = LINK_RE.search(item)
        if m:
            target = m.group(1).strip()
            rid = self.by_lower.get(target.lower())
            if len([l for l in links if l.strip().lower() in self.by_lower]) > 1:
                self.multi_links.append((where, item))
            if rid:
                prefix = item[:m.start()]
                if not portion_is_parsable(prefix):
                    self.bad_portions.append((where, item))
                return "recipe", rid, portion_multiplier(prefix)
            if row_has_numbers(row):
                self.unresolved.append((where, target, "one-off from the row's numbers"))
                return "typed", None, None
            self.unresolved.append((where, target, "row skipped (no numbers)"))
            return "skip", None, f"unresolved link [[{target}]], no numbers"
        if row_has_numbers(row):
            return "typed", None, None
        return "skip", None, "placeholder (no link, no numbers)"

    # -- standard day -------------------------------------------------------
    def load_standard(self, today: str) -> dict:
        path = self.vault / "Nutrition" / "Standard Daily Meals.md"
        text = path.read_text(encoding="utf-8")
        rows = read_table(text)
        slots, last_dinner = [], None
        for row in rows:
            meal, item = row.get("meal", ""), row.get("item", "")
            where = f"Standard Daily Meals: {strip_markup(meal)}"
            kind, rid, portion = self.resolve_row(row, where)
            if kind == "skip":
                if portion.startswith("unresolved"):
                    self.skipped_rows.append((where, item, portion))
                continue
            if kind == "typed":
                name = strip_markup(item)
                rid = slugify(name)
                if rid in self.recipes:
                    rid = f"{rid}-typed"
                self.recipes[rid] = typed_recipe(
                    rid, name, row, one_off=False,
                    note="Imported from a typed row of Standard Daily Meals.md.")
                self.typed_by_text[item.strip()] = rid
                portion = 1
            minute, last_dinner = self._minute(meal, last_dinner)
            slots.append({"label": clean_label(meal), "minuteOfDay": minute, "recipeId": rid,
                          "portion": clean_number(portion), "swaps": []})
        self._attach_swaps(slots, text)
        return {"effectiveDay": today, "slots": slots}

    @staticmethod
    def _minute(meal: str, last_dinner):
        """Minute from the label; dinner rows without a time inherit the previous dinner time."""
        minute = parse_minute_of_day(meal)
        is_dinner = clean_label(meal).lower().startswith("dinner")
        if minute is None and is_dinner:
            minute = last_dinner
        if is_dinner and minute is not None:
            last_dinner = minute
        return minute, last_dinner

    def _attach_swaps(self, slots: list, text: str):
        """Swap options from the notes under the standard table: a '>' block that mentions
        'swap' and links the slot's recipe offers the other recipes it links (ignoring links
        after a '⛔' / 'Do not' on a line). Falls back to FALLBACK_SWAPS."""
        lines = text.splitlines()
        start = 0  # first line after the standard table
        for i, ln in enumerate(lines):
            if ln.strip().startswith("|"):
                start = i
                break
        while start < len(lines) and lines[start].strip().startswith("|"):
            start += 1
        blocks, cur = [], []
        for ln in lines[start:]:
            if ln.lstrip().startswith(">"):
                cur.append(ln)
            elif cur:
                blocks.append(cur)
                cur = []
        if cur:
            blocks.append(cur)
        derived = False
        for slot in slots:
            rid = slot["recipeId"]
            for block in blocks:
                joined = "\n".join(block)
                if "swap" not in joined.lower() or f"[[{rid}]]" not in joined:
                    continue
                found = []
                for ln in block:
                    ln = re.split(r"⛔|\bdo not\b", ln, flags=re.IGNORECASE)[0]
                    for link in LINK_RE.findall(ln):
                        sid = self.by_lower.get(link.strip().lower())
                        if sid and sid != rid and sid not in found:
                            found.append(sid)
                if found:
                    slot["swaps"] = found
                    derived = True
                break
        if derived:
            self.swaps_source = "derived from the notes under the standard table"
            return
        self.swaps_source = "hardcoded fallback (notes could not be parsed)"
        for slot in slots:
            low = slot["label"].lower()
            key = "dinner-main" if low.startswith("dinner — main") else (
                "afternoon" if "smoothie" in low and (slot["minuteOfDay"] or 0) < 17 * 60 else None)
            if key:
                slot["swaps"] = [s for s in FALLBACK_SWAPS[key] if s != slot["recipeId"]]

    # -- daily history --------------------------------------------------------
    def load_days(self) -> list:
        ddir = self.vault / "Daily"
        days = []
        for path in sorted(ddir.glob("*.md")):
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", path.stem):
                continue
            text = path.read_text(encoding="utf-8")
            if not re.search(r"^## Meals", text, re.MULTILINE):
                continue
            day = path.stem
            rows = read_table(section(text, r"Meals\b"))
            if not rows:
                self.skipped_days.append((day, "## Meals table is empty (no rows)"))
                continue
            items = self._day_items(day, rows)
            if not items:
                self.skipped_days.append((day, "## Meals table has no usable rows"))
                continue
            days.append({"day": day, "state": "edited", "items": items})
        return days

    def _day_items(self, day: str, rows: list) -> list:
        items, last_dinner = [], None
        for row in rows:
            row = corrected(day, row)
            meal, item = row.get("meal", ""), row.get("item", "")
            where = f"{day}: {strip_markup(meal)}"
            kind, rid, portion = self.resolve_row(row, where)
            if kind == "skip":
                if portion.startswith("unresolved"):
                    self.skipped_rows.append((where, item, portion))
                continue
            if kind == "recipe":
                self._check_cells(day, row, rid, portion)
            elif all(not num(row.get(v)) for v, _ in MACROS):
                # An all-zero typed row marks a skipped meal ("SKIPPED", "Perrier only"): no food to log.
                self.skipped_rows.append((where, item, "all-zero typed row (a skipped meal)"))
                continue
            else:
                rid = self.typed_by_text.get(item.strip())
                if rid:
                    if any(abs((num(row.get(v)) or 0) - self.recipes[rid][k]) > 1e-6 for v, k in MACROS):
                        self.typed_reuse_diff.append((day, item))
                else:
                    # The same typed text with the same numbers on another day reuses that
                    # day's one-off (e.g. the old standard's "1 fruit / oats / rice" row).
                    key = (item.strip(),) + tuple(num(row.get(v)) or 0 for v, _ in MACROS)
                    rid = self.oneoff_by_key.get(key)
                    if rid:
                        self.oneoff_reused += 1
                    else:
                        base = f"oneoff-{day}-{slugify(strip_markup(item))}"
                        rid, n = base, 2
                        while rid in self.recipes:
                            rid, n = f"{base}-{n}", n + 1
                        self.recipes[rid] = typed_recipe(
                            rid, strip_markup(item) or strip_markup(meal), row, one_off=True,
                            note=f"Imported from Daily/{day}.md (meal: {strip_markup(meal)}).")
                        self.oneoff_by_key[key] = rid
                portion = 1
            minute, last_dinner = self._minute(meal, last_dinner)
            items.append({"label": clean_label(meal), "minuteOfDay": minute, "recipeId": rid,
                          "portion": clean_number(portion)})
        return items

    def _check_cells(self, day, row, rid, portion):
        """Informational: does the pipeline's filled kcal cell agree with recipe × portion?"""
        cell = num(row.get("kcal"))
        want = self.recipes[rid]["kcal"] * portion
        if cell is not None and abs(cell - want) > max(1.0, 0.02 * want):
            self.cell_mismatch.append((day, row.get("item", ""), cell, round(want, 1)))

    # -- output -------------------------------------------------------------
    def build(self, today: str) -> dict:
        self.load_recipes()
        standard = self.load_standard(today)
        days = self.load_days()
        recipes = []
        for rec in sorted(self.recipes.values(), key=lambda r: (r["oneOff"], r["id"])):
            out = {k: v for k, v in rec.items() if not k.startswith("_")}
            for k in MACRO_KEYS + ["sodiumMg"]:
                out[k] = clean_number(out[k])
            out["parts"] = [{**p, **{k: clean_number(p[k]) for k in MACRO_KEYS + ["sodiumMg"]}}
                            for p in rec["parts"]]
            recipes.append(out)
        return {"version": 1,
                "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "recipes": recipes, "standard": standard, "days": days}


# ---------------------------------------------------------------------------
# Validation report
# ---------------------------------------------------------------------------
def parts_mismatches(rec: dict) -> list:
    """Macros where the parts sum is off the recipe total by > 2% (and > 0.1 absolute)."""
    if not rec["parts"]:
        return []
    off = []
    for k in MACRO_KEYS:
        total = rec[k] or 0
        s = sum(p[k] or 0 for p in rec["parts"])
        if abs(s - total) > 0.1 and abs(s - total) > 0.02 * abs(total):
            off.append(f"{k} parts {round(s, 2):g} vs total {total:g}")
    return off


def report(conv: Converter, data: dict, out: Path) -> str:
    recs = data["recipes"]
    by_id = {r["id"]: r for r in recs}
    regular = [r for r in recs if not r["oneOff"]]
    oneoff = [r for r in recs if r["oneOff"]]
    items = sum(len(d["items"]) for d in data["days"])
    L = []
    L.append(f"Output: {out}")
    L.append(f"Recipes: {len(recs)} total — {len(regular)} regular "
             f"({sum(1 for r in regular if r['parts'])} with parts), {len(oneoff)} one-off")
    L.append(f"Standard day ({data['standard']['effectiveDay']}): {len(data['standard']['slots'])} slots; "
             f"swaps {conv.swaps_source}")
    kcal = prot = 0.0
    for s in data["standard"]["slots"]:
        r = by_id[s["recipeId"]]
        kcal += r["kcal"] * s["portion"]
        prot += r["proteinG"] * s["portion"]
        t = "--:--" if s["minuteOfDay"] is None else f"{s['minuteOfDay'] // 60:02d}:{s['minuteOfDay'] % 60:02d}"
        sw = f"  swaps: {', '.join(s['swaps'])}" if s["swaps"] else ""
        L.append(f"  {t}  {s['label']:<18} {s['recipeId']} ×{s['portion']:g}{sw}")
    L.append(f"  Standard day total: {kcal:,.0f} kcal / {prot:.1f} g protein (vault note says ≈1,424 / 132.9)")
    dates = [d["day"] for d in data["days"]]
    L.append(f"Days: {len(dates)}" + (f" ({dates[0]} … {dates[-1]})" if dates else "") + f", items: {items}")

    L.append("\nRecipes whose parts sum differs from totals by > 2%:")
    bad = [(r["id"], parts_mismatches(r)) for r in regular]
    bad = [(i, m) for i, m in bad if m]
    L += [f"  {i}: " + "; ".join(m) for i, m in bad] or ["  none"]
    skipped_parts = [(r["id"], r["_skippedParts"]) for r in conv.recipes.values() if r.get("_skippedParts")]
    if skipped_parts:
        L.append("  (optional add-on rows left out of parts: "
                 + "; ".join(f"{i}: {', '.join(p)}" for i, p in skipped_parts) + ")")
    typed = set(conv.typed_by_text.values())
    no_parts = [r["id"] for r in regular if not r["parts"] and r["id"] not in typed]
    L.append(f"  vault recipes without a parts table: {len(no_parts)} ({', '.join(no_parts)})")

    L.append("\nUnresolved recipe links:")
    L += [f"  {w}: [[{link}]] -> {what}" for w, link, what in conv.unresolved] or ["  none"]
    L.append("\nUnparsable portion prefixes (read as recipe × 1, same as the vault pipeline; "
             "check whether the link only sits inside commentary on a typed row):")
    L += [f"  {w}: {item}" for w, item in conv.bad_portions] or ["  none"]
    if conv.multi_links:
        L.append("\nRows linking more than one recipe (first link used, like the pipeline):")
        L += [f"  {w}: {item}" for w, item in conv.multi_links]
    L.append("\nDays skipped:")
    L += [f"  {d}: {why}" for d, why in conv.skipped_days] or ["  none"]
    if conv.skipped_rows:
        L.append("\nRows skipped (besides placeholders):")
        L += [f"  {w}: {item!r} — {why}" for w, item, why in conv.skipped_rows]
    L.append(f"\nInfo: recipe-linked day rows whose filled kcal cell disagrees with recipe × portion: "
             f"{len(conv.cell_mismatch)} (the link is used, not the cell)")
    L += [f"  {d}: {item} cell {c:g} vs link {w:g}" for d, item, c, w in conv.cell_mismatch[:15]]
    if len(conv.cell_mismatch) > 15:
        L.append(f"  … {len(conv.cell_mismatch) - 15} more")
    L.append(f"Info: typed day rows that reused an identical earlier one-off: {conv.oneoff_reused}")
    if conv.typed_reuse_diff:
        L.append(f"Info: typed rows reusing a standard typed recipe whose cells differ: "
                 + ", ".join(f"{d} {i}" for d, i in conv.typed_reuse_diff))
    no_time = sum(1 for d in data["days"] for it in d["items"] if it["minuteOfDay"] is None)
    L.append(f"Info: day items with no time in their label (minuteOfDay null): {no_time}")
    return "\n".join(L)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vault", type=Path, default=DEFAULT_VAULT,
                    help="vault root (the folder holding Nutrition/ and Daily/)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output JSON path")
    args = ap.parse_args(argv)

    conv = Converter(args.vault.expanduser())
    data = conv.build(date.today().isoformat())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(report(conv, data, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
