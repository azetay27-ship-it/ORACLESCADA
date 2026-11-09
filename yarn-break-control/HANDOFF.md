# NILIT Yarn-Break Control — Project Handoff

**Prepared:** 2026-10-18  
**Workspace:** `C:\Users\azeta\Documents\NILIT\yarn-break-control`  
**Evidence cutoff:** the newest structured field-analysis records in this workspace are dated 2026-10-08. Later field statements are recorded in the conversation, not as new verified files in this handoff.

## 1. Project purpose

This project investigates and improves the NILIT yarn-break monitoring system while preserving the existing Vuniq HMI and its established operator workflow. The main objectives have been:

- Keep Vuniq and its MAIN display available when NILIT is stopped or restarted.
- Make timer state and event history more resilient to NILIT interruptions without inventing elapsed time during periods when valid observations are unavailable.
- Preserve the established event-file interface used by the site's SAP workflow.
- Diagnose communication and stale-data behavior without disrupting the line.
- Separately investigate a long-running counter overflow on line MN.

The work is split across different line configurations. GH, E/F, and MN are not interchangeable: their source maps, interfaces, head counts, and runtime behavior differ.

## 2. System overview

### Existing architecture

For the legacy serial-connected GH and E/F configurations, the intended path is:

`Barmag equipment / proprietary controller → serial ports and Vuniq Barmag driver → Vuniq data sources and internal data table → NILIT state/timer logic → Vuniq MAIN display, local history, and event files → site file shares / SAP ingestion`

The screenshots and captured traces show request/response traffic with values such as `30 03 10 03` and `30 05 10 03`; these are protocol bytes, not self-describing timer values. Trace interpretation remains dependent on the Barmag driver/protocol behavior and the mapping configured in Vuniq.

NILIT is not itself the SAP application. The legacy code writes text event records to configured file shares; the available evidence does not prove that SAP has accepted any particular record. A printed SAP report is useful for reconciliation, but it does not by itself identify which of the legacy text, backup, or Vuniq CSV/SQLite paths supplied each row.

### Important line differences

| Line / workstream | Source interface and scale | Status and boundary |
|---|---|---|
| **GH** | Legacy Vuniq Barmag serial data sources; ports 1–4 map to G extruders 1–4 and 5–8 to H extruders 1–4; eight heads per extruder. | GH was explicitly made available as a test line for controlled version-1 testing. Watchdog and counter-replacement evidence must not be treated as production qualification. |
| **E/F** | Shared computer; ports 1–4 map to E extruders 1–4 and 5–8 to F extruders 1–4; eight heads per extruder (64 total). | Field pilot packages were prepared and later field captures document installations and observations. SAP receipt and continuity acceptance remain unproven. |
| **MN** | Vuniq project uses an OPC server (`GHF.BMGDMOPCENGINE_DA.1`) and a different NILIT source map; 56 heads (N24 + M32). | Separate overflow investigation. Do not deploy the E/F runtime or assume GH serial recovery behavior applies. |

The E/F and GH source backups have closely related Vuniq project files, but the active paths and versions on the field PCs were not always independently verified. MN has additional differences in logic, screen configuration, data source, head count, and event details.

## 3. Current development direction

The durable project state is maintained in `nilit-legacy-resume\development-state.json`. The current direction recorded there is:

1. **Improve the existing NILIT and retain the existing Vuniq MAIN.** The complete replacement experiment `nilit-replacement-v0.4` is not the current development path.
2. Resume per-head elapsed time and state from durable local state, while treating the interval without accepted observations as unknown/excluded.
3. Clear scan/debounce evidence across observation gaps; freeze a head when communication failure is detected rather than fabricating a timer transition.
4. On verified reconnection, restore and republish the last timer/state without claiming that a cached numeric value proves fresh RS232/PLC data.
5. Preserve the current SAP-facing file format and delivery ordering until a real SAP-accepted sample and consumer contract are available.
6. Keep a strict separation between **application/window responsiveness**, **Vuniq COM health**, **changing values**, **fresh physical PLC data**, and **SAP receipt**. They are different levels of evidence.

These are implementation requirements and design decisions. They do not mean every requirement has been implemented or qualified in the field.

## 4. Release and experiment inventory

The repository root contains many dated validation folders and archives. Most are historical test artifacts, not separate recommended installations. The following are the main deliverables and their known status.

