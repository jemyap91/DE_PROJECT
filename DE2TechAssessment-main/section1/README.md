# Section 1: Data Pipelines — Membership Application Processing

A pipeline that ingests membership application CSVs dropped into a folder on an
hourly basis, cleans and validates them, creates membership IDs for successful
applications, and writes successful and unsuccessful applications to separate
output folders for downstream consumers.

## Folder layout

```
section1/
├── process_applications.py       # the pipeline (Python 3 stdlib only, no dependencies)
├── test_process_applications.py  # unit tests (32 tests)
├── input/                        # landing zone — datasets are dropped here hourly
├── output/
│   ├── successful/               # applications_successful_<run timestamp>.csv
│   └── unsuccessful/             # applications_unsuccessful_<run timestamp>.csv
└── README.md
```

## Running it

```bash
# process everything currently in input/
python3 process_applications.py

# or point at explicit folders
python3 process_applications.py --input-dir /path/to/drop --output-dir /path/to/out

# run the test suite
python3 -m unittest test_process_applications -v
```

No third-party packages are required — only the Python 3 standard library.

## Scheduling (hourly)

The pipeline is a single idempotent script, so plain cron is sufficient.
Output files are stamped with the run timestamp, so consecutive runs never
overwrite each other. To run at the top of every hour:

```cron
0 * * * * /usr/bin/python3 /path/to/section1/process_applications.py >> /path/to/section1/pipeline.log 2>&1
```

The same script drops directly into an Airflow DAG if richer orchestration
(retries, alerting, backfills) is needed — `run_pipeline(input_dir, output_dir)`
is importable and side-effect free apart from writing the output files:

```python
PythonOperator(
    task_id="process_applications",
    python_callable=run_pipeline,
    op_kwargs={"input_dir": INPUT_DIR, "output_dir": OUTPUT_DIR},
)  # schedule_interval="@hourly"
```

## Processing logic

Each row from every `*.csv` in the input folder is consolidated and passed
through the following steps:

1. **Name cleaning** — honorific prefixes (`Mr.`, `Mrs.`, `Ms.`, `Miss`, `Dr.`)
   and professional suffixes (`MD`, `DDS`, `DVM`, `PhD`, `Jr.`, `III`, …) are
   stripped, then the name is split into `first_name` and `last_name`.
   Rows without a usable name are treated as unsuccessful applications.
2. **Birthday normalisation** — the raw `date_of_birth` is parsed and
   reformatted to `YYYYMMDD` (see *Date format handling* below).
3. **`above_18` flag** — `True` when the applicant is at least 18 years old as
   of **1 Jan 2022**, i.e. born on or before 1 Jan 2004. Leap-day birthdays
   (29 Feb) are observed on 1 Mar in non-leap years.
4. **Validity checks** — an application is **successful** only if all hold:
   - mobile number is exactly 8 digits
   - applicant is above 18 as defined above
   - email ends with `.com` or `.net`
   - (and the row had a usable name and parseable birthday)
5. **Membership ID** — for successful applications only:
   `<last_name>_<first 5 hex chars of SHA256(YYYYMMDD birthday)>`,
   e.g. `Dixon_3864b`.

Successful rows go to `output/successful/`, everything else to
`output/unsuccessful/`. Unsuccessful rows keep their cleaned fields so
downstream engineers can see why they failed.

## Date format handling

The raw data mixes four date formats. Profiling all 4,999 rows showed the
two-digit-first formats follow one consistent convention per separator —
in slash dates the *second* component exceeds 12 (so they are month-first),
while in dash dates the *first* component exceeds 12 (day-first):

| Raw example  | Interpreted as | Evidence in data                          |
|--------------|----------------|-------------------------------------------|
| `1974-09-10` | `YYYY-MM-DD`   | unambiguous                                |
| `1986/01/10` | `YYYY/MM/DD`   | unambiguous                                |
| `02/27/1974` | `MM/DD/YYYY`   | second part >12 in 760 rows, first never  |
| `14-03-1973` | `DD-MM-YYYY`   | first part >12 in 735 rows, second never  |

A row whose date matches none of these formats is routed to unsuccessful
(its birthday cannot be validated).

## Assumptions

- **"Over 18 as of 1 Jan 2022"** is read as *at least* 18 on that date:
  applicants born exactly on 1 Jan 2004 are eligible.
- **Valid email** is read as any domain ending in `.com` or `.net`
  (the spec's `@emailprovider.com` / `@emailprovider.net` is taken as a
  placeholder for the TLD rule). `.biz`, `.org` and `.info` addresses fail.
- A row with a name but fewer than two tokens after stripping titles cannot
  be split into first/last name and is treated as unsuccessful.
- Input files are valid CSV with the header
  `name,email,date_of_birth,mobile_no`.

## Results on the provided datasets

| Outcome      | Rows  |
|--------------|-------|
| Successful   | 526   |
| Unsuccessful | 4,473 |
| **Total**    | 4,999 |

Processed outputs are committed under `output/`.
