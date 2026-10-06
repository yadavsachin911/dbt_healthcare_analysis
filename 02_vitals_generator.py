"""
IoT Health Vitals Simulator
============================
Simulates a streaming feed of patient vitals (heart rate, blood pressure,
SpO2, temperature) as JSON files, and loads them into a Snowflake internal
stage — standing in for the S3 + Snowpipe auto-ingest path from the
blueprint, with zero AWS setup required.

Setup:
    pip install snowflake-connector-python faker

Usage:
    python 02_vitals_generator.py --batches 5 --patients 20 --interval 5

Each batch writes one JSON-lines file locally, PUTs it to the
BRONZE_HEALTH_STAGE internal stage, then runs COPY INTO to load it into
bronze_vitals_raw. In production this PUT+COPY step is what Snowpipe
automates for you.
"""

import argparse
import json
import os
import random
import time
import uuid
from datetime import datetime, timezone

import snowflake.connector
from faker import Faker

fake = Faker()

# ------------------------------------------------------------------
# Snowflake connection config — set these as environment variables,
# never hardcode credentials in the script.
#   export SNOWFLAKE_ACCOUNT=xy12345.us-east-1
#   export SNOWFLAKE_USER=your_user
#   export SNOWFLAKE_PASSWORD=your_password
#   export SNOWFLAKE_WAREHOUSE=COE_ANALYTICS_WH
#   export SNOWFLAKE_DATABASE=HEALTHCARE_DB
#   export SNOWFLAKE_SCHEMA=BRONZE
# ------------------------------------------------------------------

def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "COE_ANALYTICS_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "HEALTHCARE_DB"),
        schema=os.environ.get("SNOWFLAKE_SCHEMA", "BRONZE"),
    )


def generate_patient_pool(n_patients):
    """Fixed pool of synthetic patient IDs so vitals repeat per patient
    over time, like a real wearable feed would."""
    return [f"PT-{uuid.uuid4().hex[:8].upper()}" for _ in range(n_patients)]


def generate_vital_reading(patient_id):
    """One synthetic vitals reading. Occasionally emits an outlier so the
    downstream Cortex/anomaly-detection layer has something to catch."""
    is_anomalous = random.random() < 0.05  # 5% anomaly rate

    heart_rate = random.randint(150, 180) if is_anomalous else random.randint(60, 100)
    systolic = random.randint(160, 200) if is_anomalous else random.randint(100, 130)
    diastolic = random.randint(100, 120) if is_anomalous else random.randint(65, 85)

    return {
        "patient_id": patient_id,
        "heart_rate": heart_rate,
        "blood_pressure": f"{systolic}/{diastolic}",
        "spo2": round(random.uniform(88, 100), 1),
        "temperature_f": round(random.uniform(97.0, 103.0), 1),
        "device_id": f"DEV-{random.randint(1000, 9999)}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def write_batch_file(readings, batch_num, out_dir="vitals_batches"):
    os.makedirs(out_dir, exist_ok=True)
    filename = os.path.join(out_dir, f"vitals_batch_{batch_num}_{int(time.time())}.json")
    with open(filename, "w") as f:
        for reading in readings:
            f.write(json.dumps(reading) + "\n")
    return filename


def load_to_snowflake(conn, filepath, stage_name="BRONZE_HEALTH_STAGE"):
    cur = conn.cursor()
    try:
        abs_path = os.path.abspath(filepath).replace("\\", "/")
        cur.execute(f"PUT file://{abs_path} @{stage_name} AUTO_COMPRESS=TRUE")
        staged_name = os.path.basename(filepath) + ".gz"
        cur.execute(f"""
            COPY INTO bronze_vitals_raw(raw_payload)
            FROM @{stage_name}/{staged_name}
            FILE_FORMAT = (TYPE = 'JSON')
            ON_ERROR = 'CONTINUE'
        """)
        print(f"  Loaded {filepath} -> bronze_vitals_raw")
    finally:
        cur.close()


def main():
    parser = argparse.ArgumentParser(description="Simulate IoT vitals feed into Snowflake.")
    parser.add_argument("--batches", type=int, default=5, help="Number of batches to send")
    parser.add_argument("--patients", type=int, default=20, help="Size of the patient pool")
    parser.add_argument("--readings-per-batch", type=int, default=50, help="Readings per batch")
    parser.add_argument("--interval", type=int, default=5, help="Seconds between batches")
    parser.add_argument("--dry-run", action="store_true", help="Only write local files, skip Snowflake load")
    args = parser.parse_args()

    patients = generate_patient_pool(args.patients)
    conn = None if args.dry_run else get_connection()

    try:
        for batch_num in range(1, args.batches + 1):
            readings = [
                generate_vital_reading(random.choice(patients))
                for _ in range(args.readings_per_batch)
            ]
            filepath = write_batch_file(readings, batch_num)
            print(f"Batch {batch_num}: wrote {len(readings)} readings to {filepath}")

            if not args.dry_run:
                load_to_snowflake(conn, filepath)

            if batch_num < args.batches:
                time.sleep(args.interval)
    finally:
        if conn:
            conn.close()

    print("Done. Query bronze_vitals_raw / silver_patient_vitals in Snowsight to see results.")


if __name__ == "__main__":
    main()
