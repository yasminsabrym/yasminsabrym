# Laptop Optimizer

A safe, menu-driven Windows app (pure PowerShell — nothing to install) that:

1. **Moves data from C: to D:** — only things that are proven safe to move, so your laptop keeps working exactly as before.
2. **Optimizes storage** — cleans only regenerable cache/temp data and sets up automatic ongoing cleanup.
3. **Verifies & hardens your admin rights** — confirms you have full admin, and applies the protections that make those rights hard to override.
4. **Optimizes CPU, RAM, and GPU** — with a thermal-first approach: maximum sustainable performance *without* the fan sounding like a helicopter.

Every action is **previewed with sizes, confirmed with Y/N, and recorded in an undo journal**. System-critical paths are hard-blacklisted and can never be moved or deleted.

---

## How to run

1. Copy the `laptop-optimizer` folder to your laptop (e.g. `C:\Tools\laptop-optimizer`).
2. Right-click the Start button → **Terminal (Admin)** (or *Windows PowerShell (Admin)*).
3. Run:

```powershell
cd C:\Tools\laptop-optimizer
Set-ExecutionPolicy -Scope Process Bypass -Force
.\LaptopOptimizer.ps1
```

The tool asks for admin rights itself if you forget, and offers to create a **System Restore point** before each session.

> Works on Windows 10 and 11 out of the box (Windows PowerShell 5.1 — pre-installed on every machine).

---

## What it does, feature by feature

### 📦 Move from C: to D: (menu 3, 5–7, 12)

| What | How it stays safe |
|---|---|
| **Downloads, Documents, Pictures, Music, Videos, Desktop** | Files are moved with `robocopy`, then Windows' own *folder redirection* registry entries are updated — the same mechanism as the folder's "Location" tab. Every app finds the folder through Windows, so nothing breaks. |
| **App/dev caches** (npm, pip, NuGet, Gradle, Maven, Cargo, Android AVDs, Yarn, Composer, Spotify) | Data is moved to D: and a **junction** (folder shortcut at the filesystem level) is left at the old path. Programs literally cannot tell the difference. Only caches over 100 MB are offered. |
| **Page file** (`C:\pagefile.sys`) | Relocated to D: via the official Windows setting; frees several GB after one reboot. |
| **Future content** | Opens the exact Settings page to make Windows save *new* apps/docs/media to D: by default — so C: doesn't fill up again. |

**What it refuses to move, ever:** `C:\Windows`, `Program Files`, `ProgramData\Microsoft`, `AppData\...\Microsoft`, Store app packages (`AppData\Local\Packages`), recovery folders, drive roots. Moving installed programs or Windows itself is what breaks laptops — so it's blacklisted, not just discouraged.

### 🧹 Storage optimization (menu 2, 8–11)

- Storage report: drive fill levels + the biggest folders on C: and in your profile, so you can see where the space went.
- Safe cleanup: user/Windows temp, Windows Update leftovers, Delivery Optimization cache, thumbnail cache, crash dumps, shader cache — **only data Windows rebuilds automatically**. Personal files are never touched.
- DISM component-store deep clean (Microsoft-supported, typically frees 2–6 GB).
- Hibernation file shrink (keeps Fast Startup, halves a multi-GB file).
- Storage Sense enablement, so cleanup keeps happening automatically.

### 🔐 Admin rights: verify + make them hard to override (menu 4, 13)

The report shows: whether you're running with a full admin token, everyone in the Administrators group, UAC status/level, whether the hidden built-in Administrator or Guest accounts are enabled, and BitLocker status.

The hardening step then:
- ensures **UAC is on** (this is what stops software silently elevating past you),
- disables the built-in **Administrator** and **Guest** accounts (classic takeover paths),
- **flags any other admin accounts** so you can demote ones you don't recognize (it never auto-removes accounts — that's a lockout risk),
- reminds you about the two things only you can do: a strong password/PIN and **BitLocker/Device encryption** (without disk encryption, anyone with 10 minutes of physical access can reset your password from a USB stick — encryption is the real "cannot be overridden").

**Honest note:** Windows deliberately keeps `SYSTEM` and `TrustedInstaller` above admin accounts — that's what protects the OS (and *your* account) from tampering, including by malware running as admin. Any tool promising admin rights "above" that is weakening your machine, not strengthening it. This tool gives you the maximum rights Windows supports, protected the correct way.

### ⚡ Performance without helicopter fans (menu 1, 14–20)

The key insight: on most laptops, **Turbo Boost causes the majority of heat and fan noise for only a small burst-speed gain.**

| Mode | CPU cap | Boost | Cooling | When |
|---|---|---|---|---|
| **Quiet** | 80% | off | passive first | Browsing, office, meetings — near-silent |
| **Balanced** ⭐ | 99% | off | active | Daily driver: ~90–97% of full speed, drastically cooler and quieter |
| **Performance** | 100% | aggressive | active | Gaming/rendering — fans allowed |

Plus:
- Full system report: CPU load, RAM usage + top consumers, GPU + driver age check, disk health, and CPU temperatures (where the laptop exposes them).
- **Startup audit**: see everything that launches at boot and disable items one by one (reversibly) — the biggest real-world RAM/boot-time win.
- **GPU hardware-accelerated scheduling** toggle (lower latency, less CPU overhead).
- Visual effects performance mode that keeps fonts smooth and thumbnails on.
- HDD-aware service tuning: disables SysMain **only** if a spinning disk is detected; on SSDs it correctly leaves it on (disabling it on SSDs is an outdated tweak that hurts).

---

## Safety model

- ✅ **Preview → confirm → journal** for every single change.
- ✅ Undo journal at `%LOCALAPPDATA%\LaptopOptimizer\undo-journal.json` — every entry includes `HowToUndo`.
- ✅ Session log at `%LOCALAPPDATA%\LaptopOptimizer\optimizer.log`.
- ✅ System Restore point offered at session start.
- ✅ Free-space check before any move; failed moves leave redirection untouched (nothing half-broken).
- ❌ No registry "gaming tweaks", no service massacres, no disabling Defender/updates — those are how "optimizers" break laptops.

## Recommended extras (things a script can't or shouldn't automate)

- **Update the GPU driver** if the report flags it as over a year old (Intel/NVIDIA/AMD site or Windows Update).
- **Vendor power app** (Lenovo Vantage, Dell Power Manager, HP Command Center, MyASUS) — the only legitimate way to control the actual *fan curve*.
- **HWiNFO64** (free) if you want live temperature/fan monitoring beyond what Windows exposes.
- **Physically dust the vents** once or twice a year — the #1 cause of helicopter fans on laptops older than ~2 years.
- **Don't block the intake**: hard surfaces beat blankets/laps; a cheap stand drops temps noticeably.
- Keep **15–20% of C: free** — SSDs slow down dramatically when nearly full.

## Ideas for future versions

- Scheduled-task mode (weekly auto-cleanup with a summary report).
- Duplicate-file finder for the data drive.
- Battery health report (`powercfg /batteryreport` parsing).
- Per-app GPU preference management (force efficiency GPU for background apps).
- Bloatware detector for preinstalled OEM apps.
