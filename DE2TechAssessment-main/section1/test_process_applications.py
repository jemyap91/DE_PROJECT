"""Unit tests for the membership application processing pipeline.

Run with: python3 -m unittest test_process_applications.py -v
"""
import csv
import os
import shutil
import tempfile
import unittest

from process_applications import (
    split_name,
    parse_birthday,
    is_above_18,
    is_valid_mobile,
    is_valid_email,
    create_membership_id,
    process_row,
    run_pipeline,
)


class TestSplitName(unittest.TestCase):
    def test_simple_two_token_name(self):
        self.assertEqual(split_name("William Dixon"), ("William", "Dixon"))

    def test_strips_salutation_prefix(self):
        self.assertEqual(split_name("Mr. Scott Martinez"), ("Scott", "Martinez"))
        self.assertEqual(split_name("Dr. Jeffrey Spencer"), ("Jeffrey", "Spencer"))
        self.assertEqual(split_name("Mrs. Jessica Gibson"), ("Jessica", "Gibson"))
        self.assertEqual(split_name("Miss Katherine Brennan"), ("Katherine", "Brennan"))

    def test_strips_professional_suffix(self):
        self.assertEqual(split_name("Sean Wang DDS"), ("Sean", "Wang"))
        self.assertEqual(split_name("Arthur Hall MD"), ("Arthur", "Hall"))
        self.assertEqual(split_name("Gregory Hill III"), ("Gregory", "Hill"))
        self.assertEqual(split_name("Adam Smith Jr."), ("Adam", "Smith"))

    def test_strips_both_prefix_and_suffix(self):
        self.assertEqual(split_name("Mr. Larry Grimes MD"), ("Larry", "Grimes"))
        self.assertEqual(split_name("Dr. Edward Marshall DDS"), ("Edward", "Marshall"))

    def test_empty_or_blank_name_returns_none(self):
        self.assertIsNone(split_name(""))
        self.assertIsNone(split_name("   "))
        self.assertIsNone(split_name(None))


class TestParseBirthday(unittest.TestCase):
    def test_iso_dash_format(self):
        self.assertEqual(parse_birthday("1974-09-10"), "19740910")

    def test_iso_slash_format(self):
        self.assertEqual(parse_birthday("1986/01/10"), "19860110")

    def test_slash_dates_are_month_first(self):
        # 07/03/2016 must be July 3rd, not March 7th
        self.assertEqual(parse_birthday("07/03/2016"), "20160703")
        self.assertEqual(parse_birthday("02/27/1974"), "19740227")

    def test_dash_dates_are_day_first(self):
        # 14-03-1973 must be March 14th
        self.assertEqual(parse_birthday("14-03-1973"), "19730314")
        self.assertEqual(parse_birthday("05-04-1990"), "19900405")

    def test_invalid_date_returns_none(self):
        self.assertIsNone(parse_birthday("not-a-date"))
        self.assertIsNone(parse_birthday(""))
        self.assertIsNone(parse_birthday(None))


class TestIsAbove18(unittest.TestCase):
    def test_clearly_above_18(self):
        self.assertTrue(is_above_18("19900101"))

    def test_turns_18_exactly_on_cutoff_counts(self):
        # Born 1 Jan 2004 -> turns 18 on 1 Jan 2022 -> eligible
        self.assertTrue(is_above_18("20040101"))

    def test_just_under_18_is_rejected(self):
        self.assertFalse(is_above_18("20040102"))

    def test_child_is_rejected(self):
        self.assertFalse(is_above_18("20160703"))

    def test_leap_day_birthday_does_not_crash(self):
        # Born 29 Feb 2004: 18th birthday falls in 2022 (not a leap year),
        # observed 1 Mar 2022, which is after the cutoff -> not eligible.
        self.assertFalse(is_above_18("20040229"))
        # Born 29 Feb 1988: well over 18 by the cutoff.
        self.assertTrue(is_above_18("19880229"))


class TestIsValidMobile(unittest.TestCase):
    def test_eight_digits_is_valid(self):
        self.assertTrue(is_valid_mobile("40601711"))

    def test_too_short_is_invalid(self):
        self.assertFalse(is_valid_mobile("737931"))

    def test_too_long_is_invalid(self):
        self.assertFalse(is_valid_mobile("123456789"))

    def test_non_numeric_is_invalid(self):
        self.assertFalse(is_valid_mobile("4060171a"))
        self.assertFalse(is_valid_mobile(""))
        self.assertFalse(is_valid_mobile(None))

    def test_surrounding_whitespace_is_tolerated(self):
        self.assertTrue(is_valid_mobile(" 40601711 "))


