#!/usr/bin/env python3
"""Replay only LibreLane STAPostPNR for five host arrival windows.

Run after TinyTapeout/tt-gds-action in the SAME GitHub job and workspace.
No synthesis, CTS, placement, routing, or repair steps are selected here.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

VARIATIONS = (0, 1, 2, 4, 8)
KNOB = re.compile(r"^set host_variation_ns\s+[^\n]+$", re.MULTILINE)


def latest_checkpoint(run):
    candidates = list(run.glob("*-openroad-stapostpnr/state_in.json"))
    if not candidates:
        candidates = list(run.glob("*-openroad-rcx/state_out.json"))
    if not candidates:
        raise ValueError("No post-route STA input or RC extraction checkpoint found. The GDS run must reach parasitic extraction first.")
    return max(candidates, key=lambda p: int(p.parent.name.split("-", 1)[0]))


def input_files(state):
    if not state.get("nl") or not isinstance(state.get("spef"), dict) or not state["spef"]:
        raise ValueError("Checkpoint must contain a routed netlist and extracted SPEFs.")
    return [Path(state["nl"]), *(Path(p) for p in state["spef"].values())]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(case, variation, returncode):
    row = {"variation_ns": variation, "status": "TOOL_ERROR", "returncode": returncode}
    states = list(case.glob("*-openroad-stapostpnr/state_out.json"))
    if not states:
        return row
    metrics = json.loads(states[-1].read_text()).get("metrics", {})
    required = ("timing__setup__ws", "timing__hold__ws", "timing__setup_vio__count", "timing__hold_vio__count")
    if not all(k in metrics for k in required):
        return row
    row.update(
        setup_slack_ns=metrics[required[0]], hold_slack_ns=metrics[required[1]],
        setup_violations=metrics[required[2]], hold_violations=metrics[required[3]],
        max_cap_violations=metrics.get("design__max_cap_violation__count", ""),
        max_slew_violations=metrics.get("design__max_slew_violation__count", ""),
        corner_count=sum(k.startswith("timing__setup__ws__corner:") for k in metrics),
    )
    if returncode == 0:
        row["status"] = "PASS" if (float(row["setup_slack_ns"]) >= 0 and float(row["hold_slack_ns"]) >= 0 and int(row["setup_violations"]) == 0 and int(row["hold_violations"]) == 0) else "TIMING_FAIL"
    return row


def write_results(out, rows):
    fields = ["variation_ns", "status", "setup_slack_ns", "hold_slack_ns", "setup_violations", "hold_violations", "max_cap_violations", "max_slew_violations", "corner_count", "returncode"]
    with (out / "summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    lines = ["## Post route host timing sweep", "", "Same routed netlist and SPEFs for every case. PASS covers setup and hold only.", "", "| Variation | Result | Worst setup ns | Worst hold ns | Corners |", "| --- | --- | --- | --- | --- |"]
    for row in rows:
        def show(key):
            v = row.get(key, "")
            return f"{float(v):.4f}" if v != "" else "unavailable"
        lines.append(f"| +/-{row['variation_ns']} ns | {row['status']} | {show('setup_slack_ns')} | {show('hold_slack_ns')} | {row.get('corner_count', '')} |")
    lines += ["", "Input timing spread is exploratory. READY/output and reset constraints retain their provisional baseline. Capacitance and slew violations are separate checks; see summary.csv and the per-corner reports.", ""]
    text = "\n".join(lines)
    (out / "summary.md").write_text(text)
    if len(rows) == len(VARIATIONS) and os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text)
    if len(rows) == len(VARIATIONS):
        print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=Path("runs/wokwi"))
    parser.add_argument("--sdc", type=Path, default=Path("src/project.sdc"))
    parser.add_argument("--output", type=Path, default=Path("timing_sweep"))
    parser.add_argument("--no-docker", action="store_true", help="Only for an existing native LibreLane tool environment.")
    parser.add_argument("--dry-run", action="store_true", help="Prepare cases and print commands without running STA.")
    args = parser.parse_args()
    run, sdc, out = args.run.resolve(), args.sdc.resolve(), args.output.resolve()
    config = run / "resolved.json"
    checkpoint = latest_checkpoint(run)
    resolved = json.loads(config.read_text())
    state = json.loads(checkpoint.read_text())
    paths = input_files(state)
    for path in paths:
        if not path.is_file():
            raise ValueError(f"Missing routed input: {path}. Run in the original GDS job/workspace.")
    if float(resolved["CLOCK_PERIOD"]) != 50.0:
        raise ValueError("This sweep expects CLOCK_PERIOD=50 ns. Set src/config.json to 50 before building GDS.")
    template = sdc.read_text()
    matches = KNOB.findall(template)
    if len(matches) != 1 or "-clock_fall" not in template:
        raise ValueError("Use the source-synchronous project.sdc supplied with this package.")
    if float(matches[0].split()[2]) != 0:
        raise ValueError("Build the nominal layout with host_variation_ns=0; leave the source SDC at 0.")
    if out.exists():
        raise ValueError(f"Output directory already exists: {out}. Choose a fresh --output directory.")
    out.mkdir(parents=True)
    original = {str(p): digest(p) for p in [config, checkpoint, sdc, *paths]}
    (out / "inputs.json").write_text(json.dumps({"config": str(config), "checkpoint": str(checkpoint), "sha256": original}, indent=2))
    rows = []
    for variation in VARIATIONS:
        case = out / f"variation_{variation}ns"
        case.mkdir()
        case_sdc = case / "project.sdc"
        case_sdc.write_text(KNOB.sub(f"set host_variation_ns {variation}.0", template))
        command = [sys.executable, "-m", "librelane"]
        if not args.no_docker:
            command += ["--docker-no-tty", "--dockerized"]
        command += [
            "--manual-pdk", "--pdk-root", resolved["PDK_ROOT"],
            "--pdk", resolved["PDK"], "--scl", resolved["STD_CELL_LIBRARY"],
            "--flow", "Classic", "--only", "OpenROAD.STAPostPNR",
            "--with-initial-state", str(checkpoint),
            "--design-dir", resolved["DESIGN_DIR"],
            "--run-tag", f"host_variation_{variation}ns", "--force-run-dir", str(case),
            "--hide-progress-bar",
            # subprocess passes each argument literally. LibreLane 3.0.3
            # keeps path override values verbatim; JSON quotes become part
            # of the filename. Shell quoting belongs only in the printed
            # shlex.join representation, never in these argument values.
            "-c", "PNR_SDC_FILE=" + str(case_sdc),
            "-c", "SIGNOFF_SDC_FILE=" + str(case_sdc),
            str(config),
        ]
        (case / "command.json").write_text(json.dumps(command, indent=2))
        print(f"\n::group::Host variation +/-{variation} ns", flush=True)
        print(shlex.join(command), flush=True)
        if args.dry_run:
            row = {"variation_ns": variation, "status": "DRY_RUN", "returncode": ""}
        else:
            with (case / "sta-console.log").open("w") as log:
                proc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
            row = summarize(case, variation, proc.returncode)
            print(f"Result: {row}", flush=True)
        print("::endgroup::", flush=True)
        # Put diagnostics outside the collapsed group so the actual cause
        # is visible beside TOOL_ERROR in the main GitHub log.
        if row["status"] == "TOOL_ERROR":
            print(f"::error title=STA execution failed::Variation +/-{variation} ns; return code {row['returncode']}. See the log excerpt below and {case}/sta-console.log", flush=True)
            print((case / "sta-console.log").read_text()[-6000:], flush=True)
        rows.append(row)
        write_results(out, rows)
    if any(digest(Path(path)) != value for path, value in original.items()):
        raise ValueError("An original input changed during the sweep; results cannot be compared as one fixed layout.")
    # Expected stress timing failures are results. Tool/execution failures fail CI.
    return int(any(row["status"] == "TOOL_ERROR" for row in rows))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
