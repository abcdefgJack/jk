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
| School | `jk class` / `jk class week` | Today's classes ("now, ends 9:50", "in 25m"), next class, weekly timetable; `jk class pick` asks for your sections (or `jk class pick cs341 003`); `jk class import` reads Quest's List View (nothing copied yet: it opens Quest and waits for the copy) |
| | `jk cs341` / `jk co 367` | One course on a screen: its exam (how far off, worth), its next deadlines, marks so far and what the rest needs, its classes, the study `jk plan` has for it today, and the newest files in its folder (`jk find -o 1` opens one). A word after it goes to that command for the course: `jk cs341 exam`, `grade`, `grep <words>`, `due`, `files <deadline>`, `go` |
| | `jk due` | Deadlines in the next 14 days with countdowns. `jk week` grid, `jk exams`, `jk due cs350` |
| | `jk exam cs370` | One exam on a screen: when and where, worth, what you need on it, the prep `jk plan` expects and has scheduled, what lands the week before, and its review files (`jk find -o 1` opens one) |
| | `jk grep cs370 condition number` | Words inside your course files, page by page: lecture PDFs, slides (`.pptx`), Word files, notebooks (by cell), notes and code across this term's course folders (`jk grep all ...` for every term), each hit with its page and the words picked out; `jk find -o 1` opens a PDF at that page. PDF text is read once (pdftotext from MiKTeX or Git, else pypdf) and kept by file size and time, so later searches take a fraction of a second; handwritten PDFs are counted, not searched |
| | `jk due add cs350 "A4" dec 2 8pm -Weight 10` | Natural dates: `fri`, `next week`, `tomorrow`, `+3`, `oct 28`, `Mon Nov 9`, `12/2` |
| | `jk due sync` | Pulls deadlines from LEARN's calendar feed (or any `.ics` link or file). The first time, it offers a link already on your clipboard, or opens LEARN's calendar and reads the link once you copy it from Subscribe. Re-syncs update moved dates and keep your own edits, and the morning task syncs daily |
| | `jk due done a2a` | Complete by id or by part of the title (Tab completes ids, with titles) |
| | `jk due files cs341 a2` | The files in that course's folder named after the deadline (`A2.tex`, `A2\...`, `a2a.pdf`), or its newest files; `jk find -o 1` opens one |
| | `jk due cal` / `jk due ics` | Generated calendar web page / `.ics` for Google Calendar or Outlook |
| | `jk plan` / `jk plan week` / `jk plan start` | Splits today's study time across upcoming exams and assignments by weight, days left and your marks (a course behind its target gets more, its exams from 5 weeks out); the week as a day-by-day checklist; starts the next 25-minute block. `jk config set plan.skip <course>` leaves a course out |
| | `jk grade cs350` | Running weighted average and "to finish with 80% you need 77% on the rest" |
| | `jk grade cs370 if midterm 70` | What if: the average with that mark (several: `if midterm 70, a2 85`) and what the rest would then need; nothing is saved |
| | `jk grade fill` | Goes through every past graded item with no mark: type it (`17/20`, `85`), Enter skips. Each marked item is checked off as of its due date |
| | `jk grade import cs341` | Copy the course's Grades page in LEARN (Ctrl+A, Ctrl+C): each row is matched to its deadline by title, shown with what did not match, and recorded on a yes. Nothing copied yet? It opens LEARN and waits |
| | `jk todo "email the TA" -Due fri` | Lightweight to-do list |
| | `jk pdf *.jpg` / `jk pdf p1.jpg a3.pdf -Out hw3.pdf` | Photos of handwritten work into one PDF for a LEARN dropbox or Crowdmark: each turned upright by the phone's rotation tag, a page each (landscape pages for landscape photos), Letter or `-A4`, in natural order (IMG_2 before IMG_10); PDFs in the list are merged in (pypdf or pdfunite); `-Small` shrinks photos for upload limits; never overwrites |
| | `jk review` | Last 7 days (done, slipped, focus per course) and next 7 (load, where the marks are) |
| | `jk jobs` / `jk jobs stripe` | Job applications from your tracker table: applied, waiting on you (sign-ins, MFA, take-homes), ruled out, weekly pace; search answers "did I already apply?" (read-only) |
| Time | `jk focus 50 cs350` | Focus block; a popup slides in when it ends. `jk focus log` for the week |
| | `jk next` | The one thing to do now and the two after it: an exam within 6 hours (leave in time, the room), a class within 45 minutes, work due within 12 hours, to-dos due today, then the study `jk plan` has for today, each with the command that does it |
| | `jk in 20m "laundry"` / `jk at 5pm "leave"` | One-off reminders (re-armed after a restart) |
| | `jk time` / `jk time 8pm beijing` | The time where your people are: ahead or behind, awake or asleep, when you are both up for a call, and a warning when the gap is about to change (Waterloo falls back on Nov 1: Beijing goes from 12 to 13 hours ahead). `jk time 8pm beijing` is that time in yours, `jk time 9am` yours in theirs. The places start from your installed languages (Chinese (PRC) gives Beijing); `jk time add london`, `jk time rm london` |
| | `jk weather` / `jk weather toronto` | The forecast read for you: now, the next hours, today and four more days as "rain 2–6 pm (80%) → umbrella", snow totals, icy sidewalks, a wind chill, and the weather at your next in-person exams. The dashboard shows a line of it and the morning popup a summary; `jk weather set <place>` (default Waterloo), `jk weather off`. From [Open-Meteo](https://open-meteo.com) (free, no account; only the place's coordinates are sent), converted to local time on your machine so the hours stay right across a clock change |
| Code | `jk cp new A` / `jk cp add` / `jk cp` | Scaffold, paste samples from the clipboard, compile + test with diffs |
| | `jk cp new <problem link>` | AtCoder, USACO and CSES links: the folder named after the problem with every sample downloaded (old USACO file-I/O problems get the USACO template under their file name). Codeforces blocks scripts: folder only, paste with `jk cp add` |
| | `jk cp listen` | Any judge, Codeforces included: run it, then press the [Competitive Companion](https://github.com/jmerle/competitive-companion) extension's green + on a problem or contest page; each problem arrives as a folder with its samples and a `problem.txt` holding its link and the judge's time and memory limits, which `jk cp` then holds every run against (`close to the 2 s limit`, `over 256 MB`) (port 10043, `jk config set cp.port`) |
| | `jk cp stress` | `main` vs `brute` on `gen <seed>` inputs; a counterexample becomes a sample |
| | `jk repos` / `jk repos -Fetch` | Every git repo under the Desktop: uncommitted, unpushed, behind (git runs for 8 repos at a time; a hung fetch is stopped after a minute) |
| | `jk port 8080 -Kill` | Who holds a port, and free it; a database other devices on the network can reach is flagged with the setting that keeps it local |
| Machine | `jk shots` | The Screenshots folder: count per month, the newest numbered (`jk find -o 1` opens the latest); `jk shots file` sorts older ones into month folders (`jk tidy undo` reverses it), `jk shots old -Recycle` bins those over a year old; `jk shots find backward euler` finds screenshots by the words in them (read by Windows' own OCR, about 30 ms each, the rest in the background; kept on this PC, `jk shots forget` deletes it) |
| | `jk net` | Is it the Wi-Fi or the internet? Address, router, internet, DNS and web checked in order, then one line on what is wrong (weak signal, no address, DNS, a sign-in page); `jk net speed` measures latency, download and upload against Cloudflare (up to ~15 s) and says what that is good for |
| | `jk find co250 a3` / `jk find -o 1` | Any file on the Desktop, in Documents or Downloads whose name or folders hold every word, best first (a word like `pdf` picks the type). Walked live in about 0.2 s, so new files show up at once; `-o`, `-e`, `-c`, `-p` open, reveal in Explorer, edit or print a result |
| | `jk clip` / `jk clip unwrap` / `jk clip ocr` | Word count of the clipboard (Chinese counted by character); `ocr` reads the text in a snip (Win+Shift+S) or copied image files with Windows' own OCR and puts it on the clipboard, lines kept; `unwrap` fixes text copied from a PDF (wrapped lines rejoined, "optimi-zation" mended, bullets kept); `plain` drops formatting |
| | `jk recent` / `jk recent 7` | The files you changed in the last 2 (or N) days, newest first, with the busiest folders on top; the numbers work with `jk find -o` |
| | `jk tidy` / `jk tidy apply` / `jk tidy undo` | Sort Downloads (dry run first, fully undoable). Files named after a course with a folder (`CS245-F25-A05.pdf`, `STAT_230_002_27.pdf`) go to that folder, e.g. `Desktop\Waterloo course\CS245`, unless a copy is already filed there; `jk config set tidy.courses off` turns that off. `jk tidy dupes` and `jk tidy old` report duplicates and stale installers; `-Recycle` sends them to the Recycle Bin, looking only at loose downloads and jk's category folders, never inside unzipped programs or repos |
| | `j co250` (`jk go co250`), `j co250/final`, `j jobs`, `j -` | Fuzzy jump (Chinese folder names work too); `jk mark` bookmarks the current folder |
| | `jk sys` | CPU, memory, disks, battery and its wear (today's full charge against the design capacity), Wi-Fi, apps using the most RAM |
| | `jk space` / `jk space clean conda` | What fills the disk (caches, temp, Docker, `node_modules`, Android emulator disks such as MuMu, WeChat files, Ollama models, `~\.cache`, Windows Update downloads), with the right cleanup for each, and what grew since an earlier run ("+6.2 GB since Sat"). Free space is read once a day: the dashboard turns orange when 4 GB or more went in three days |
| | `jk speed` / `jk speed fix` | Times shell startup per profile file; makes the `conda init` hook instant (about 2.4 s to 0.3 s) |
| jk | `jk doctor` | Checks the module link, profile hook, morning task, LEARN feed, backups, background errors, databases open to the network and the compilers |
| | `jk remind` / `jk remind install` | Pending reminders (cancel by id) and the morning task's state; `install` sets up or repairs the task |
| | `jk config` / `jk backup` | Every setting, with what an empty default comes to here / the daily snapshots of your data, `jk backup restore <day>` |
| | `jk update` / `jk brief` | Pulls the latest jk from GitHub and reloads it / the one-line summary shown when PowerShell starts |

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
