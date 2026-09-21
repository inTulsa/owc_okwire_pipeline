# Requires: pip install requests pandas, beautifulsoup4, openpyxl, xlrd
# (xlrd is only used for the pre-2019 legacy .xls workbooks still linked
# on the page; openpyxl reads everything from 2019 onward)
import os
import re
import urllib.parse

import pandas as pd
import requests
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Config (Step 1a-1c / 2a-2e)
# ---------------------------------------------------------------------------
PAGE_URL = (
    "https://oklahoma.gov/education/services/student-information/"
    "state-public-enrollment-totals.html"
)

# Step 2a: the page's main content grid — the outer scope every container
# search below is confined to, so a stray "text aem-GridColumn--default--12"
# div elsewhere on the page (nav, footer, an unrelated widget) can't get
# mistaken for a download section.
GRID_WRAPPER_CLASSES = ("aem-Grid", "aem-Grid--12", "aem-Grid--default--12")

# Step 2a: the layout container that actually holds the download links,
# searched for only inside a GRID_WRAPPER_CLASSES wrapper
CONTAINER_CLASS = "aem-GridColumn--default--12"

# Step 2b: multi-sheet workbooks are linked with a plain "Click here" anchor;
# the sheet we need out of them is always named this
CLICK_HERE_TEXT = "click here"
SCHOOL_TOTALS_SHEET = "School Totals by Race"

# Step 2c: the per-school Race/Gender/Grade workbook is linked from a
# bulleted <li><a> whose text is this — spacing after "w/" is inconsistent
# year to year on the live page ("w/Ethnicity" vs "w/ Ethnicity"), so this
# gets matched normalized. This is the only source Step 2c-2d ever reports
# or reshapes as a discovered file.
SCHOOL_ETHGEN_LI_TEXT = "School Site Totals w/Ethnicity and Gender"

# Step 2d: that same section links a companion <li><a> with County/District/
# School Name (and School Code) but no Race/Gender breakdown. It is never a
# source in its own right — it's fetched silently, purely as a backup for
# any blank location value on the primary file above, and only when that
# primary actually exists in this section. Matched exact-normalized so it
# never also matches SCHOOL_ETHGEN_LI_TEXT itself.
SCHOOL_SITE_TOTALS_LI_TEXT = "School Site Totals"

# Step 2d: the School Site Totals workbook's first sheet carries one of
# these titles most years; if none match, its true first sheet is used.
SCHOOL_SITE_SHEET_PREFERENCE = ["GG_BySITE", "ALL sites", "School Totals"]

# The visible anchor text for a "click_here" link is just "Click here" —
# not useful as a title — so titles use this friendlier label instead.
FRIENDLY_LABEL = {
    "click_here": SCHOOL_TOTALS_SHEET,
    "school_ethgen_li": SCHOOL_ETHGEN_LI_TEXT,
    "school_site_li": SCHOOL_SITE_TOTALS_LI_TEXT,
}

DOWNLOAD_DIR = "data"
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Step 1b/5e: raw .xlsx/.xls originals downloaded from the website live in
# their own subfolder, separate from the data directory's own output. That
# keeps Step 5e's cleanup simple (it only ever has to clear DOWNLOAD_DIR's
# top level, which cleanup_download_dir() already does by skipping
# subdirectories) and gives Step 1b's cache a stable home across runs: an
# original source file already here is reused as-is, never re-downloaded --
# though only a file behind a printed "[found]" record earns that caching;
# cleanup_source_dir() below prunes everything else (i.e. every "School
# Site Totals" companion) at the end of each run.
SOURCE_DIR = os.path.join(DOWNLOAD_DIR, "data_sources")
os.makedirs(SOURCE_DIR, exist_ok=True)

HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; PythonScript/1.0)"}

# ---------------------------------------------------------------------------
# Column vocabulary (Step 2e, 4a, 4b)
# ---------------------------------------------------------------------------
id_columns = ["SchoolYear", "County", "District", "School Name", "Grade"]

