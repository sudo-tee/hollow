# Application profiling (experimental)

This is an opt-in actual-window probe, not the headless renderer or Lua harness.
It is experimental: validate the visible picker, backend, key delivery and resize
geometry before treating a run as a comparison. A successful process launch or
PostMessage alone does not prove that the intended UI was rendered or scrolled.

Build a Windows ReleaseFast application with frame profiling compiled in. In
Windows PowerShell, run one combination per fresh output directory, for example:

```powershell
./scripts/run-app-profile.ps1 -Exe C:\path\to\hollow-native.exe `
  -Fixture C:\path\to\app-profile-fixture.lua -OutputDir C:\temp\profile-palette-clay-selection `
  -Picker palette -Backend clay -Scenario selection -Seconds 20
python scripts/app_profile_summary.py C:\temp\profile-palette-clay-selection\frames.csv --warmup 30 --rendered-only
```

Repeat `palette`/`workspace`, `clay`/`legacy`, and `idle`/`selection`/`resize`.
Fixture uses 100 fixed synthetic entries and a callable workspace source. The
runner starts its own native process with isolated APPDATA/LOCALAPPDATA and an
explicit config override, restores the prior foreground window when possible,
and sends page keys or resizes only that process's window. It does not inject
mouse input, manipulate existing windows, force-kill processes, or close any
other window. The application also loads its base configuration; audit that config
and shell startup before running. Closing the owned process is requested on exit;
if it fails, the runner leaves it running. Frame output requires orderly shutdown.
The fixture checks its initial Lua overlay/backend and writes a ready marker;
the runner aborts if that marker is missing. This does not verify native paint.
Runner and fixture have not yet been validated as a reproducible end-to-end
comparison; in particular, synthetic posted keys and pre-mux picker opening may
not exercise the intended paths on every build. Confirm visually and with UI
semantics or screenshots; do not assume `selection` is mouse wheel scrolling.

`frames.csv` stores at most 200,000 callback samples; `dropped` reports overflow.
`start_ns` is monotonic, `elapsed_ns` is callback wall time including idle and
frame-cap waits, and `thread_cpu_ns` is Windows render-thread user+kernel CPU
(100 ns units, often coarser actual resolution), not total process CPU. A blank
CPU field means unavailable. `rendered=1` means `sg_commit` was called, not that
the GPU finished. Callback start intervals include scheduling and, when filtering
to rendered samples, skipped callbacks between them. Samples include startup,
warmup, measurement and shutdown; the simple summary's warmup is a callback
count, not phase synchronization. Isolate runs and inspect raw timestamps before
comparing. Nearest-rank p50/p95/p99 and max are reported, without interpolation.
Profiling adds two thread-time queries and in-memory recording per callback;
fixed sample storage and output writing also perturb memory and shutdown.

`memory.csv` samples the selected GUI process every ~250 ms: Windows working
set, private bytes and cumulative process CPU. It excludes child processes, can
miss peaks, and cannot attribute bytes to Clay, native allocations, Lua or GPU.
`metadata.json` identifies scenario and process. Use independent runs, same
window conditions, enough warmup, and repeat runs on an idle machine. The runner
does not currently enforce matching monitor, DPI, client dimensions, or stable
foreground state; resize uses alternating 1000/1200 outer widths and 800 outer
height. Record those conditions separately. No GPU timing is measured.

For read-only sampling of an already identified process, use
`scripts/app_profile_memory.ps1 -GuiPid PID -Output C:\temp\memory.csv`.
Never select another user's process without permission. Raw frame capture can
also be enabled directly by setting `HOLLOW_PROFILE_FRAMES` to a fresh absolute
path before launch. Existing output at that path is overwritten on shutdown.

## Smoke test, not a comparison

2026-10-29, Windows 10.0.26200, WSL2, ReleaseFast crossbuild, 1440x900
initial window, fallback embedded font, vsync off. Four-second palette/Clay
selection smoke test confirmed fixture's initial backend but did not verify
posted keys changed selection. Whole trace after discarding 30 callbacks and
selecting rendered callbacks: 194 callbacks, wall p50/p95/p99 15.32/17.41/18.18
ms including sleeps, render-thread CPU 0/15.625/31.25 ms with coarse 15.625 ms
resolution, no dropped samples. Twelve process samples ranged 149,008,384–
156,631,040 working-set bytes and 281,223,168–288,145,408 private bytes.
Samples also include time outside the four-second scenario. They do not establish
backend performance, native allocation cost, or actual scrolling.

Raw Windows output: `C:\Users\FBELAN~1\AppData\Local\Temp\hollow-app-profile-4b1f26f6014f40178e72246ac65c1a46`.
A separate workspace/legacy resize smoke trace is at
`C:\Users\FBELAN~1\AppData\Local\Temp\hollow-app-profile-0a008cbc30d145789fa3cc317a894345`;
resize and visual behavior have not been independently verified.
