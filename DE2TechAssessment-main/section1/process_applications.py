"""Membership application processing pipeline.

Ingests application CSVs dropped into an input folder, cleans and
validates each application, then writes:
  - successful applications  -> <output>/successful/
  - unsuccessful applications -> <output>/unsuccessful/

An application is successful when ALL of the following hold:
  - name field is present
  - birthday can be parsed and the applicant is at least 18 years old
    as of 1 Jan 2022
  - mobile number is exactly 8 digits
  - email ends with .com or .net

Usage:
    python3 process_applications.py [--input-dir DIR] [--output-dir DIR]
"""
import argparse
import csv
import glob
import hashlib
import logging
import os
from datetime import datetime

logger = logging.getLogger(__name__)

# Cutoff for the age check: applicant must be >= 18 as of this date,
# i.e. born on or before 1 Jan 2004.
AGE_CUTOFF = datetime(2022, 1, 1)

# Honorifics and professional suffixes observed in the raw data. These are
# stripped so that first_name/last_name (and therefore the membership ID,
# which embeds last_name) are not polluted by titles.
NAME_PREFIXES = {"mr", "mrs", "ms", "miss", "dr"}
NAME_SUFFIXES = {"md", "dds", "dvm", "phd", "jr", "sr", "ii", "iii", "iv", "v"}

# Date formats present in the raw data. Profiling showed that for
# two-digit-first dates the convention is consistent per separator:
# slash dates are month-first (second component exceeds 12 in the data,
# first never does) and dash dates are day-first (the reverse).
DATE_FORMATS = ("%Y-%m-%d", "%Y/%m/%d", "%m/%d/%Y", "%d-%m-%Y")

VALID_EMAIL_SUFFIXES = (".com", ".net")

OUTPUT_FIELDS = [
    "membership_id", "first_name", "last_name", "email",
    "date_of_birth", "mobile_no", "above_18",
]
UNSUCCESSFUL_FIELDS = [
    "first_name", "last_name", "email", "date_of_birth",
    "mobile_no", "above_18",
]


def split_name(name):
    """Split a raw name into (first_name, last_name).

    Strips honorific prefixes (Mr., Dr., ...) and professional suffixes
    (MD, DDS, Jr., ...). Returns None when no usable name remains.
    """
    if not name or not name.strip():
        return None
    tokens = name.strip().split()
    while tokens and tokens[0].lower().rstrip(".") in NAME_PREFIXES:
        tokens = tokens[1:]
    while tokens and tokens[-1].lower().rstrip(".") in NAME_SUFFIXES:
        tokens = tokens[:-1]
    if len(tokens) < 2:
        return None
    return tokens[0], " ".join(tokens[1:])


def parse_birthday(raw):
    """Parse a raw date-of-birth string into canonical YYYYMMDD form.

    Returns None when the value matches none of the known formats.
    """
    if not raw or not raw.strip():
        return None
    raw = raw.strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).strftime("%Y%m%d")
        except ValueError:
            continue
    return None


def is_above_18(yyyymmdd):
    """True when the applicant is at least 18 years old as of 1 Jan 2022."""
    born = datetime.strptime(yyyymmdd, "%Y%m%d")
    try:
        eighteenth_birthday = born.replace(year=born.year + 18)
    except ValueError:
        # Born 29 Feb and the 18th year is not a leap year: the birthday
        # is observed on 1 Mar.
        eighteenth_birthday = datetime(born.year + 18, 3, 1)
    return eighteenth_birthday <= AGE_CUTOFF


def is_valid_mobile(mobile):
    """True when the mobile number is exactly 8 digits."""
    if not mobile:
        return False
    mobile = mobile.strip()
    return len(mobile) == 8 and mobile.isdigit()


def is_valid_email(email):
    """True when the email has a local part and ends with .com or .net."""
    if not email or "@" not in email:
        return False
    local, _, domain = email.partition("@")
    return bool(local) and domain.endswith(VALID_EMAIL_SUFFIXES)


def create_membership_id(last_name, yyyymmdd):
    """Build <last_name>_<first 5 hex chars of sha256(birthday)>."""
    digest = hashlib.sha256(yyyymmdd.encode("utf-8")).hexdigest()
    return f"{last_name}_{digest[:5]}"


def process_row(row):
    """Clean and validate one application row.

    Returns (record, success). The record always carries the cleaned
    fields so unsuccessful applications remain inspectable downstream.
    """
    name_parts = split_name(row.get("name"))
    birthday = parse_birthday(row.get("date_of_birth"))
    above_18 = bool(birthday) and is_above_18(birthday)

    record = {
        "first_name": name_parts[0] if name_parts else "",
        "last_name": name_parts[1] if name_parts else "",
        "email": (row.get("email") or "").strip(),
        "date_of_birth": birthday or (row.get("date_of_birth") or "").strip(),
        "mobile_no": (row.get("mobile_no") or "").strip(),
        "above_18": above_18,
    }

    success = (
        name_parts is not None
        and birthday is not None
        and above_18
        and is_valid_mobile(row.get("mobile_no"))
        and is_valid_email(row.get("email"))
    )
    if success:
        record["membership_id"] = create_membership_id(name_parts[1], birthday)
    return record, success


def run_pipeline(input_dir, output_dir, run_timestamp=None):
    """Consolidate every CSV in input_dir and split rows by outcome.

    Writes one consolidated file per outcome, stamped with the run time so
    hourly runs never overwrite each other. Returns row counts per outcome.
    """
    stamp = run_timestamp or datetime.now().strftime("%Y%m%d_%H%M%S")
    successful, unsuccessful = [], []

    input_files = sorted(glob.glob(os.path.join(input_dir, "*.csv")))
    logger.info("Found %d input file(s) in %s", len(input_files), input_dir)

    for path in input_files:
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                record, success = process_row(row)
                (successful if success else unsuccessful).append(record)

    for subdir, rows, fields in (
        ("successful", successful, OUTPUT_FIELDS),
        ("unsuccessful", unsuccessful, UNSUCCESSFUL_FIELDS),
    ):
        out_dir = os.path.join(output_dir, subdir)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, f"applications_{subdir}_{stamp}.csv")
        with open(out_path, "w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        logger.info("Wrote %d row(s) to %s", len(rows), out_path)

    return {"successful": len(successful), "unsuccessful": len(unsuccessful)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    base = os.path.dirname(os.path.abspath(__file__))
    parser.add_argument("--input-dir", default=os.path.join(base, "input"))
    parser.add_argument("--output-dir", default=os.path.join(base, "output"))
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    counts = run_pipeline(args.input_dir, args.output_dir)
    logger.info("Done: %(successful)d successful, %(unsuccessful)d unsuccessful",
                counts)


if __name__ == "__main__":
    main()