value_columns = [
    "His M", "His F",
    "AmInd M", "AmInd F",
    "Asian M", "Asian F",
    "Black M", "Black F",
    "Pac Is M", "Pac Is F",
    "White M", "White F",
    "Multi M", "Multi F",
]

desired_columns = id_columns[:4] + value_columns + ["Grade"]

race_map = {
    "His": "Hispanic or Latino",
    "AmInd": "American Indian or Alaska Native",
    "Asian": "Asian",
    "Black": "Black or African American",
    "Pac Is": "Native Hawaiian or Other Pacific Islander",
    "White": "White",
    "Multi": "Two or more races",
}

gender_map = {
    "M": "Male",
    "F": "Female",
}

# Step 2c's verbose column variant -> the abbreviated tokens above
verbose_to_abbrev_v1 = {
    "Hispanic Male": "His M",
    "Hispanic Female": "His F",
    "American Indian Male (Non Hispanic)": "AmInd M",
    "American Indian Female (Non Hispanic)": "AmInd F",
    "Asian Male (Non Hispanic)": "Asian M",
    "Asian Female (Non Hispanic)": "Asian F",
    "Black Male (Non Hispanic)": "Black M",
    "Black Female (Non Hispanic)": "Black F",
    "Hawaiian or Pacific Islander Male (Non Hispanic)": "Pac Is M",
    "Hawaiian or Pacific Islander Female (Non Hispanic)": "Pac Is F",
    "White Male (Non Hispanic)": "White M",
    "White Female, (Non Hispanic)": "White F",
    "Two or More Races Male (Non Hispanic)": "Multi M",
    "Two or More Races Female (Non Hispanic)": "Multi F",
}

# A third naming convention observed on the live workbooks for FY21-22 and
# FY22-23 (the WAVE system export flips word order and drops the space
# before "Latino")
verbose_to_abbrev_v2 = {
    "HispanicLatino Male": "His M",
    "HispanicLatino Female": "His F",
    "American Indian(Non-Hispanic) Male": "AmInd M",
    "American Indian(Non-Hispanic) Female": "AmInd F",
    "Asian(Non-Hispanic) Male": "Asian M",
    "Asian(Non-Hispanic) Female": "Asian F",
    "Black(Non-Hispanic) Male": "Black M",
    "Black(Non-Hispanic) Female": "Black F",
    "Hawaiian or Pacific Islander(Non-Hispanic) Male": "Pac Is M",
    "Hawaiian or Pacific Islander(Non-Hispanic) Female": "Pac Is F",
    "White(Non-Hispanic) Male": "White M",
    "White(Non-Hispanic) Female": "White F",
    "Two or More Races(Non-Hispanic) Male": "Multi M",
    "Two or More Races(Non-Hispanic) Female": "Multi F",
}

verbose_to_abbrev = {**verbose_to_abbrev_v1, **verbose_to_abbrev_v2}

# Some workbooks carry both "Grade Code" (e.g. "3H") and a prose "Grade"
# description column; we want the code — format_grade() parses that — not
# the prose. "School Site" is Step 2d's companion workbook's own name for
# what we call "School Name" everywhere else.
alt_id_columns = {"Grade Code": "Grade", "School Site": "School Name"}


def normalize(col) -> str:
    """Lower-case and strip everything but letters/digits so header text
    matches loosely across punctuation and spacing differences."""
    return re.sub(r"[^a-z0-9]", "", str(col).lower())


# One rename lookup that understands both the abbreviated and verbose
# column spellings, keyed by their normalized form.
normalized_desired = {normalize(c): c for c in desired_columns}
for verbose, abbrev in verbose_to_abbrev.items():
    normalized_desired[normalize(verbose)] = abbrev
for alt, canonical in alt_id_columns.items():
    normalized_desired[normalize(alt)] = canonical

_known_signatures = [
    {normalize(c) for c in value_columns},
    {normalize(c) for c in verbose_to_abbrev_v1},
    {normalize(c) for c in verbose_to_abbrev_v2},
]
_HEADER_SCAN_ROWS = 8