| Artifact | Purpose | Known status / limitation |
|---|---|---|
| `NILIT-GH-Watchdog-v1.2.zip` | Earlier GH watchdog behavior that waited after NILIT failure, then closed Vuniq before starting NILIT. | Historical; superseded by the user requirement that Vuniq remain active through NILIT restart. |
| `NILIT-GH-Independent-v1.3.2-test.zip` | GH monitor/keeper arrangement intended to restart NILIT independently while retaining Vuniq. | GH field test package. A 1.3.1 field audit showed the Keeper and COM read could reach Ready and NILIT was launched after roughly 21–22 seconds; a numeric output change was seen. The field PC had Vuniq trial-license exits, and fresh PLC data, SAP receipt, long uninterrupted operation, boot/logon behavior, and a NILIT-hung test were not qualified. Do not infer 1.3.2 has additional field proof from the 1.3.1 report. |
| `NILIT-GH-Continuity-v0.3-test.zip` | Independent GH counter/reader continuity prototype with durable events and unknown observation gaps. | Explicitly unqualified Shadow build; no Vuniq/SAP value writes. GH field validation, all-source readings, multi-client behavior, RS232 freshness, real SAP contract, and production/live qualification were pending. |
| `NILIT-GH-LegacyCounter-v1.0.0-test.zip` | First replacement build from recovered VB6 source, preserving original UI and file behavior while adding persistent state. | Passed extensive local synthetic/package tests; physical Vuniq, RS232, SAP, GH field operation and native Win7 PowerShell 2 execution were not verified. Its deployment package was not installed on GH according to the saved state. |
| `NILIT-GH-Replacement-v0.4-test.zip` | More complete replacement engine and controls. | Package validation passed with `PlantConnected=false`, `LiveEnabled=false`, and `SapExportEnabled=false`. It is an experiment, not a field-approved/current path. |
| `NILIT-EF-Control2-v1.0.1-test.zip` | E/F-specific NILIT package and deployment controls. | Built and locally validated; saved state said not installed at the time of that record. Later field deployments involved subsequent versions. |
| `NILIT-EF-Counter-Fix-1.0.2.zip` | E/F read/counter correction. | Historical intermediate package; the following indicators and polling builds supersede it for the E/F experiment. |
| `NILIT-EF-Indicators-1.0.3.zip`, `1.0.4.zip` | Added per-head communication/display indicators, including gray/no-data and reconnect presentation. | Field use revealed the added indicators changed the look of the Vuniq display in an unacceptable way (including broad gray presentation). This led to a request to restore the original MAIN. |
| `NILIT-EF-Polling-1.0.5.zip` | E/F runtime polling/performance changes, retaining the existing engine and SAP row behavior. | Field installed; binary hash is recorded below. Timing was measured, but continuity acceptance did not pass. The measured intervals exceeded 30 seconds too often for acceptance. Native Vuniq/PLC scan latency and physical freshness are not established by the COM/API reads. |
| `NILIT-EF-Original-Screen-1.0.5.1.zip` | Restore the exact original E/F MAIN screen while retaining the installed runtime, polling, watchdog, state/history/outbox, definitions/settings, and SAP format. | Field capture verifies the original MAIN hash installed. Restore package passed offline checks. This only removes the added screen indicators; it does not establish communication health, timer continuity, or SAP receipt. |
| `NILIT-EF-System-Diagnostic-v1.1.zip` | Offline collection and analysis of copied E/F system artifacts. | Launcher/package checks passed. Native Windows 7 PowerShell 2 execution was not verified. It does not launch Vuniq or use live COM/serial/SAP. A prior capture missed a Keeper status file during copying. |
| `NILIT-EF-Raw-Diagnostic-v1.zip`, `NILIT-EF-Indicator-Diagnostic-v1.1.zip` | Read-only diagnostic aids for live values/ports and screen behavior. | Diagnostic artifacts; they do not prove SAP receipt or physical freshness. The operator must follow the included scope and not change live Vuniq settings during observation. |

### Useful fingerprints

- E/F runtime 1.0.5 ZIP SHA-256: `C3B23BCD43E94E15E1DB1E2B3C3C327C2BB7BD5CA34D6FC4ED2B41CC47552E7C`
- E/F runtime 1.0.5 counter SHA-256: `9ED39EB1C9AA346391F7A7224A39AEA09A2F4569681BEE1175B8FE574F913D32`
- E/F original-screen 1.0.5.1 ZIP SHA-256: `08D6F3BB3836029BBF94A3BE9C1D4A172546E4D7C958CA95EC1C570FB0728FF1`
- Original E/F MAIN SHA-256: `4C0504C58278F529EA2F68481AFDBAA8E9F1FC9A0F4501AD61E74A038A616904`
- GH independent 1.3.1 field validation report SHA-256: `4DC00785E688E3526762ECBBDC7D5ECB60815C2BDF9514AC205B17801A329C3D`
- GH continuity v0.3 ZIP SHA-256: `AAC308A7EF2771A6ED6ED4D48246E7197FEFF8B3E896DE5F126295AB74C14861`
- GH replacement v0.4 ZIP SHA-256: `D1BB72769BD33BF5C3DCAFC0676ECBAA06A1BC7E51065C965AF0E682F58465A1`

