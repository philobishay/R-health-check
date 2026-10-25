# Raid health check

Watches a Windows mirrored drive (Disk Management's *Mirrored volume* on two dynamic disks; `R:` unless you say
otherwise) and tells you when anything is wrong, so you can copy what matters off the surviving disk.

## What it checks

1. `diskpart` *list volume*: `R:` must be *Healthy*. A broken mirror shows as *Failed Rd* (Disk Management: *Failed
   Redundancy*); *Rebuild* means it is copying onto a replaced disk.
2. `diskpart` *list disk*: every disk must be *Online*. A disk that stops responding shows as *Missing*.
3. Each disk's own health status (`Get-PhysicalDisk`): *Warning* or *Unhealthy* is reported.
4. The drives' failure prediction (SMART), where Windows can read it.

On a problem you get an email, a pop-up and a line in `C:\ProgramData\MirrorCheck\log.txt`. The check runs daily at
9:00 and when you sign in. An "all OK" email every four weeks shows that the check itself still runs.

## First-time setup

1. **Gmail app password** (skip if you want only pop-ups). Gmail rejects your normal password from scripts. With
   2-Step Verification on in your Google account, open https://myaccount.google.com/apppasswords, type a name such
   as *Mirror check*, and click **Create**. Google shows 16 letters; keep them on screen for step 3.
2. **Get this folder** (PowerShell; needs Git for Windows):
   ```powershell
   New-Item -ItemType Directory -Force "$HOME\Repos" | Out-Null
   cd "$HOME\Repos"
   git clone https://github.com/philobishay/Raid-health-check.git
   ```
   If an earlier copy of the folder is there, delete it first. It holds no settings; setup keeps them in
   `C:\ProgramData\MirrorCheck`.
3. **Run setup in an Administrator window.** Right-click Start → **Terminal (Admin)** (older Windows 10: **Windows
   PowerShell (Admin)**), click Yes, then paste these two lines:
   ```powershell
   cd "$HOME\Repos\Raid-health-check"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
   ```
   Setup shows what `diskpart` reports for `R:`, asks for the Gmail address and the app password, sends a test alert
   (click OK on the pop-up; the email's subject starts with *TEST ALERT*) and schedules the checks. For another
   drive letter, add `-Drive E` (for example) to the setup line.

There is no password file to find or edit. Setup creates `C:\ProgramData\MirrorCheck\mail.xml` from what you type,
encrypted so that only your Windows account can read it. `C:\ProgramData` is hidden in File Explorer; type the path
into the address bar to open it.

## Afterwards

- New address or app password: run setup again (step 3).
- New version: `git pull` in this folder, then run setup again; it installs the new `check-mirror.ps1`.
- The scheduled checks: Task Scheduler → Task Scheduler Library → *Check R mirror* and *Check R mirror (OK email)*.
- Remove everything: `powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Uninstall` (Administrator).

## Files

| File | What it is |
|---|---|
| `check-mirror.ps1` | The check. Setup copies it to `C:\ProgramData\MirrorCheck`, where the scheduled tasks run it. |
| `setup.ps1` | First-time setup, changes, `-Uninstall`. |
| `tests.ps1` | Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests.ps1` (should end with *all passed*). |

## Limits

- It reads English Windows (*Healthy*, *Online*, ...).
- It runs only while you are signed in to the desktop, because the app password is encrypted for your account.
- The tests use `diskpart` output written by hand, not recorded on this PC. Setup step 2 prints the real lines: if
  setup reports a problem while Disk Management shows the mirror *Healthy*, the check misreads this PC.
- It is not a backup. It tells you a disk failed; copies on other drives are what protect the files.