def _matches_known_signature(columns) -> bool:
    cols = {normalize(c) for c in columns}
    return any(sig.issubset(cols) for sig in _known_signatures)


# ---------------------------------------------------------------------------
# Step 2a: LocatingContainers
# ---------------------------------------------------------------------------
def _has_classes(tag, *required):
    """True if `tag` is a <div> whose class list contains every token in
    `required` — e.g. both "text" and "aem-GridColumn--default--12"."""
    if tag.name != "div":
        return False
    classes = tag.get("class") or []
    return all(token in classes for token in required)


def locate_containers(soup: BeautifulSoup):
    """Step 2a, two levels deep: first the page's main
    `<div class="aem-Grid aem-Grid--12 aem-Grid--default--12">` wrapper,
    then every `<div class="text aem-GridColumn aem-GridColumn--default--12">`
    inside it — the sibling `<div class="title ...">` holds the FY heading,
    not the links, so "text" has to match too or nearest_fiscal_year_heading()
    below would never find a distinct heading container to compare against.
    Falls back to a whole-page search if the wrapper isn't found, rather than
    silently returning nothing.
    """
    wrappers = soup.find_all(lambda tag: _has_classes(tag, *GRID_WRAPPER_CLASSES))
    if not wrappers:
        print(f"  Warning: no <div class=\"{' '.join(GRID_WRAPPER_CLASSES)}\"> "
              f"wrapper found — searching the whole page instead")
        wrappers = [soup]

    containers = []
    for wrapper in wrappers:
        containers.extend(wrapper.find_all(lambda tag: _has_classes(tag, "text", CONTAINER_CLASS)))
    return containers


# ---------------------------------------------------------------------------
# Step 2b / 2c / 2d: ClassifyAnchor -> RequestWorkook -> Checksheet -> RecordFile (ScanningLinks phase)
# ---------------------------------------------------------------------------
_school_ethgen_li_signature = normalize(SCHOOL_ETHGEN_LI_TEXT)
_school_site_li_signature = normalize(SCHOOL_SITE_TOTALS_LI_TEXT)


def classify_anchor(a_tag):
    """Return "click_here", "school_ethgen_li", "school_site_li", or None.

    The exact-normalized match matters here: "School Site Totals" must NOT
    also match "School Site Totals w/Ethnicity and Gender" — the page links
    both, and they are different, unrelated downloads.
    """
    text = a_tag.get_text(strip=True)

    if text.lower() == CLICK_HERE_TEXT:
        return "click_here"

    if a_tag.find_parent("li") is not None:
        norm_text = normalize(text)
        if norm_text == _school_ethgen_li_signature:
            return "school_ethgen_li"
        if norm_text == _school_site_li_signature:
            return "school_site_li"

    return None


def nearest_fiscal_year_heading(a_tag):
    """Step 5a: the nearest preceding <h2> whose text starts with "FY" and
    whose parent is a `<div class="title aem-GridColumn--default--12">` —
    the section heading for this link's container. Returns None if the page
    doesn't have one (e.g. the workbook already carries its own Year column).
    Both a "School Site Totals w/Ethnicity and Gender" link and its
    "School Site Totals" companion sit under the same heading, which is how
    Step 2d pairs them up later.
    """
    for h2 in a_tag.find_all_previous("h2"):
        text = h2.get_text(strip=True)
        if not text.upper().startswith("FY"):
            continue
        if h2.find_parent(lambda tag: _has_classes(tag, "title", CONTAINER_CLASS)):
            return text
    return None


def parse_fiscal_year(heading):
    """"FY 2023/2024" -> "2023-2024"; a lone "FY 2024" or "FY24" -> "2023-2024",
    same (year-1)-(year) convention clean_year() uses for a bare Year column."""
    if not heading:
        return None
    years4 = re.findall(r"20\d{2}", heading)
    if len(years4) >= 2:
        return f"{years4[0]}-{years4[1]}"
    if len(years4) == 1:
        y = int(years4[0])
        return f"{y - 1}-{y}"
    years2 = re.findall(r"\d{2}", heading)
    if years2:
        y = 2000 + int(years2[-1])
        return f"{y - 1}-{y}"
    return None


