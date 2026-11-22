---
description: Flush what's accumulated on this machine, never touching MindAttic's own live workload. "/flush" or "/flush ram" sweeps RAM held by idle apps (quick; add "deep" for kernel pool, handle-leak, driver and startup forensics). "/flush drive", "/flush ssd", "/flush hdd" or "/flush hd" frees disk cruft - temp folders, crash dumps, Recycle Bin, Windows Update leftovers, logs, package and browser caches - and finds new kinds as they pile up. Measures first, asks before changing anything.
argument-hint: "[ram [deep] | drive | ssd | hdd | hd]"
allowed-tools: PowerShell, Bash
---

Flush what's accumulated on this machine (MAT-T165, formerly `/ghostram`). This PC runs
MindAttic.Orchestrator plus however many CLI tabs, TermHost processes, Launcher instances and Claude
Code subagents it's hosting right now. That stack is the wanted workload, never a target: every
flush starts by setting it aside. Don't assume the answer - measure, rule things in or out with
numbers, and show what you found after each step. Use PowerShell.

The scripts live in `D:\Projects\MindAttic\mindattic-agent-standard\shared\flush\` (source:
`MindAttic.Agency\shared\flush\`). Their CSVs go to `%LOCALAPPDATA%\MindAttic\Flush\`.

## 1. Parse the target

`$ARGUMENTS`, first word, case-insensitive:

- empty or `ram` → **RAM flush**, section 2. A second word `deep` or `full` adds section 3.
- `drive`, `ssd`, `hdd` or `hd` → **disk flush**, section 4 (all four mean the same thing: every fixed drive).
- `deep` or `full` alone → RAM flush with section 3.
- anything else → say which targets exist (`ram`, `drive`/`ssd`/`hdd`/`hd`) and stop. More targets will be
  added here as new sections; don't guess at one that isn't listed.

Rules for every target:
- Don't kill, close, uninstall, stop, disable or delete anything without asking first. List what
  you'd change, why, and the numbers behind it, then wait for a yes.
- When a step needs admin, give one complete copy-paste block for an Administrator PowerShell
  window, starting with the `cd`, and say exactly what output to expect and what to send back.

## 2. RAM flush

Run `& "D:\Projects\MindAttic\mindattic-agent-standard\shared\flush\flush-ram.ps1"` (read-only). It
reports, in order:

- **Totals**: installed vs usable RAM (the gap is hardware-reserved, not reclaimable), in use/free,
  commit charge vs limit, uptime, then paged/nonpaged pool, cache, standby and modified. Standby is
  harmless and freed on demand; never present it as reclaimable.
- **MindAttic workload**, collapsed into one line. It uses the same protected roots as the
  Orchestrator's own memory guard (`ProcessTree.IsProtectedRootName`/`IsProtected` in
  `MindAttic.Orchestrator.Core\Sessions\ProcessTree.cs`): `claude.exe` (or `claude.exe.old.N`),
  `MindAttic.Launcher.exe`, `MindAttic.Orchestrator.TermHost.exe` and
  `MindAttic.Orchestrator.Desktop.exe`, plus everything descended from one of them (up to 16
  parent steps). If that list ever changes in `ProcessTree.cs`, change the script to match; never
  keep a separate list. Other MindAttic apps (`idiotproof-hub`, `tickets`, `psst`, ...) are ordinary
  candidates.
- **Everything else**, grouped by exe name with process counts, private and working-set GB and the
  oldest start time, then whether each group has a visible window.
- **Reconciliation**: commit = MindAttic + others + unexplained. A large unexplained share is kernel,
  driver or file-backed memory; that's what `deep` is for.
- **Since the last run**: every process group that's new or grew by 0.2 GB+ since the previous
  `ram-*.csv`. Nothing is hardcoded about which apps pile up, so whatever starts accumulating
  next shows up here first; lead the verdict with it.

Before you call something idle, sample it: CPU over ~10 seconds, its parent and its command line. A
process that a CLI started (a game capture, ffmpeg, a build) is live work even if its name looks
foreign.

Then give a verdict table: group, GB, idle or not (with the evidence), and the option: trim its
working set (reversible, nothing closes: `EmptyWorkingSet` through a small Add-Type P/Invoke) or
close it. Offer the trim first. Wait for a yes before closing anything.

Orchestrator already runs an automatic version of this (`MemoryReclaim.Run`, past
`MemoryGuardStartPercent`, 98% by default): it trims its own tree, then every other unprotected
process, and only as a last resort closes an idle headless CLI of its own or one app from a vetted
allow-list. `/flush ram` is the manual, ask-first sweep and doesn't replace it. If you find little
to reclaim, the guard may already have run.

## 3. RAM deep sweep (`/flush ram deep`, `/flush deep`)

Slow (pool sampling needs 90+ seconds between samples), so only when asked. After section 2:

a) VMs (`vmmem`/`vmmemWSL`/Docker/Hyper-V/Android emulators reserve whole GBs up front) and Windows
   itself (Search indexer, Memory Compression, SysMain, Defender, svchost groups mapped to services
   with `tasklist /svc`): a verdict on each, with numbers.
b) Kernel/driver leaks: paged pool over ~2 GB or nonpaged over ~1 GB means a driver is leaking
   (weigh it against uptime). Break the pools down by tag with `NtQuerySystemInformation` class 22
   (`SystemPoolTagInformation`) through an `Add-Type` C# helper (x64 entries are 40 bytes: `Tag`@0,
   `PagedAllocs`@4, `PagedFrees`@8, `PagedUsed` SIZE_T@16, `NonPagedAllocs`@24, `NonPagedFrees`@28,
   `NonPagedUsed`@32). Show the top tags by MB and live object count, look them up, then sample
   again 90+ seconds later to see which tags are growing.
c) Handle leaks: handles per process and per object type with `NtQuerySystemInformation` class 64
   (`SystemExtendedHandleInformation`: 40-byte entries, `PID`@8, `ObjectTypeIndex` USHORT@30) and
   type names from `NtQueryObject` class 3 (`TypeIndex` UCHAR@0x5A, `TotalNumberOfObjects`@0x10,
   `TotalNumberOfHandles`@0x14). Millions of objects with few handles means a driver holding
   references; a huge count on PID 4 means a driver leak; a huge count on an app means that app leaks.
d) Who could own a kernel leak: file-system minifilters (services with an `Instances` key, sorted by
   Altitude), running non-Microsoft kernel drivers (`Win32_SystemDriver` plus file version info for
   the company), and `root/SecurityCenter2 AntivirusProduct`. Antivirus, driver updaters, fan/RGB
   tools, anti-cheat and VPN drivers are common leakers; prove it with the numbers.
e) Slow app leaks: sample private bytes twice, several minutes apart, and flag anything that only grows.
f) Startup bloat: `Win32_StartupCommand` (Run keys, Startup folders), non-Microsoft scheduled tasks
   with logon/boot triggers, non-Microsoft Automatic services. Group them and ask which groups to
   turn off. Disable approved entries the way Task Manager does: under
   `...\CurrentVersion\Explorer\StartupApproved\Run` (or `\StartupFolder`) set the value to binary
   `03 00 00 00 00 00 00 00 00 00 00 00` (HKCU per-user, HKLM machine-wide with admin);
   `Disable-ScheduledTask` for tasks; services to Manual only after approval of each one. Report
   every change and how to undo it.

End with the top-consumers table and the re-run command, so a run after a reboot shows what grows
back first. If a driver keeps leaking across reboots, name the software that owns it and how to
remove it.

## 4. Disk flush (`/flush drive`, `/flush ssd`, `/flush hdd`, `/flush hd`)

Every kind of disk cruft is an entry in `shared\flush\cruft-sources.json`, grouped:

| Group | Default | What |
|---|---|---|
| `temp` | yes | `%TEMP%`, `%TMP%`, `%LOCALAPPDATA%\Temp`, `%WINDIR%\Temp`, `Temp`/`Tmp` at every fixed drive root |
| `dumps` | yes | crash dumps (any app's `CrashDumps` folder), Windows Error Reporting, kernel dumps (admin) |
| `recyclebin` | yes | the Recycle Bin on every drive |
| `updates` | yes | Windows Update downloads, Delivery Optimization cache (admin) |
| `logs` | opt-in | Windows CBS/DISM logs (admin) |
| `shaders` | opt-in | NVIDIA/AMD/D3D shader caches (games recompile them on next launch) |
| `caches` | opt-in | npm, pip, Yarn, NuGet HTTP caches (rebuildable, but the next build re-downloads) |
| `browsers` | opt-in | Chrome/Edge/Brave caches (sign-ins and history untouched) |
| `apps` | opt-in | Electron app caches (Discord, Slack, Teams, VS Code) |

A new kind of cruft is a new entry in that file (group, name, paths with `%VARS%` and `*`,
`minAgeHours`, `admin`, `default`); never hardcode one in the script.

Kept, always: Claude Code session folders (`claude\`, owned by Orchestrator's `SessionTempPruner`),
MindAttic app extraction folders (`.net\MindAttic.*`), anything named MindAttic, Orchestrator or
TermHost; and inside temp roots also ticket work folders (`SG-T143`, `M.ORCH-T1876`...) and
anything an environment variable points into (e.g. `NUGET_PACKAGES` in `R:\Temp\nuget\packages`).
Only files older than a source's `minAgeHours` (24 by default) count, so work in progress anywhere
keeps its files.

1. Measure: `& "D:\Projects\MindAttic\mindattic-agent-standard\shared\flush\flush-disk.ps1"`. It
   changes nothing, and prints:
   - the per-source table (Reclaim, Recent, Kept GB, and which sources need admin to measure);
   - totals by group, for the default groups and for everything;
   - **unlisted cruft**: Cache/Logs/Dumps/CrashDumps-style folders over 250 MB under AppData and
     ProgramData that no source covers yet. This is how cruft that starts piling up later gets
     caught. For each, say what owns it and whether it's safe to flush, and offer to add it to
     `cruft-sources.json` (in `MindAttic.Agency`, then `render-abilities.ps1` +
     `sync-workspace-copy.ps1`) so every later flush includes it.
2. Show the biggest reclaimable entries in the large sources (list the top-level items by size).
   Name anything that looks deliberate rather than disposable (an installer you may still want, a
   folder named for a project) and ask about it.
3. Ask which groups to flush: the default groups, plus any opt-in ones, with GB beside each. This
   deletes and can't be undone, so the yes is required.
4. Apply: `flush-disk.ps1 -Apply -Groups temp,dumps,...`. Locked files are skipped; emptied folders
   are removed. Admin-only sources are skipped in a normal window: give the Administrator block
   (`cd D:\Projects\MindAttic\mindattic-agent-standard\shared\flush` then
   `.\flush-disk.ps1 -Apply -Groups dumps,updates,logs -NoDiscover`) and say to send back the
   "Deleted ... GB freed" and free-space lines.
5. Report GB freed per drive and anything skipped.
