# jk

A personal command-line toolkit for Windows PowerShell 5.1. It covers:
- **School:** classes and timetable, deadlines, grades, a weekly review, and the co-op job search.
- **Time:** reminders and a focus timer.
- **Code:** a competitive-programming runner.
- **Machine:** Downloads and disk cleanup reports, fuzzy folder jumping, machine/port/repo status, and a
  shell-startup fixer.

It needs nothing beyond what ships with Windows.

```powershell
jk            # dashboard: next class, next exam, this week's deadlines, to-dos, job applications
              # blocked on you, focus time, machine health
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

Your data (deadlines, classes, grades and the rest) lives in `~\.jk` and is not in the repo. Copy that
folder over to bring it along.

Install does three things:

- **Module link.** It links the module into `Documents\WindowsPowerShell\Modules\jk`, so `jk`
  autoloads in every new shell.
- **Profile hook.** It adds a one-line summary to your profile. Your profile as it was before is
  kept as `<profile>.jk-hook-backup`.
- **Morning task.** It registers `jk-remind`, which runs at 7:45 am (`jk config set remind.time 8am`),
  as soon as the PC wakes if it was asleep, and again at sign-in. Each run:
  - shows the morning popup: today's remaining classes, anything due within 48 hours, and today's
    study plan;
  - syncs your LEARN feed, once it is connected;
  - sets a popup 2 hours before each deadline or appointment later that day (`alert.before`).
    Interviews and OAs count too; work marked 0% and quiz-window openings don't, and an item you
    mark done first stays quiet;
  - sets a popup 10 minutes before each class, with the room (`alert.class`). Only one class timer
    waits at a time; each sets the next as it fires.

`jk config set alert.before 90m` or `alert.class 5m` change the lead times, and `off` turns either
off. `jk setup uninstall` removes the hook, the task and the link; your data stays in `~\.jk`.

### First-time setup

```powershell
jk class pick      # lists every section of your courses, then asks which ones you are in
jk due sync        # after copying LEARN > Calendar > Subscribe: takes the link from the clipboard
```

## Commands

| Area | Command | What it does |
|---|---|---|
| School | `jk class` / `jk class week` | Today's classes ("now, ends 9:50", "in 25m"), next class, weekly timetable; `jk class pick` asks for your sections (or `jk class pick cs341 003`); `jk class import` reads Quest's List View |
| | `jk due` | Deadlines in the next 14 days with countdowns. `jk week` grid, `jk exams`, `jk due cs350` |
| | `jk exam cs370` | One exam on a screen: when and where, worth, what you need on it, the prep `jk plan` expects and has scheduled, what lands the week before, and its review files (`jk find -o 1` opens one) |
| | `jk due add cs350 "A4" dec 2 8pm -Weight 10` | Natural dates: `fri`, `tomorrow`, `+3`, `oct 28`, `12/2` |
| | `jk due sync` | Pulls deadlines from LEARN's calendar feed (or any `.ics` link or file). The first time, it offers the link on your clipboard or asks you to paste it. Re-syncs update moved dates and keep your own edits, and the morning task syncs daily |
| | `jk due done a2a` | Complete by id or by part of the title (Tab completes ids, with titles) |
| | `jk due files cs341 a2` | The files in that course's folder named after the deadline (`A2.tex`, `A2\...`, `a2a.pdf`), or its newest files; `jk find -o 1` opens one |
| | `jk due cal` / `jk due ics` | Generated calendar web page / `.ics` for Google Calendar or Outlook |
| | `jk plan` / `jk plan start` | Splits today's study time across upcoming exams and assignments by weight and days left; starts the next 25-minute block |
| | `jk grade cs350` | Running weighted average and "to finish with 80% you need 77% on the rest" |
| | `jk grade fill` | Goes through every past graded item with no mark: type it (`17/20`, `85`), Enter skips. Each marked item is checked off as of its due date |
| | `jk grade import cs341` | Copy the course's Grades page in LEARN (Ctrl+A, Ctrl+C): each row is matched to its deadline by title, shown with what did not match, and recorded on a yes. Nothing copied yet? It opens LEARN and waits |
| | `jk todo "email the TA" -Due fri` | Lightweight to-do list |
| | `jk review` | Last 7 days (done, slipped, focus per course) and next 7 (load, where the marks are) |
| | `jk jobs` / `jk jobs stripe` | Job applications from your tracker table: applied, waiting on you (sign-ins, MFA, take-homes), ruled out, weekly pace; search answers "did I already apply?" (read-only) |
| Time | `jk focus 50 cs350` | Focus block; a popup slides in when it ends. `jk focus log` for the week |
| | `jk in 20m "laundry"` / `jk at 5pm "leave"` | One-off reminders (re-armed after a restart) |
| Code | `jk cp new A` / `jk cp add` / `jk cp` | Scaffold, paste samples from the clipboard, compile + test with diffs |
| | `jk cp new <problem link>` | AtCoder, USACO and CSES links: the folder named after the problem with every sample downloaded (old USACO file-I/O problems get the USACO template under their file name). Codeforces blocks scripts: folder only, paste with `jk cp add` |
| | `jk cp listen` | Any judge, Codeforces included: run it, then press the [Competitive Companion](https://github.com/jmerle/competitive-companion) extension's green + on a problem or contest page; each problem arrives as a folder with its samples (port 10043, `jk config set cp.port`) |
| | `jk cp stress` | `main` vs `brute` on `gen <seed>` inputs; a counterexample becomes a sample |
| | `jk repos` / `jk repos -Fetch` | Every git repo under the Desktop: uncommitted, unpushed, behind (git runs for 8 repos at a time; a hung fetch is stopped after a minute) |
| | `jk port 8080 -Kill` | Who holds a port, and free it |
| | `jk shots` | The Screenshots folder: count per month, the newest numbered (`jk find -o 1` opens the latest); `jk shots file` sorts older ones into month folders (`jk tidy undo` reverses it), `jk shots old -Recycle` bins those over a year old |
| | `jk net` | Is it the Wi-Fi or the internet? Address, router, internet, DNS and web checked in order, then one line on what is wrong (weak signal, no address, DNS, a sign-in page) |
| Machine | `jk find co250 a3` / `jk find -o 1` | Any file on the Desktop, in Documents or Downloads whose name or folders hold every word, best first (a word like `pdf` picks the type). Walked live in about 0.2 s, so new files show up at once; `-o`, `-e`, `-c`, `-p` open, reveal in Explorer, edit or print a result |
| | `jk clip` / `jk clip unwrap` | Word count of the clipboard (Chinese counted by character); `unwrap` fixes text copied from a PDF (wrapped lines rejoined, "optimi-zation" mended, bullets kept); `plain` drops formatting |
| | `jk recent` / `jk recent 7` | The files you changed in the last 2 (or N) days, newest first, with the busiest folders on top; the numbers work with `jk find -o` |
| | `jk tidy` / `jk tidy apply` / `jk tidy undo` | Sort Downloads (dry run first, fully undoable). Files named after a course with a folder (`CS245-F25-A05.pdf`, `STAT_230_002_27.pdf`) go to that folder, e.g. `Desktop\Waterloo course\CS245`, unless a copy is already filed there; `jk config set tidy.courses off` turns that off. `jk tidy dupes` and `jk tidy old` report duplicates and stale installers; `-Recycle` sends them to the Recycle Bin, looking only at loose downloads and jk's category folders, never inside unzipped programs or repos |
| | `j co250`, `j co250/final`, `j jobs`, `j -` | Fuzzy jump (Chinese folder names work too); `jk mark` bookmarks the current folder |
| | `jk sys` | CPU, memory, disks, battery and its wear (today's full charge against the design capacity), Wi-Fi, apps using the most RAM |
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
  once, items that merely share a title (a weekly "Quiz") stay separate, and a note such as
  "best 6 of 8" turns into a drop-lowest rule automatically.
- **Wide characters.** Chinese, Japanese and Korean text (and fullwidth punctuation) counts as two
  columns, so tables stay aligned around folder names in those scripts.
- **Narrow windows** (a split pane, a VS Code terminal). A line that would wrap is cut at the window
  edge with `…`, and `jk help` rewraps its descriptions instead, so tables never break.
- **Fast startup.** The profile hook prints a cached one-line brief without loading the module,
  and tab completion loads it on first use.
- **`jk speed fix`** replaces conda's hook, which runs `conda.exe` on every launch, with the same
  activation applied directly: the same PATH entries and `CONDA_*` variables. Conda's module then
  loads the first time you type `conda`.
  - It is dry-run in throwaway shells first and rolled back if `python`, the env or PATH would change.
  - The original is kept as `<profile>.jk-speed-backup` (or `.jk-backup` from older versions).
  - `jk speed undo` swaps back only the conda block; anything you added to the profile since stays.
- **Background timers** (reminders, alerts, focus blocks) are headless PowerShell processes that
  sleep before loading the module (about 60 MB each). A machine-wide lock keeps two firing at once
  from overwriting each other's changes.
- **The dashboard** announces new features once each, three per run (`$script:JkNews` in
  `lib\dash.ps1`).
- **Data** is plain JSON in `~\.jk`: `deadlines.json`, `classes.json`, `sections.json` (the section
  catalog), `grades.json`, `todo.json`, `focus.json`, `reminders.json`, `bookmarks.json`,
  `config.json` and `state.json`.
  - Errors from background timers go to `~\.jk\background.log` (trimmed to the newest 500 lines).
  - Before the first change each day, the previous version of every data file is copied to
    `~\.jk\backups\<date>\`. 30 days are kept, and `jk backup restore <date>` brings a day back.
  - Those backups are inside the data folder. `jk backup mirror <folder>` also keeps a daily
    snapshot somewhere else (another drive, a USB stick, a synced folder). Restore reads it when the
    local backups are gone.
  - `jk tidy apply` logs every move in `~\.jk\tidy\`, which is what `jk tidy undo` reads.
  - `jk cp` builds into a hidden `.jkcp` folder next to each solution, never into `.jk`.
  - `jk find` keeps the paths it last listed in `~\.jk\find.last`, so `jk find -o 2` knows which
    file is number 2.
  - `~\.jk\cache\` keeps the dashboard's study line (for the hour) and jobs section (for the day),
    redone as soon as the deadlines, focus log, settings or tracker change. Safe to delete.
  - `~\.jk\battery.cache` holds the battery's design capacity from Windows' battery report, which
    takes a second to generate. It is re-read every 90 days, in case the battery is replaced.

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1      # one run, about 2 minutes
powershell -NoProfile -ExecutionPolicy Bypass -File tests\check.ps1    # before merging
```

The tests use a throwaway data folder and a pinned clock. `tests\check.ps1` runs them four ways at once (as
is, in UTC, in Pacific time, and with German regional formats: decimal comma, day-first dates) so nothing
quietly depends on the machine's time zone or locale, and alongside them `tests\smoke.ps1`: install, a new
shell that finds jk through its link and runs real commands, uninstall. `run.ps1 -TimeZone <id>` and
`-Culture <name>` change only the test process, never Windows' settings; `smoke.ps1` sets `JK_SANDBOX`, which
sends the module link, profile hook and data to a temp folder and skips Task Scheduler (`-Real`, CI only,
does the real install). The GitHub Actions workflow is disabled: there is no Actions budget for this private
repo. Source files must stay pure ASCII,
because Windows PowerShell 5.1 reads BOM-less files as ANSI; the suite enforces this. Build
non-ASCII glyphs from code points (see `$script:G` in `lib\core.ps1`). The suite also lints for
two PowerShell traps: `'a', 'b' + $c` (comma binds tighter than `+`) and helper calls that get
stray arguments.

`tools\ansi2html.ps1 -Commands 'jk|jk due' -Out preview.html` renders real colored output as
a web page, which is handy for reviewing the look without a terminal.