def find_sheet_by_name(xls: pd.ExcelFile, target: str):
    norm_target = normalize(target)
    for sheet_name in xls.sheet_names:
        if normalize(sheet_name) == norm_target:
            return sheet_name
    return None


def find_header_row(xls: pd.ExcelFile, sheet_name: str):
    """Real-world workbooks often carry a title row (or two) above the
    actual header — scan for the row that actually looks like our header."""
    for header_row in range(_HEADER_SCAN_ROWS):
        try:
            preview = pd.read_excel(xls, sheet_name=sheet_name, header=header_row, nrows=0)
        except Exception:
            continue
        if _matches_known_signature(preview.columns):
            return header_row
    return None


def find_sheet_by_column_signature(xls: pd.ExcelFile):
    """Returns (sheet_name, header_row), or (None, None) if nothing matches."""
    for sheet_name in xls.sheet_names:
        header_row = find_header_row(xls, sheet_name)
        if header_row is not None:
            return sheet_name, header_row
    return None, None


# ---------------------------------------------------------------------------
# Step 2d: School Site Totals — sheet/header lookup for the companion file
# ---------------------------------------------------------------------------
def find_school_site_sheet(xls: pd.ExcelFile) -> str:
    """Prefer a sheet literally titled one of SCHOOL_SITE_SHEET_PREFERENCE;
    fall back to the workbook's actual first sheet — both conventions are
    used across different fiscal years on the live page."""
    for wanted in SCHOOL_SITE_SHEET_PREFERENCE:
        norm_wanted = normalize(wanted)
        for sheet_name in xls.sheet_names:
            if norm_wanted in normalize(sheet_name):
                return sheet_name
    return xls.sheet_names[0]


#  "School Code" on current-year workbooks, "Site Code" on older ones — same
# role (a unique per-school join key), just renamed year to year.
_SCHOOL_CODE_ALIASES = ("schoolcode", "sitecode")


def find_school_code_column(columns):
    for c in columns:
        if normalize(c) in _SCHOOL_CODE_ALIASES:
            return c
    return None


def find_school_site_header_row(xls: pd.ExcelFile, sheet_name: str):
    """The companion workbook's own shape: a County column, a School Name/
    Site column, and a School/Site Code — that code is what backfill_
    missing_location() below joins on."""
    for header_row in range(_HEADER_SCAN_ROWS):
        try:
            preview = pd.read_excel(xls, sheet_name=sheet_name, header=header_row, nrows=0)
        except Exception:
            continue
        cols_norm = {normalize(c) for c in preview.columns}
        has_location = "county" in cols_norm and ("schoolname" in cols_norm or "schoolsite" in cols_norm)
        has_school_code = find_school_code_column(preview.columns) is not None
        if has_location and has_school_code:
            return header_row
    return None


