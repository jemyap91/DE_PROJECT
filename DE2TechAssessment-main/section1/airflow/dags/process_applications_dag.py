"""Hourly membership application processing DAG.

Wraps the section 1 pipeline (process_applications.run_pipeline) in a
two-task Airflow DAG:

    process_hourly_drop  -> run the pipeline over input/, stamped with the
                            data interval's logical date so backfills and
                            re-runs name their outputs after the hour of
                            data they represent, not the wall-clock moment
                            the worker happened to execute
    check_quality        -> fail loudly on the silent failure modes a plain
                            scheduler would miss (zero rows ingested, or a
                            success-ratio collapse such as a renamed input
                            column making every row unsuccessful)

The pipeline module itself is unchanged: run_pipeline() takes its input and
output directories and an injectable run timestamp as arguments, so the DAG
is a thin orchestration shell around the same code the cron alternative runs.
"""
from datetime import timedelta

import pendulum
from airflow.sdk import dag, task

# Paths inside the Airflow containers; docker-compose.yml mounts section1/
# at /opt/pipelines/section1 and puts it on PYTHONPATH.
INPUT_DIR = "/opt/pipelines/section1/input"
OUTPUT_DIR = "/opt/pipelines/section1/output"

# The provided datasets yield ~10.5% successful applications. A healthy run
# landing far below that means the input data is malformed (e.g. renamed
# header) even though every row "processed" without error.
MIN_SUCCESS_RATIO = 0.02


@dag(
    dag_id="process_membership_applications",
    schedule="@hourly",
    start_date=pendulum.datetime(2026, 6, 1, tz="Asia/Singapore"),
    catchup=False,
    default_args={
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
    },
    tags=["section1", "membership"],
)
def process_membership_applications():

    @task
    def process_hourly_drop(**context) -> dict:
        from process_applications import run_pipeline

        # Manually triggered runs in Airflow 3 may carry no logical date;
        # fall back to the run_after instant so the stamp is always set.
        moment = context.get("logical_date") or context["dag_run"].run_after
        counts = run_pipeline(
            INPUT_DIR,
            OUTPUT_DIR,
            run_timestamp=moment.strftime("%Y%m%d_%H%M%S"),
        )
        return counts

    @task
    def check_quality(counts: dict) -> None:
        total = counts["successful"] + counts["unsuccessful"]
        if total == 0:
            raise ValueError(
                "0 rows processed — is the upstream hourly drop missing?"
            )
        ratio = counts["successful"] / total
        if ratio < MIN_SUCCESS_RATIO:
            raise ValueError(
                f"Success ratio anomaly: {counts['successful']}/{total} "
                f"({ratio:.1%}) — possible input schema drift."
            )

    check_quality(process_hourly_drop())


process_membership_applications()