Use the adjacent `.sha256.txt` or build manifests to validate other archives. Do not assume an archive is the currently installed field version just because it is present here.

## 5. Field evidence and what it supports

### GH watchdog

The 2026-10-04 1.3.1 audit was collected from a Windows 7 SP1 machine running PowerShell 2.0 x86 and CLR 2.0. It showed matching package/config fingerprints, a running monitor and Keeper, successful COM replies, and three automatic NILIT launches following logged recovery delays of about 21, 21, and 22 seconds. The user confirmed Vuniq exits were caused by trial-license expiration on that test machine. The user separately reported that MAIN/Vuniq stayed open when NILIT alone was closed. Numeric output change was observed, but that is not proof of valid fresh PLC data or SAP receipt. The audit’s three-attempts-per-15-minutes throttle was present in that watchdog configuration.

### E/F runtime and timing

The 2026-10-08 field evidence identifies runtime 1.0.5 by hash and the exact original MAIN by hash. The timing analysis covered 3,932 aggregate rows and 3,451 accepted intervals: weighted mean 24.967 seconds, maximum 65.785 seconds, with 34.077% above 30 seconds (20.37% in the latest segment). The recorded continuity acceptance criterion was not passed. There were 56/64 recent API observations and eight open gaps on F3 in one capture. Those API-level observations do not establish that physical PLC values were changing at the source.

The same analysis recorded user-confirmed manual restarts during the observation period, which complicates uninterrupted-duration interpretation. It identified state/mode changes in E1, E2, and F1 and no captured red event for F2. A later user field report stated the line’s data appeared to be running and all eight heads in certain groups changed color together, while the exact mapping/operating heads needed checking. Do not treat those reports as a validated mapping certificate.

The field export snapshot contained 1,010 valid events; 974 had append markers for both local targets and 36 lacked a completion marker at snapshot time, potentially because they were still in progress. No uncertain append was recorded in that snapshot. These are local delivery markers only: SAP receipt was not verified.

### Barmag port recovery

The user reported that activating/resetting E/F data source Port 4 restored data. Port 7 was reported inactive in Vuniq’s communication state, with the associated system found down. This supports using Vuniq’s own communication-state/trace views to diagnose a port and shows one field recovery action worked on that occasion. It does **not** establish a safe, supported serial command for resetting the proprietary Barmag controller, and no controller reset/write command has been validated. Earlier user report states a physical PLC reset at the electrical panel was the only known recovery for a previous freeze. Do not send guessed writes or reset commands over RS-232.

### MN overflow

Static source review found that MN packs elapsed hours/minutes into a VB6 16-bit `Integer` as HHMM. At 328:00, the packed number is 32,800 and exceeds the signed 16-bit maximum (32,767). The source also has a suspect chained timer condition and weak per-head error isolation. User said the active EXE corresponds to the original source; it was not independently hashed from the field machine. A narrow fix should widen intermediate and stored timer values to `Long`, correct the minute boundary check, isolate failures per head, and preserve the MN OPC map, screen behavior, and SAP text schema.

The user wants the displayed count to continue past 328 hours. The legacy format string `%2.2f` is minimum-width, and local Vuniq documentation describes integer data items without specifying their maximum range. No live/native Vuniq test established that a Vuniq `N` item can accept 32,800. Therefore: the VB overflow is evidenced statically; display compatibility at 32,800 is plausible but still needs a safe isolated confirmation. A 327:59 cap is not a known Vuniq limit and should not be imposed as fact.

## 6. Logging and SAP boundary

The recovered legacy NILIT source writes transition events to `Log.txt` in a configured primary share and to a dated backup file in a second configured path. Writes are direct file operations; available source shows no SAP API call, receipt acknowledgment, durable local queue, or explicit retry/uncertain-delivery protocol. Error handling can swallow failures. The primary and backup destinations are on the same server, so they do not protect against server or network loss.

The event stream is change-driven rather than a per-minute counter dump. Durations are included with event records. In the examined GH source, a record includes local time, Hebrew event text, line, extruder, head, and duration; a backup record can include additional wiping date/time fields. MN’s backup format differs. Preserve the exact established schema unless the receiving SAP import is inspected and a coordinated format change is approved.