# ---------------------------------------------------------------------------
# Step 2a-2d: LocatingContainers -> ScanningLinks -> Done (RecordsDiscovered phase checkpoint)
# ---------------------------------------------------------------------------
def discover_enrollment_files(page_url: str):
    print(f"Requesting {page_url} ...")
    resp = requests.get(page_url, headers=HEADERS, timeout=60)
    resp.raise_for_status()  # fatal: 4xx/5xx halts the script here

    soup = BeautifulSoup(resp.text, "html.parser")
    containers = locate_containers(soup)
    print(f"Found {len(containers)} container(s) with class '{CONTAINER_CLASS}'")

    records = []
    companions_by_year = {}
    seen_urls = set()

    for container in containers:
        anchors = [(a, classify_anchor(a)) for a in container.find_all("a", href=True)]
        has_primary = any(pattern == "school_ethgen_li" for _, pattern in anchors)

        for a_tag, pattern in anchors:
            if pattern is None:
                continue

            if pattern == "school_site_li" and not has_primary:
                continue  # no primary in this section -- nothing to back fill

            candidate_url = urllib.parse.urljoin(page_url, a_tag["href"].strip())
            if candidate_url in seen_urls:
                continue
            seen_urls.add(candidate_url)

            year_label = nearest_fiscal_year_heading(a_tag)
            fiscal_year = parse_fiscal_year(year_label)

            # Step 1b/1c: an original source file already in data_sources/
            # is kept and reused as-is -- only fetch it over the network
            # (1c) if it isn't there yet. was_cached is carried onto the
            # record so the missing-files notice after the loop knows which
            # ones, if any, had to be added back this run.
            local_name = os.path.basename(urllib.parse.unquote(candidate_url))
            local_path = os.path.join(SOURCE_DIR, local_name)
            was_cached = os.path.exists(local_path)

            if was_cached:
                print(f"  [skip] {local_name} exists and already in {SOURCE_DIR}/ — skipping...")
            else:
                try:
                    file_resp = requests.get(candidate_url, headers=HEADERS, timeout=60)
                    file_resp.raise_for_status()
                except requests.exceptions.RequestException as exc:
                    print(f"  [skip] {candidate_url} unreachable ({exc}) — next anchor")
                    continue
                with open(local_path, "wb") as f:
                    f.write(file_resp.content)

            try:
                xls = pd.ExcelFile(local_path)
            except Exception as exc:
                print(f"  [skip] {candidate_url} is not a readable workbook ({exc})")
                continue

            # Windows keeps this file handle locked until it's explicitly
            # closed -- without the `with` here, cleanup_source_dir() below
            # can fail to delete a companion moments later in the same run.
            with xls:
                if pattern == "click_here":
                    sheet_name = find_sheet_by_name(xls, SCHOOL_TOTALS_SHEET)
                    header_row = find_header_row(xls, sheet_name) if sheet_name else None
                elif pattern == "school_site_li":
                    sheet_name = find_school_site_sheet(xls)
                    header_row = find_school_site_header_row(xls, sheet_name)
                else:
                    sheet_name, header_row = find_sheet_by_column_signature(xls)

            if sheet_name is None or header_row is None:
                print(f"  [skip] {candidate_url} has no matching sheet — next anchor")
                continue

            record = {
                "title": f"{year_label} — {FRIENDLY_LABEL[pattern]}" if year_label else FRIENDLY_LABEL[pattern],
                "url": candidate_url,
                "pattern": pattern,
                "sheet": sheet_name,
                "header_row": header_row,
                "local_path": local_path,
                "fiscal_year": fiscal_year,
                "cached": was_cached,
            }

            if pattern == "school_site_li":
                if fiscal_year:
                    companions_by_year[fiscal_year] = record
                continue

            print(f"  [found] {record['title']} -> sheet '{sheet_name}' (header row {header_row})")
            records.append(record)

    print(f"\nDiscovery complete: {len(records)} file(s) found.\n")

    # Step 1b: name whichever found sources weren't already in data_sources/
    # -- missing, and just re-fetched to fill that gap -- or confirm none
    # were, rather than leaving the user to infer it from the [skip] lines
    # scrolled past above.
    if records:
        missing_names = [os.path.basename(r["local_path"]) for r in records if not r["cached"]]
        if missing_names:
            print(f"{len(missing_names)} source file(s) were missing from {SOURCE_DIR}/ "
                  f"and have been added back: {', '.join(missing_names)}\n")
        else:
            print(f"No source files are missing -- all {len(records)} were already in {SOURCE_DIR}/.\n")

    return records, companions_by_year

# ---------------------------------------------------------------------------
# Step 3, 4a, 4b, 5a, 5b: unpivot, relabel Race/Gender/Year/Grade (ReshapingRecords phase)
# ---------------------------------------------------------------------------
def split_race_gender(column_name: str):
    parts = column_name.rsplit(" ", 1)
    race_abbr, gender_abbr = parts[0], parts[1]
    return race_map.get(race_abbr, race_abbr), gender_map.get(gender_abbr, gender_abbr)


