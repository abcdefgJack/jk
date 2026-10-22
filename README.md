# jk

A personal command-line toolkit for Windows PowerShell 5.1. It covers:
- **School:** classes and timetable, deadlines, grades, a weekly review.
- **Time:** reminders and a focus timer.
- **Code:** a competitive-programming runner.
- **Machine:** Downloads and disk cleanup reports, fuzzy folder jumping, machine/port/repo status, and a
  shell-startup fixer.

It needs nothing beyond what ships with Windows.

```powershell
jk            # dashboard: next class, next exam, this week's deadlines, to-dos, focus time, machine health
jk help       # every command;  jk help <command> for examples
```

## Install

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Desktop\jk\install.ps1"
```

On another PC, clone it first:

```powershell
gh repo clone abcdefgJack/jk "$HOME\Desktop\jk"
powershell -ExecutionPolicy Bypass -File "$HOME\Desktop\jk\install.ps1"
```

Install links the module into `Documents\WindowsPowerShell\Modules\jk`, so `jk` autoloads in
every new shell. It also adds a one-line summary to your profile and registers a morning
brief popup: today's remaining classes plus anything due within 48 hours. It runs at 7:45 am
(`jk config set remind.time 8am` changes that), or as soon as the PC wakes if it was asleep,
and again at sign-in. To undo the profile line, task and link, run `jk setup uninstall`; your
data stays in `~\.jk`.

## Commands

| Area | Command | What it does |
|---|---|---|
| School | `jk class` / `jk class week` | Today's classes ("now, ends 9:50", "in 25m"), next class, weekly timetable; `jk class pick cs341 003` adds a section from the catalog; `jk class import` reads Quest's List View |
| | `jk due` | Deadlines in the next 14 days with countdowns. `jk week` grid, `jk exams`, `jk due cs350` |
| | `jk due add cs350 "A4" dec 2 8pm -Weight 10` | Natural dates: `fri`, `tomorrow`, `+3`, `oct 28`, `12/2` |
| | `jk due done a2a` | Complete by id or by part of the title (Tab completes ids, with titles) |
| | `jk due cal` / `jk due ics` | Generated calendar web page / `.ics` for Google Calendar or Outlook |
| | `jk plan` / `jk plan start` | Splits today's study time across upcoming exams and assignments by weight and days left; starts the next 25-minute block |
| | `jk grade cs350` | Running weighted average and "to finish with 80% you need 77% on the rest" |
| | `jk todo "email the TA" -Due fri` | Lightweight to-do list |
| | `jk review` | Last 7 days (done, slipped, focus per course) and next 7 (load, where the marks are) |
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

- **Colors** assume a dark terminal, which is the default in Windows Terminal and VS Code. Run
  `jk config set theme light` for light backgrounds, and `NO_COLOR=1` or `JK_COLOR=never` for plain text.
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
- **Data** is plain JSON in `~\.jk`: `deadlines.json`, `classes.json`, `grades.json`, `todo.json`,
  `focus.json`, `reminders.json`, `bookmarks.json`, `config.json`. Errors from background
  timers go to `~\.jk\background.log`. Before the first change each day, the previous version of every data file is copied to `~\.jk\backups\<date>\`; 30 days are kept, and `jk backup restore <date>` brings a day back.

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

The tests use a throwaway data folder and a pinned clock. Source files must stay pure ASCII,
because Windows PowerShell 5.1 reads BOM-less files as ANSI; the suite enforces this. Build
non-ASCII glyphs from code points (see `$script:G` in `lib\core.ps1`). The suite also lints for
two PowerShell traps: `'a', 'b' + $c` (comma binds tighter than `+`) and helper calls that get
stray arguments.

`tools\ansi2html.ps1 -Commands 'jk|jk due' -Out preview.html` renders real colored output as
a web page, which is handy for reviewing the look without a terminal.
