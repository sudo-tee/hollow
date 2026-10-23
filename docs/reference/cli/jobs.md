# Background execution jobs

Run work in a new tab **without changing workspace, tab, pane focus, or keyboard
input destination**. The original pane and tab stay active. Jobs use real PTYs,
not detached OS sessions; Hollow must remain running.

```sh
# Direct executable + literal arguments (no shell expansion):
hollow-cli job spawn --cwd /work/project -- npm test

# Explicit shell mode (pipes, expansion, builtins):
hollow-cli job spawn --cwd /work/project --shell 'npm test && npm run build'

# Load interactive shell configuration, wait, then close the completed pane:
hollow-cli --timeout 120 job spawn --user-shell --wait --auto-close \
  --cwd /work/project -- make test
```

Both `hollow-cli` and `hollow cli` expose the same commands. Rebuild/restart Hollow
to expose the `background_jobs` capability.

Lua integrations can use [`hollow.term.jobs.spawn`](../lua/term.md#owned-background-jobs)
and its async `wait`, `output`, and `cleanup` methods over the same backend.

## Full workflow

```bash
job=$(hollow-cli job spawn --cwd /work/project -- npm test) || exit 1
pane=$(jq -r .pane_id <<< "$job")
token=$(jq -r .token <<< "$job")

# Wait for real process exit, never terminal revisions or a fixed sleep.
result=$(hollow-cli --timeout 120 job wait --id "$pane" --token "$token") || exit 1

if jq -e '.status == 0' <<< "$result" >/dev/null; then
  hollow-cli job cleanup --id "$pane" --token "$token"
else
  echo "Tests failed; job retained for inspection."
  hollow-cli job output --id "$pane" --token "$token" > failure-output.json
  # Raw bytes, including ANSI/OSC: inspect safely rather than replay escapes.
  jq -r .data failure-output.json | base64 -d | cat -v
fi
```

Spawn returns `pane_id`, `tab_id`, `workspace_id`, a random `token`, and `cursor`.
The event cursor is captured **before** process launch; even fast exit can be
replayed through [external events](events.md):

```sh
hollow-cli --timeout 120 wait process-exit --after CURSOR --pane PANE_ID
```

Prefer `job wait` for owned jobs: it checks retained process state before waiting
on events, works for already-completed jobs, and safely reconciles event-journal
overflow by querying that same owned job again. It never relaunches work.

## Commands and results

```sh
hollow-cli job get     --id PANE_ID --token TOKEN
hollow-cli job output  --id PANE_ID --token TOKEN
hollow-cli job wait    --id PANE_ID --token TOKEN
hollow-cli job cleanup --id PANE_ID --token TOKEN
hollow-cli job wait    --id PANE_ID --token TOKEN --auto-close
```

### Shell setup, inline waiting, and automatic cleanup

- **`--user-shell`** opts into the target user's interactive shell startup files
  (e.g. Bash `.bashrc`, Zsh `.zshrc`, Fish configuration, or PowerShell profiles).
  Uses the pane's configured shell on native hosts, the host user's login shell
  on agents, or explicit WSL inner shell configuration. It does not reuse a live
  pane's shell process, copy temporary exports/virtualenv activation, or request
  login-shell startup. Startup files can print output or override the command's
  environment. Unsupported shells fail explicitly; native cmd is unsupported in
  this mode. Existing configured shell flags may disable profile loading.
  `-- ARGV...` remains literal: arguments are safely quoted inside the shell;
  `--user-shell --shell 'COMMAND'` deliberately enables shell syntax.
- **`--wait`** on spawn waits over the socket and prints one final JSON result
  combining job state/status with `pane_id`, `tab_id`, `workspace_id`, and `token`.
  As with `job wait`, CLI exit zero means completion was observed, not that tests
  passed: inspect `status`. Timeout/wait errors print the recoverable spawn handle
  on stdout and an error on stderr, with nonzero CLI exit. No relaunch or cleanup
  occurs on timeout. Global `--timeout SECONDS` controls the wait budget.
- **`--auto-close`** works on `job spawn --wait` and `job wait`. After completion,
  it performs ownership-checked cleanup and adds `closed: true` to the result.
  This includes **failed workloads**: retained terminal/output is discarded too.
  Without `--wait`, spawn rejects `--auto-close` before launching anything. A
  cleanup failure is an error, not a false successful-close report. Timeout never
  triggers cleanup; manual closure by another client remains possible.

`--wait` and `--auto-close` are CLI workflow flags, not `job_spawn` API arguments;
the API exposes `user_shell: true` plus existing get/events/cleanup operations.

- **Spawn:** completes pane creation, not workload execution. Returns IDs and
  ownership information instead of a generic queued acknowledgement. Asynchronous
  agent/bootstrap failure appears as an exited job, generally status 125; native
  fork/exec failure may likewise be reported by process exit rather than spawn.
- **Get/wait:** return `pane_id`, `state` (`running` or `exited`), nullable process
  `status`, current event `cursor`, and output byte/loss indicators. `job wait`
  requires socket transport. CLI exit zero means completion was observed; inspect
  `status` for command success. Unknown status is `null`, never invented as zero.
- **Output:** returns `{encoding:"base64", data:"...", truncated:false,
  incomplete:false, capacity_bytes:1048576}`. It is the last **1 MiB of raw PTY
  bytes**, including escape sequences and non-UTF-8 data, not viewport text or
  separate stdout/stderr streams. `truncated` means older bytes were evicted;
  `incomplete` means allocation failure lost bytes. Capture continues as output
  arrives, including any trailing output after observed process exit. This is not
  an unlimited durable log or a guarantee that descendants closed all output.
  POSIX job waits/cleanup also wait for PTY EOF and draining; descendants holding
  the PTY open can therefore cause a timeout. Agent exit is ordered after output.
  Native Windows process exit can precede final ConPTY bytes; retain the pane and
  inspect output before cleanup if those trailing bytes matter.
- **Cleanup:** closes only the original pane matching ID **and token**. Running
  jobs or queued output fail with `job_running`, not silent cancellation. Other
  panes added to that tab are preserved, and inactive-job cleanup does not change
  focus. There is no broad tag-based “close all jobs” operation.

Both successful and failed panes remain until explicit cleanup, manual user
closure, workspace/tab closure, or Hollow shutdown. Timeout and CLI disconnect
leave the job intact; retain its handle. A lost spawn reply is ambiguous: do not
automatically retry and accidentally launch a duplicate.

## Execution modes and bounds

- Supply exactly one of direct `argv` or shell `cmd` (`--shell`). `--` ends CLI
  option parsing, so workload flags such as `--pretty` and `--timeout` stay literal.
  Direct mode preserves empty arguments and does not interpret `$`, `*`, pipes,
  redirects, quotes, or shell builtins. Use a real executable (not a Windows batch
  file) or select shell mode deliberately.
- Shell mode runs one noninteractive command and exits with its shell's status;
  it does not type text into a prompt or require lifecycle shell integration.
  POSIX Bash/sh/Zsh/Fish and native Windows PowerShell/cmd are supported. Existing
  native configured shell arguments and explicit WSL inner argv still apply;
  other agent domains use the host's login shell. Shell profiles/flags may affect behavior.
  `--user-shell` deliberately switches this to interactive startup.
- Optional `--domain NAME` selects the pane host. Default workspace/domain/cwd
  follow existing new-tab inheritance from the active pane. Specify domain/cwd
  explicitly when controller identity differs from current UI focus.
- Agent-backed WSL/SSH/container domains support both modes, dedicated or muxed.
  Legacy remote launchers without an agent reject background execution rather
  than silently executing locally. Background agent launches disable implicit
  native fallback. Shell-mode jobs require advertised one-shot support and fail
  before submission on older agents; update deployed agents along with Hollow.
  `--user-shell` additionally requires advertised user-shell support.
- Up to **64** retained owned panes; clean up old jobs to release capacity. Direct
  argv is limited to 256 entries and 128 KiB total argument bytes; embedded NULs
  are rejected. OS command-line limits may be lower. Output capture uses up to
  64 MiB across 64 jobs, plus normal bounded pane/terminal resources.

Tokens prevent accidental cleanup of user panes or a reused pane ID; they do not
authenticate the command socket or provide isolation from other local users.
Handles last only for that pane's lifetime in one running Hollow instance.

Raw API methods are `job_spawn`, `job_get`, `job_output`, and `job_cleanup`.
Use `api describe` for running-version contracts. `job_spawn` accepts exactly one
of `argv: ["npm","test"]` or `cmd: "npm test"`, plus optional `cwd` and `domain`.
Other methods take `{id: PANE_ID, token: TOKEN}`. Existing `run`, tab creation, and
pane split commands retain their focus/queue semantics.

Validation covers headless Linux mux/native PTYs, dedicated and multiplexed local
agent processes, and fake-host CLI scenarios. Windows is cross-build checked,
not native runtime qualified by these tests.