def clean_year(value):
    if pd.isna(value):
        return value
    s = str(value).strip()
    try:
        s = str(int(float(s)))
    except (ValueError, TypeError):
        pass
    if re.fullmatch(r"20\d{2}", s):
        y = int(s)
        return f"{y - 1}-{y}"
    return s


def format_grade(value):
    """Step 5b: P.. -> Pre-Kindergarten, K.. -> Kindergarten, 1-12 -> "Nth
    Grade" — everything else (13, OHP, AE, or any other code not listed in
    Step 5b) becomes "Other"."""
    if pd.isna(value):
        return value
    s = str(value).strip()
    su = s.upper()
    if su in ("3F", "3H"):
        return "Pre-Kindergarten"
    if su.startswith("P"):
        return "Pre-Kindergarten"
    if su.startswith("K"):
        return "Kindergarten"
    try:
        n = int(float(s))
    except (ValueError, TypeError):
        return "Other"
    if 1 <= n <= 12:
        suffix = "th" if 11 <= (n % 100) <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
        return f"{n}{suffix} Grade"
    return "Other"


# ---------------------------------------------------------------------------
# Step 2d: backfill any blank County/District/School Name on the primary
# file using the companion "School Site Totals" workbook, joined on School
# Code. This is an exact lookup, never an estimate — a value either has a
# real match or it stays blank.
# ---------------------------------------------------------------------------
def backfill_missing_location(df: pd.DataFrame, companion_record: dict) -> pd.DataFrame:
    loc_cols = [c for c in ("County", "District", "School Name") if c in df.columns]
    school_code_col = find_school_code_column(df.columns)
    if not loc_cols or school_code_col is None:
        return df

    blank = df[loc_cols].isna() | df[loc_cols].astype(str).apply(lambda s: s.str.strip() == "")
    if not blank.to_numpy().any():
        return df

    ref = pd.read_excel(companion_record["local_path"], sheet_name=companion_record["sheet"],
                         header=companion_record["header_row"])
    ref_school_code_col = find_school_code_column(ref.columns)
    if ref_school_code_col is None:
        return df

    ref_rename = {c: normalized_desired[normalize(c)] for c in ref.columns if normalize(c) in normalized_desired}
    ref = ref.rename(columns=ref_rename)
    # Join key as string on both sides — one side often reads as int64,
    # the other as object, and a dtype mismatch would silently match nothing.
    ref[ref_school_code_col] = ref[ref_school_code_col].astype(str).str.strip()
    ref_lookup = ref.dropna(subset=[ref_school_code_col]).drop_duplicates(subset=ref_school_code_col) \
                     .set_index(ref_school_code_col)
    df_codes = df[school_code_col].astype(str).str.strip()

    filled = 0
    for col in loc_cols:
        if col not in ref_lookup.columns:
            continue
        col_blank = df[col].isna() | (df[col].astype(str).str.strip() == "")
        if not col_blank.any():
            continue
        looked_up = df_codes[col_blank].map(ref_lookup[col])
        df.loc[col_blank, col] = looked_up
        filled += int(looked_up.notna().sum())

    if filled:
        print(f"  Backfilled {filled} blank County/District/School Name value(s) "
              f"from {companion_record['local_path']}")
    return df