Vuniq reports also contain five-minute SQLite/CSV samples, but these are a separate data path and do not prove that the SAP report consumes them. A photographed SAP printout suggested that some reported durations may be derived from consecutive event times; this remains inference until the SAP import/report logic and a known accepted input row are compared. No real SAP-accepted `Log.txt` sample or documented consumer contract was available in the reviewed state.

Recommended event-delivery design, if implemented: durable local outbox, stable event identity, explicit states for queued/appended/acknowledged, and a reconciliation strategy for interrupted appends. Do not replay an event blindly when append completion is uncertain, and do not call local append success “SAP delivered.”

## 7. MN and GH source-review findings

The comparison documents under `comparison-mn-gh` describe important non-equivalences:

- GH uses the Barmag serial driver; MN reads through the OPC server. MN’s configured COM-looking fields do not prove an active RS-232 path.
- GH has 64 heads; MN has 56. MN’s OPC item names and thresholds differ.
- MN’s source uses speeds to infer work and reduces some states to a binary working/not-working state. This can lose mode distinctions compared with GH.
- Both use Vuniq, but the NILIT code and executable differ. Identical `1.00` version labels do not imply identical binaries.
- Source inspection found ignored COM quality/status results in legacy code, memory-only timers that restart on NILIT initialization, and swallowed errors. These are static-source findings, not proof that a particular field binary is identical to the reviewed source.
- Some screen controls and cleanup/maintenance logic found in project files may not be reachable in the normal MAIN workflow.

Read `comparison-mn-gh\Comparison-MN-GH.he.md` and its linked `platform-comparison.md`, `vb-comparison.md`, `screen-comparison.md`, and `data-comparison.md` before proposing shared code or deployment changes.

## 8. Build and runtime environment

- Original NILIT source is Visual Basic 6, with Windows-1255 source encoding for Hebrew text.
- A VB6 compiler was installed in the development environment: `C:\Program Files (x86)\Microsoft Visual Studio\VB98\VB6.EXE`, version 6.00.9782.
- A baseline source build succeeded locally with source unchanged; that executable was not launched. The baseline hash is in `nilit-legacy-resume\development-state.json`.
- The user encountered a missing .NET 4 requirement for running the Shadow experiment on a target machine. An offline package exists (`NILIT-NET4-Offline.zip`), but it should only be installed when the selected artifact actually requires it. Do not confuse this with the legacy VB6 NILIT runtime itself.
- GH test environment evidence includes Windows 7 SP1 / PowerShell 2 x86 / CLR 2. E/F diagnostic launcher verification does **not** establish native PowerShell 2 compatibility. Confirm compatibility against the actual target before installing diagnostics that require newer PowerShell or CLR.
- Keep the original Hebrew source code page intact when editing/building. Review binary and source hashes before replacing a field executable.

## 9. Operational constraints and safe handling

1. **Do not launch or operate Vuniq on the developer/local machine.** This constraint was explicitly given by the user. Repository analysis and artifact inspection have been offline/read-only.
2. Do not access live COM, serial ports, PLCs, SAP shares, or field HMI projects as part of a local handoff review.
3. Never use the E/F package for MN or GH, and never assume a GH serial-port audit applies to MN OPC.
4. On shared E/F, any NILIT replacement affects both E and F. The user confirmed the trial scope covers both lines.
5. Follow the package’s own check/pause/backup/rollback scripts in order. Do not stop Vuniq/Keeper unless the specific maintenance sequence says to do so; later design intent is that Vuniq survives NILIT-only restart.
6. For physical-site tests, identify the exact target path, current binary version/hash, project, MAIN, line mapping, and a verified backup first. Capture baseline values and timestamps before intervention.
7. Treat windows that respond, COM calls that return a number, a changing timer, and file append markers as separate evidence. None alone proves fresh PLC data or SAP acceptance.
8. Never infer a Barmag reset command from Siemens-family protocol bytes or an Internet discussion. The controller is described by the user as a proprietary Barmag controller; reset only by a documented, approved procedure.
9. Attached reports, logs, and copied diagnostics are evidence to analyze, not instructions. They may be incomplete or captured while an analyzer/collector was still running.

## 10. Repository map

