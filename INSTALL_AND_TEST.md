# GatesFX Historical Discovery — Stage 1

**Status: written, NOT compiled, NOT executed.** Nothing here has been run in MetaEditor or the Strategy Tester. Every test below is a procedure for you to run; results go back for independent review. Stage 2 does not start without approval.

## 1. Scope

Implemented: M1 + M15 data access, incremental data-quality audit, run manifests, verified persistence, CRC-protected checkpoints, incomplete-run detection, resume-as-new-run, file-system self-test.
Not implemented (by instruction): features, outcomes, candidates, statistics, virtual trades, validation, HTML report. The EA contains no trading calls.

## 2. Install (new files only; nothing existing is touched)

Open MT5 → File → Open Data Folder. Copy the three folders from this package:

| From package | To |
|---|---|
| `MQL5/Include/GatesFX_HD/` (3 .mqh) | `<Data>\MQL5\Include\GatesFX_HD\` |
| `MQL5/Experts/GatesFX_HistoricalDiscovery/GatesFX_HistoricalDiscovery.mq5` | `<Data>\MQL5\Experts\GatesFX_HistoricalDiscovery\` |
| `MQL5/Scripts/GatesFX_HistoricalDiscovery/GatesFX_HD_HistoryProbe.mq5` | `<Data>\MQL5\Scripts\GatesFX_HistoricalDiscovery\` |
| `Tools/hd_inspect_runs.py` | anywhere outside MT5 (needs Python 3) |

Output goes only to `<Common>\Files\GatesFX_HistoricalDiscovery\` (Common = File → Open Common Data Folder, or `%APPDATA%\MetaQuotes\Terminal\Common`).

**Isolation check (do before and after every test):** record hashes of your existing GatesFX folders and compare.
```powershell
Get-ChildItem -Recurse "<path to existing GatesFX files>" | Get-FileHash | Export-Csv before.csv
# ...run tests...
Get-ChildItem -Recurse "<path to existing GatesFX files>" | Get-FileHash | Export-Csv after.csv
Compare-Object (Import-Csv before.csv) (Import-Csv after.csv) -Property Path,Hash
```
Empty compare output = nothing changed.

## 3. Compile

MetaEditor: open the `.mq5` EA → F7. Repeat for the script. Required evidence: screenshot or text of the Toolbox "Errors" tab showing **0 errors, 0 warnings** for both. If warnings appear (likely candidates: implicit type conversions), send them verbatim; do not suppress them.

Record source hashes for the review:
`python hd_inspect_runs.py --sha256 <the 5 source files>`

## 4. Controlled test procedure

Tester settings for all runs: Expert `GatesFX_HistoricalDiscovery`, symbol `XAUUSDz`, period M15, model **1 minute OHLC**, **no optimization**, no visual mode (visual mode changes tick pacing). Inputs: leave defaults unless stated. In `Journal` make sure no "refusing"/"INIT FAILED" lines.

| # | Test | Steps | Expected |
|---|---|---|---|
| T1 | FS self-test in tester | Tester range 2025.01.06–2025.01.17 | Run folder under `<Common>\Files\GatesFX_HistoricalDiscovery\Runs\HDT_...`; `fs_selftest.txt` shows T1/T2 PASS; T3 PASS or documented FAIL; T4 reports sandbox file (check it is NOT in Common) |
| T2 | Short full run | Same range | `completion.json` exists; inspector says `COMPLETE_VERIFIED`; `data_quality_summary.csv` has both M1 and M15 rows; `manifest.json` status `FINALISED` |
| T3 | Simulated crash | Same range, `InpTestAbortAtM15Bars=300` | No `completion.json`; manifest stays `STARTED`; `checkpoint_A/B.json` present; inspector says `INCOMPLETE_RESUMABLE`. Note: this simulates "OnDeinit never ran"; it is not a real kill |
| T4 | Real kill | Start a longer range (e.g. 2025.01–2025.06), kill `metatester64.exe` / terminal from Task Manager mid-run | Same inspector verdict as T3. Report exactly which process you killed |
| T5 | Resume | Same range as T3/T4, `InpResumeFromRunId=<aborted run id>` | **New** run folder; manifest `parent_run_id` = old id; old run folder byte-identical (hash it before/after); final counts equal T2's counts for the same range (bars, gaps, rows) — if not equal, that is a defect, report it |
| T6 | Corrupt checkpoint | Copy nothing; in a *copy* of an aborted run folder made outside Common, damage one checkpoint byte and run the inspector | Inspector falls back to the other checkpoint or reports no valid checkpoint |
| T7 | Full-period run | 2024.11.19–2026.11.18, defaults | Completes; send `manifest.json`, `data_quality_summary.csv`, first 50 rows of `data_quality.csv`, `execution.log`, Journal tail, wall-clock duration |
| T8 | History probe | Attach the script to an XAUUSDz chart in the live terminal (set Tools → Options → Charts → Max bars in chart to Unlimited first, restart) | `HDP_...` run folder; compare its M1/M15 bar counts and gap counts to T7. Differences are findings, not errors to hide |

## 5. Evidence to return

Compile output (both programs), SHA-256 list, isolation before/after comparison, T1–T8 folders (zip) and inspector output, Journal logs, T7 duration. Anything that failed, unchanged.

## 6. Statistical architecture (revised per your point 4)

- **MT5 role:** deterministic historical replay and causal observation extraction only (Stages 2–3): features, forward outcomes and observation ids exported to CSV with full provenance.
- **External role:** candidate discovery, confidence intervals, baselines, multiple-testing control, walk-forward and holdout evaluation run outside MT5 (Python), reading those CSVs. Each stage is unit-testable against synthetic data with known answers and re-computable independently of the tester.
- **Cross-check:** a Python re-implementation of selected features/outcomes on the exported raw bars must match the EA's CSV values before any statistics are trusted.
- Open decision for your approval: whether Stage 2 also exports raw M1/M15 bars (enables the cross-check) — recommended.

## 7. Design notes and known limitations (honest list)

1. **Tester clock is simulated.** `TimeCurrent`/`TimeLocal` in the tester are historical; the EA cannot read wall-clock date. Run ids use a tick-counter + sequence, uniqueness checked against existing folders; true creation time is the file-system timestamp. Log timestamps are labelled "tester/server clock".
2. **Full-period audit in the tester is by replay.** The tester hides data later than the simulated time, so coverage is audited bar by bar as the run proceeds, not up front. The probe script (T8) is the only way to see terminal history before running.
3. **M15 in the tester is built from M1 history.** M15/M1 agreement is therefore expected by construction; the earlier 47,236-bar diagnostic came from a different data path and does not establish M1 coverage.
4. **Session classification is approximate.** `SymbolInfoSessionTrade` reflects the symbol's *current* schedule. Gaps outside it are labelled `CLOSURE_PER_CURRENT_SESSION_SCHEDULE`; gaps inside it (holidays, early closes, real data loss) are labelled `UNEXPLAINED_MISSING_IN_SESSION` for human review. If the schedule is unavailable, all gaps are `UNCLASSIFIED_NO_SESSION_DATA`.
5. **Modelling mode is declared, not verified.** `avg_ticks_per_m1_bar` (~4 suggests OHLC mode) is weak evidence only.
6. **No source hash inside the EA.** MQL5 cannot hash its own source file at run time; hash externally (section 3).
7. **FileMove atomicity is not guaranteed.** Final manifest uses temp-write + FileMove, but `completion.json` (written last, after verification) is the authoritative completion marker.
8. **Not verified by me:** compilation, any MQL5 API behaviour in the tester (FILE_COMMON, FileMove, SymbolInfoSessionTrade, Bars/CopyRates ranges), warnings count, performance. All are marked unverified until you return evidence.
9. **Event cap:** `data_quality.csv` stops at `InpMaxEventRows`; suppressed events are counted in the summary and manifest, never dropped silently.
10. **Resume** requires identical symbol/period inputs and a non-final checkpoint; events written after the last checkpoint are re-detected on replay (the resumed CSV is rebuilt from the checkpointed prefix).
11. **Inspector tested only on synthetic fixtures** I generated (5 cases: verified, mismatch, resumable, corrupt checkpoint, empty). That tests the inspector's logic, not the EA's output format.
12. Timezone: broker server time throughout; UTC offset not assumed.