def reshape_workbook(record: dict, companion: dict = None) -> pd.DataFrame:
    print(f"Processing {record['local_path']} (sheet '{record['sheet']}') ...")
    df = pd.read_excel(record["local_path"], sheet_name=record["sheet"], header=record["header_row"])

    # Some workbooks carry both "Grade Code" (e.g. "3H") and a prose "Grade"
    # description column; keep the code, which alt_id_columns maps to Grade.
    if "Grade Code" in df.columns and "Grade" in df.columns:
        df = df.drop(columns=["Grade"])

    rename_map = {c: normalized_desired[normalize(c)] for c in df.columns if normalize(c) in normalized_desired}
    df = df.rename(columns=rename_map)

    # Step 2d: fill blank location values before School Code (not in our
    # column whitelist) gets dropped below.
    if companion is not None:
        df = backfill_missing_location(df, companion)

    # Some sheets carry no Year column at all — fall back to the fiscal
    # year read off the page heading the link was found under.
    if "SchoolYear" not in df.columns and record.get("fiscal_year"):
        df["SchoolYear"] = record["fiscal_year"]

    present_id_cols = [c for c in id_columns if c in df.columns]
    present_value_cols = [c for c in value_columns if c in df.columns]
    missing = [c for c in value_columns if c not in df.columns]
    if missing:
        print(f"  Warning: race/gender columns not found and skipped: {missing}")

    df = df[present_id_cols + present_value_cols]

    melted = df.melt(
        id_vars=present_id_cols,
        value_vars=present_value_cols,
        var_name="RaceGender",
        value_name="Count",
    )
    race_gender = melted["RaceGender"].apply(split_race_gender)
    melted["Race"] = race_gender.apply(lambda x: x[0])
    melted["Gender"] = race_gender.apply(lambda x: x[1])
    melted = melted.drop(columns=["RaceGender"])

    id_cols_no_grade = [c for c in present_id_cols if c != "Grade"]
    grade_col = ["Grade"] if "Grade" in present_id_cols else []
    melted = melted[id_cols_no_grade + ["Race", "Gender"] + grade_col + ["Count"]]

    melted = melted.rename(columns={
        "SchoolYear": "Year",
        "School Name": "School",
        "Count": "Total",
    })

    if "Year" in melted.columns:
        melted["Year"] = melted["Year"].apply(clean_year)
        before = len(melted)
        melted = melted[
            melted["Year"].notna()
            & (melted["Year"].astype(str).str.strip() != "")
            & (melted["Year"].astype(str).str.strip().str.lower() != "nan")
        ]
        removed = before - len(melted)
        if removed:
            print(f"  Removed {removed} row(s) with a blank Year")

    if "Grade" in melted.columns:
        melted["Grade"] = melted["Grade"].apply(format_grade)

    print(f"  -> {len(melted)} row(s)")
    return melted


# ---------------------------------------------------------------------------
# Step 5e: once the comprehensive CSV exists, delete only the intermediate
# per-file "_formatted.csv" outputs used to build it, leaving DOWNLOAD_DIR's
# top level with that one comprehensive file. The original .xlsx/.xls files
# in SOURCE_DIR (data/data_sources/) are never touched here -- skipped as a
# subdirectory below -- both because Step 6 says to keep them there and
# because Step 1b's cache depends on them surviving to the next run. Either
# way -- something removed or nothing to remove because it was already
# clean -- the user is told which happened, not left to assume silence
# means success.
# ---------------------------------------------------------------------------
def cleanup_source_dir(keep_paths, quiet: bool = False) -> None:
    """Only a workbook behind a printed "[found]" line is a real source --
    a "School Site Totals" companion is downloaded into SOURCE_DIR too but
    never printed as found (it's only ever read internally, for Step 2d's
    backfill), so it has no claim on data_sources/'s cache and is removed
    here once it's no longer needed. That also means a companion is
    re-fetched fresh on every run rather than reused like a found file.

    quiet=True skips both messages below -- used when the run already found
    nothing new (see main()) and said so; a "removed N companions" or
    "already clean" line on top of that would just be repeating old news.
    """
    keep_paths = {os.path.abspath(p) for p in keep_paths}
    removed = 0
    for name in os.listdir(SOURCE_DIR):
        path = os.path.abspath(os.path.join(SOURCE_DIR, name))
        if path in keep_paths or os.path.isdir(path):
            continue
        os.remove(path)
        removed += 1
    if quiet:
        return
    if removed:
        print(f"-> Removed {removed} file(s) from {SOURCE_DIR}/ that weren't behind a [found] record.")
    else:
        print(f"-> Nothing to remove from {SOURCE_DIR}/ — already clean.")


