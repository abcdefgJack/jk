# jk

A personal command-line toolkit for Windows PowerShell 5.1: deadlines, grades, reminders,
a focus timer, a Downloads cleaner, a competitive-programming runner, fuzzy folder
jumping, and machine/port/repo status. No dependencies beyond what ships with Windows.

```powershell
jk            # dashboard: next exam, this week's deadlines, to-dos, focus time, machine health
jk help       # every command;  jk help <command> for examples
```

## Install

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Desktop\jk\install.ps1"
```

This links the module into `Documents\WindowsPowerShell\Modules\jk`, so `jk` autoloads in
every new shell. It also adds a one-line summary to your profile and registers a daily
deadline check (8:30 am and at sign-in). To undo the profile line, task and link, run
`jk setup uninstall`; your data stays in `~\.jk`.

## Commands

| Area | Command | What it does |
|---|---|---|
| School | `jk class` / `jk class week` | Today's classes ("now, ends 9:50", "in 25m"), next class, weekly timetable; `jk class import` reads Quest's List View |
| | `jk due` | Deadlines in the next 14 days with countdowns. `jk week` grid, `jk exams`, `jk due cs350` |
| | `jk due add cs350 "A4" dec 2 8pm -Weight 10` | Natural dates: `fri`, `tomorrow`, `+3`, `oct 28`, `12/2` |
| | `jk due done a2a` | Complete by id or by part of the title (Tab completes ids, with titles) |
| | `jk due cal` / `jk due ics` | Generated calendar web page / `.ics` for Google Calendar or Outlook |
| | `jk grade cs350` | Running weighted average and "to finish with 80% you need 77% on the rest" |
| | `jk todo "email the TA" -Due fri` | Lightweight to-do list |
| Time | `jk focus 50 cs350` | Focus block; a popup slides in when it ends. `jk focus log` for the week |
| | `jk in 20m "laundry"` / `jk at 5pm "leave"` | One-off reminders (re-armed after a restart) |
| Code | `jk cp new A` / `jk cp add` / `jk cp` | Scaffold, paste samples from the clipboard, compile + test with diffs |
| | `jk cp stress` | `main` vs `brute` on `gen <seed>` inputs; a counterexample becomes a sample |
| | `jk repos` | Every git repo under the Desktop: uncommitted, unpushed, behind |
| | `jk port 8080 -Kill` | Who holds a port, and free it |
| Machine | `jk tidy` / `jk tidy apply` / `jk tidy undo` | Sort Downloads (dry run first, fully undoable); `dupes`, `old` |
| | `j co250`, `j co250/final`, `j -` | Fuzzy jump; `jk mark` bookmarks the current folder |
| | `jk sys` | CPU, memory, disks, battery, Wi-Fi, apps using the most RAM |
| | `jk space` / `jk space clean conda` | What fills the disk (caches, temp, Docker, `node_modules`), with the right cleanup for each |
| | `jk speed` / `jk speed fix` | Times shell startup per profile file; makes the `conda init` hook instant (about 2.4 s to 0.3 s) |

## Notable details

- **Notifications.** If Windows notifications are off, `jk` draws its own popup: a WPF card in
  the bottom-right that never steals focus and pauses while hovered. Set it with
  `jk config set notify auto|popup|toast|off`.
- **cp runner.** It solves several Windows-specific problems:
  - Programs link with a 256 MB stack, so deep DFS doesn't crash.
  - Stdin is fed without the UTF-8 BOM that .NET adds on UTF-8 consoles, which would otherwise
    break `cin >> n`.
  - Crashes skip Windows Error Reporting, so they show as RTE immediately instead of looking
    like TLE.
  - Exit codes such as `0xC0000005` are explained, and peak memory is measured exactly.
  - Floats compare with a 1e-6 tolerance.
- **Grades** reuse the weights stored with your deadlines. A quiz window's opens/closes pair counts
  once, and a note such as "best 6 of 8" turns into a drop-lowest rule automatically.
- **Fast startup.** The profile hook prints a cached one-line brief without loading the module,
  and tab completion loads it on first use. `jk speed fix` replaces conda's hook, which runs
  `conda.exe` on every launch, with the same activation applied directly: the same PATH entries
  and `CONDA_*` variables. Conda's module then loads the first time you type `conda`. The fix is
  dry-run in throwaway shells first and rolled back if `python`, the env or PATH would change.
- **Data** is plain JSON in `~\.jk`: `deadlines.json`, `grades.json`, `todo.json`,
  `focus.json`, `reminders.json`, `bookmarks.json`, `config.json`. Errors from background
  timers go to `~\.jk\background.log`.

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

The tests use a throwaway data folder and a pinned clock. Source files must stay pure ASCII,
because Windows PowerShell 5.1 reads BOM-less files as ANSI; the suite enforces this. Build
non-ASCII glyphs from code points (see `$script:G` in `lib\core.ps1`).
