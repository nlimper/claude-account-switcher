# Claude Account Switcher

Switch the **Claude desktop app** (Windows) between multiple **Anthropic Claude**
accounts you own (e.g. several Pro/Max accounts), with a Desktop shortcut and a
5-hour / 7-day usage readout per account.

The desktop app has no built-in account switcher; this adds one. **No npm or
other dependencies required.** Windows only.

---

## Quick start

In **PowerShell**:

```powershell
# 1. Install (run once)
irm https://raw.githubusercontent.com/nlimper/claude-account-switcher/main/install.ps1 | iex
# 2. Open a NEW PowerShell window, then save each account (see "Add your accounts")
claude-add-account
# 3. Switch any time
claude-switch-account
```

---

## Step 1 — Install

Open **PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/nlimper/claude-account-switcher/main/install.ps1 | iex
```

This installs:

- the scripts in `~/.claude-tools/`
- the PowerShell commands `claude-add-account`, `claude-switch-account` and
  `claude-switch-update`
- a **"Claude Switch Account"** shortcut on your Desktop

**Then open a new PowerShell window** so the commands load.

---

## Step 2 — Add your accounts

> ⚠️ **Do NOT use the Claude app's "Log out" while adding accounts.** Logging out
> revokes that account's session on Anthropic's servers, which kills the saved
> snapshot. `claude-add-account` clears the *local* login for you instead — so
> every saved account stays valid.

1. **Log into your first account** in the Claude desktop app.
2. Run:

   ```powershell
   claude-add-account
   ```

   - It detects which account is logged in and asks you to confirm it.
   - Claude briefly closes (to copy its profile) and reopens.
3. When it asks **"Add ANOTHER account now?"** → type **`y`**. Claude reopens at a
   **fresh sign-in screen** (your first account is *not* logged out).
4. **Sign in as your next account** and run `claude-add-account` again. Repeat
   for as many accounts as you like.
5. On the **last** account, answer **`n`** to "Add ANOTHER account?".

---

## Step 3 — Switch accounts

- **Double-click** the **"Claude Switch Account"** icon on your Desktop, **or**
- run **`claude-switch-account`** in a standalone PowerShell window.

You'll see a menu like:

```
=== Switch Claude account ===
  [1] * you@example.com           5h  12% / 7d   8% used
        5h resets in 4h15m (21:49)   |   7d resets Sun Jun 7, 02:29
  [2]   work@example.com          5h  47% / 7d  31% used
        5h resets in 1h02m (18:36)   |   7d resets Fri Jun 5, 09:00
  (* = current   |   lower % = more headroom)
  Live profile: C:\Users\you\AppData\Roaming\Claude
```

Type the **number** and press Enter. Claude closes and reopens logged into that
account. A saved account whose snapshot is unusable is shown in red with the
reason and cannot be picked; sign in to it and run `claude-add-account` again.

> ⚠️ Run it from a **standalone** PowerShell window (or the Desktop shortcut),
> **not** from inside a Claude session — switching force-closes the desktop app.
>
> An account whose saved token has expired shows `usage n/a` until you next
> switch to it.

---

## Updating

```powershell
claude-switch-update
```

Pulls the latest version. (You can also just re-run the install one-liner.) When a
newer version is available, `claude-switch-account` shows a one-line notice.

---

## How it works

The Claude desktop app is an Electron app — your login is a **browser session**
(cookies + Local Storage + IndexedDB), just like being signed into claude.ai in a
browser. There is no single token file to swap, so the switcher works on the
complete app profile:

- `claude-add-account` closes Claude and saves the complete app profile into
  `~/.claude-accounts/<email>/profile/`.
- `claude-switch-account` closes Claude, backs up the live profile to
  `~/.claude-accounts/.backup-<timestamp>/profile/`, saves the live profile back
  into the account it belongs to, loads the chosen account's profile and
  restarts the app.

**Finding the live profile.** Depending on the version and install type, the app
keeps its profile in `%APPDATA%\Claude`, in
`%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude` (Store/MSIX) or in
`%LOCALAPPDATA%\Claude-Data`. When the app moves its data it leaves the old
folder behind with a `.user-data-left.*` marker; such folders are skipped. If no
folder holds a session, the switcher stops instead of guessing.

**Safeguards against losing an account:**

- Every profile is verified (`Local State`, cookies, and a token in
  `config.json`) before and after each copy. An empty or logged-out profile never
  overwrites a saved account.
- The account the live session belongs to is asked from Anthropic's OAuth
  profile endpoint. If that is not possible (expired token, no network), the
  switcher falls back to the last switch and asks for confirmation before
  saving the live session into that account.
- When an account is saved again, its previous snapshot is kept as
  `profile.prev` and put back if the new copy does not verify.
- The last 2 verified backups are kept.
- Any error during the swap aborts it; if loading the chosen profile fails, the
  live profile is restored from the backup. After the restart the switcher
  checks that the app actually uses the profile folder that was written.

There is no live in-app switch — the menu is the "dropdown", and the app reflects
whichever account's session is active after the restart.

> **One-time migration:** versions before 3.7 saved only selected session
> folders. Those snapshots are deliberately not restored because they can mix
> authentication state and cause a sign-in warning. After updating, sign in to
> each account once and run `claude-add-account` to create a complete-profile
> snapshot.

> The desktop client changed its credential cache from V1 to V2 in 2026. This
> version detects V2 first, with V1 compatibility for older Claude builds.

---

## Uninstall

```powershell
irm https://raw.githubusercontent.com/nlimper/claude-account-switcher/main/uninstall.ps1 | iex
```

Removes the scripts, the Desktop shortcut and the commands. Leaves your saved
accounts alone; remove them yourself if you want:

```powershell
Remove-Item -Recurse -Force ~/.claude-accounts
```

---

## Notes & caveats

- **Use only accounts you own.** This is for moving between your own accounts,
  not sharing accounts or evading limits.
- **Switching closes Claude.** The app must fully quit so its session files
  unlock; the switcher waits for that, then reopens it. Don't run it from inside
  a Claude session you care about.
- **The whole profile is switched.** Local app data such as settings and local
  sessions belongs to the profile, so after a switch you see the state of the
  account you switched to, as it was when you last left it.
- **Saved sessions are machine-bound.** Cookies are encrypted with a Windows
  (DPAPI) key tied to your user account, so a snapshot only works on the same
  Windows user/machine it was taken on. Don't copy `~/.claude-accounts` to
  another PC, and never commit it anywhere — it contains live login sessions.
- If a switch ever leaves Claude in a weird state, your previous session is in
  `~/.claude-accounts/.backup-<timestamp>/`.
- **Sign-in can still be required by Claude.** A server-enforced session expiry,
  security check, or organization policy cannot be bypassed locally. This tool
  prevents profile mixing; it does not override Anthropic's authentication rules.

## License

MIT — see [LICENSE](LICENSE).