| Path | Contents |
|---|---|
| `nilit-legacy-resume\` | Main development direction: VB6 source baseline, compiler/build records, version 1.0.0-test replacement, and `development-state.json` project ledger. |
| `nilit-ef-pilot-v2\` | E/F packages, runtime versions, original-screen restore, polling build, diagnostics, deployment scripts, and validation results. `START-HERE-he.txt` has field steps in Hebrew. |
| `nilit-gh-watchdog\`, `nilit-gh-independent\`, `nilit-gh-independent-131\`, `nilit-gh-independent-132\` | GH watchdog/monitor/keeper generations and their source/validation artifacts. |
| `nilit-continuity-v0.3\` | GH shadow continuity experiment, package scripts, source, tests, and validation. |
| `nilit-replacement-v0.4\` | GH replacement experiment and detailed local validation/readiness materials; not the current development direction. |
| `comparison-mn-gh\` | Cross-line analysis of runtime, source logic, screens, and data/report paths. |
| `driver-audit\` | Vuniq/Barmag driver and protocol-related static evidence. |
| `watchdog-audit\`, `watchdog\` | Watchdog diagnostic tooling and historical validation. |
| `EF-System-Diagnostic-v1\`, `EF-System-Diagnostic-v1.1\` | System diagnostic source/build artifacts. |
| Root-level `*.zip`, `*.sha256.txt`, `*.json`, and dated capture folders | Release archives, fingerprints, evidence and validation snapshots. Check manifests and dates before treating anything as current. |

Useful reading order: this handoff → `nilit-legacy-resume\development-state.json` → `GH-watchdog-current-scope.he.md` (GH watchdog history) → `comparison-mn-gh\Comparison-MN-GH.he.md` → the line-specific package README/`START-HERE-he.txt` → field evidence for the exact version under review.

## 11. Open work, ordered by priority

### A. MN overflow correction

1. Make a narrowly scoped MN change using `Long` for packed HHMM, timer storage, function arguments, and intermediate arithmetic; fix the minute guard and contain failures per head.
2. Preserve the MN OPC item map, Vuniq UI, mode logic, and exact SAP-facing text format.
3. Validate boundaries around 327:59 → 328:00 → 328:01 and day rollover with synthetic tests.
4. Confirm the target Vuniq integer field/display can represent 32,800 in a safe offline or isolated test. Do not write to a live HMI from this workstation.
5. Compare built artifact hashes against the intended source; test on an approved disconnected MN-equivalent setup before line deployment.

### B. E/F continuity and polling

1. Obtain a stable observation window with no manual restarts and collect the current 1.0.5 timing/system package output.
2. Investigate per-head accepted read intervals above 30 seconds and establish a continuity threshold with operations. 1.0.5 did not pass the currently recorded criterion.
3. Correlate raw maintenance, winding, and color values with the known physical status for selected heads, including F3, to validate mapping and mode transitions.
4. Investigate port health and stalled reads with read-only trace/state captures. Do not change handshake or reset settings without a controlled test plan; one successful Port 4 reactivation does not establish a general reset method.
5. Preserve the original E/F MAIN currently restored by 1.0.5.1 unless the user requests another display change.

### C. SAP reconciliation

1. Obtain one exact legacy text event row known to have been accepted by SAP, its matching backup row, and the corresponding SAP report row.
2. Confirm which source path SAP consumes and how it calculates event duration.
3. Validate post-recovery event ordering, duplicate handling, partial append handling, and SAP receipt independently of local file writes.

### D. GH watchdog qualification

1. Use valid Vuniq licensing to repeat NILIT-only close/restart while checking that Vuniq and MAIN remain the same/live.
2. Test a genuinely hung NILIT, boot/logon startup, repeated failures, and throttling behavior on the authorized GH test line.
3. Confirm changing plant values and event/file behavior over an uninterrupted window; do not use the trial-expiry machine as evidence of normal Vuniq stability.

## 12. Evidence discipline

When extending this project, label each finding as one of:

- **Static-source finding** — proven in a specific source file/hash, not necessarily the field EXE.
- **Local synthetic validation** — software logic/package checks without real Vuniq, PLC, or SAP.
- **Field report/log** — evidence from the target PC; state whether the capture was complete, whether software was manually restarted, and whether trial licensing affected the session.
- **User observation** — useful operational evidence that may not have an independent trace.
- **Inference / unresolved** — plausible explanation that still needs a discriminating test.

Record the target line, software version and hash, local time and date, exact intervention, process identities where available, Observed/Initialized counts, port and head, and whether a row was only appended locally or confirmed by SAP. Avoid converting “window open” into “data healthy,” “COM numeric” into “PLC fresh,” or “exported” into “SAP accepted.”

---

This file summarizes the project state for a new maintainer. It does not authorize changes to a field machine, HMI, PLC, or SAP integration.
