from google.cloud import bigquery
import subprocess, sys

phases = [4, 5, 6, 7, 8, 99]
for ph in phases:
    print(f"\n{'='*60}")
    print(f"Running Phase {ph}...")
    result = subprocess.run(
        [sys.executable, "run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py", "--phase", str(ph)],
        input="y\n",
        capture_output=True,
        text=True
    )
    # Print last 5 lines of output
    lines = (result.stdout + result.stderr).strip().split('\n')
    for line in lines[-8:]:
        print(line)
    if result.returncode != 0:
        print(f"ERROR in phase {ph}!")
        print(result.stderr[-500:])
        break
print("\nDone.")