class TestIsValidEmail(unittest.TestCase):
    def test_com_domain_is_valid(self):
        self.assertTrue(is_valid_email("Kristen_Horn@lin.com"))

    def test_net_domain_is_valid(self):
        self.assertTrue(is_valid_email("someone@provider.net"))

    def test_other_tlds_are_invalid(self):
        self.assertFalse(is_valid_email("William_Dixon@woodward-fuller.biz"))
        self.assertFalse(is_valid_email("a@b.org"))
        self.assertFalse(is_valid_email("a@b.info"))

    def test_must_contain_at_sign(self):
        self.assertFalse(is_valid_email("no-at-sign.com"))
        self.assertFalse(is_valid_email(""))
        self.assertFalse(is_valid_email(None))


class TestCreateMembershipId(unittest.TestCase):
    def test_format_is_lastname_underscore_hash_prefix(self):
        # sha256("19860110") = "3864b..." (first 5 hex chars)
        self.assertEqual(create_membership_id("Dixon", "19860110"), "Dixon_3864b")


class TestProcessRow(unittest.TestCase):
    def _row(self, **overrides):
        row = {
            "name": "William Dixon",
            "email": "William_Dixon@provider.com",
            "date_of_birth": "1986/01/10",
            "mobile_no": "40601711",
        }
        row.update(overrides)
        return row

    def test_fully_valid_row_is_successful(self):
        record, success = process_row(self._row())
        self.assertTrue(success)
        self.assertEqual(record["first_name"], "William")
        self.assertEqual(record["last_name"], "Dixon")
        self.assertEqual(record["date_of_birth"], "19860110")
        self.assertEqual(record["above_18"], True)
        self.assertEqual(record["membership_id"], "Dixon_3864b")

    def test_missing_name_is_unsuccessful(self):
        record, success = process_row(self._row(name=""))
        self.assertFalse(success)

    def test_bad_mobile_is_unsuccessful(self):
        record, success = process_row(self._row(mobile_no="12345"))
        self.assertFalse(success)

    def test_bad_email_is_unsuccessful(self):
        record, success = process_row(self._row(email="William_Dixon@provider.biz"))
        self.assertFalse(success)

    def test_under_18_is_unsuccessful(self):
        record, success = process_row(self._row(date_of_birth="07/03/2016"))
        self.assertFalse(success)
        self.assertEqual(record["above_18"], False)

    def test_unparseable_birthday_is_unsuccessful(self):
        record, success = process_row(self._row(date_of_birth="garbage"))
        self.assertFalse(success)


class TestRunPipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.input_dir = os.path.join(self.tmp, "input")
        self.output_dir = os.path.join(self.tmp, "output")
        os.makedirs(self.input_dir)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _write_csv(self, filename, rows):
        path = os.path.join(self.input_dir, filename)
        with open(path, "w", newline="") as fh:
            writer = csv.DictWriter(
                fh, fieldnames=["name", "email", "date_of_birth", "mobile_no"]
            )
            writer.writeheader()
            writer.writerows(rows)

    def test_consolidates_multiple_files_and_splits_by_outcome(self):
        self._write_csv("applications_dataset_1.csv", [
            {"name": "William Dixon", "email": "wd@provider.com",
             "date_of_birth": "1986/01/10", "mobile_no": "40601711"},
            {"name": "Tony Shepherd", "email": "ts@provider.com",
             "date_of_birth": "07/03/2016", "mobile_no": "71144712"},
        ])
        self._write_csv("applications_dataset_2.csv", [
            {"name": "Sherry Gonzalez", "email": "sg@provider.net",
             "date_of_birth": "14-03-1973", "mobile_no": "66744895"},
        ])

        counts = run_pipeline(self.input_dir, self.output_dir)

        self.assertEqual(counts, {"successful": 2, "unsuccessful": 1})

        success_files = os.listdir(os.path.join(self.output_dir, "successful"))
        failed_files = os.listdir(os.path.join(self.output_dir, "unsuccessful"))
        self.assertEqual(len(success_files), 1)
        self.assertEqual(len(failed_files), 1)

        with open(os.path.join(self.output_dir, "successful", success_files[0])) as fh:
            rows = list(csv.DictReader(fh))
        self.assertEqual(len(rows), 2)
        ids = {r["membership_id"] for r in rows}
        self.assertIn("Dixon_3864b", ids)


if __name__ == "__main__":
    unittest.main()