def cleanup_download_dir(keep_path: str, quiet: bool = False):
    """quiet=True skips both messages below -- see cleanup_source_dir()."""
    keep_path = os.path.abspath(keep_path)
    removed = 0
    for name in os.listdir(DOWNLOAD_DIR):
        path = os.path.abspath(os.path.join(DOWNLOAD_DIR, name))
        if path == keep_path or os.path.isdir(path):
            continue
        if os.path.splitext(name)[1].lower() != ".csv":
            continue  # only .csv intermediates are ever written directly into DOWNLOAD_DIR
        os.remove(path)
        removed += 1
    if quiet:
        return
    if removed:
        print(f"\nRemoved {removed} intermediate .csv file(s) from directory {DOWNLOAD_DIR}/")
        print(f"-> Kept {os.path.basename(keep_path)}; original source file(s) stay cached in {SOURCE_DIR}/")
    else:
        print(f"\nNo intermediate .csv files to remove from {DOWNLOAD_DIR}/ — already clean.")
        print(f"-> Kept {os.path.basename(keep_path)}; original source file(s) stay cached in {SOURCE_DIR}/")


# ---------------------------------------------------------------------------
# Step 5c, 5d, 5e, 6: per-file CSV, merged CSV, cleanup, all in the data
# directory (MergeAll, WriteComprehensiveCSV, CleanupDownloads, Done phases)
# ---------------------------------------------------------------------------
def main():
    records, companions_by_year = discover_enrollment_files(PAGE_URL)
    if not records:
        print("No matching files were found on the page. Nothing to do.")
        return

    merged_out_path = os.path.join(DOWNLOAD_DIR, "primary_enrollment_data.csv")

    if all(r["cached"] for r in records):
        # Step 1b: the "no new sources" notice already printed inside
        # discover_enrollment_files() -- nothing found this run justifies a
        # rebuild, so the existing comprehensive CSV is left exactly as it
        # is rather than regenerated from the same inputs as last time.
        # Companions still got freshly downloaded for nothing, though, so
        # they're cleaned up same as any other run.
        print(f"-> {merged_out_path} left unchanged (no new source files).")
        cleanup_download_dir(merged_out_path, quiet=True)
        cleanup_source_dir((r["local_path"] for r in records), quiet=True)
        print("\nDone.")
        return

    reshaped_frames = []
    for record in records:
        companion = companions_by_year.get(record["fiscal_year"]) if record["pattern"] == "school_ethgen_li" else None

        try:
            tidy = reshape_workbook(record, companion=companion)
        except Exception as exc:
            print(f"  [skip] {record['local_path']} failed to reshape ({exc})")
            continue

        # Step 5e: intermediate output belongs in DOWNLOAD_DIR, not
        # alongside the cached original in data_sources/ -- that directory
        # is only ever originals, never derived files.
        formatted_name = os.path.splitext(os.path.basename(record["local_path"]))[0] + "_formatted.csv"
        out_path = os.path.join(DOWNLOAD_DIR, formatted_name)
        tidy.to_csv(out_path, index=False)
        print(f"  -> formatted file saved to {out_path}\n")
        reshaped_frames.append(tidy)

    if not reshaped_frames:
        print("No files reshaped successfully. Nothing to merge.")
        return

    merged = pd.concat(reshaped_frames, ignore_index=True)
    merged.to_csv(merged_out_path, index=False)

    print(f"Merged {len(reshaped_frames)} file(s) into a single CSV:")
    print(f"-> {merged_out_path} ({len(merged)} total rows)")

    cleanup_download_dir(merged_out_path)
    # Companions have already done their job (backfilling, above) by now --
    # safe to drop anything in SOURCE_DIR that isn't a [found] record.
    cleanup_source_dir(r["local_path"] for r in records)
    print("\nDone.")

if __name__ == "__main__":
    main()
