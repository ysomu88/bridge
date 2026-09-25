# Bridge — Remote Control from Your Phone

Drive the Bridge stack on this PC from anywhere: **start** it, check on it, read
its **logs**, **stop** it, and **shut the PC down** — all from your phone.

Powering the PC **on** is deliberately out of scope (a human turns the machine
on — see [Powering the PC on](#powering-the-pc-on-later) at the end if you ever
want to automate that too). Everything *after* power-on is remote.

---

## How it works

```
   PHONE                                       PC
   ┌────────────────────────┐                 ┌────────────────────────────────────┐
   │ Tailscale  (private   │                 │ sshd  (auto-starts at boot,        │
   │            network)   │                 │        runs as a Windows service)  │
   │                        │                 │   └─ bridge-remote.ps1 <action>    │
   │ Termius  ──── SSH ────┼────────────────▶│                                    │
   │  one-tap snippets      │                 │ Task Scheduler: "BridgeStack"      │
   │                        │                 │   └─ ollama serve                  │
   │ Browser ─── HTTP ─────┼────────────────▶│   └─ python server.py  (:8000)     │
   │ http://<pc>:8000       │                 │                                    │
   └────────────────────────┘                 └────────────────────────────────────┘
```

Two pieces do all the work:

| Piece | Role |
|---|---|
| `bridge-remote.ps1` | The control script — `start`, `stop`, `restart`, `status`, `logs`, `shutdown`, `cancel` |
| `BridgeStack` task | Owns the server's process tree so it **survives your SSH session closing** |

### Why a scheduled task, and not just SSH + `Start-Process`?

This is the single most important design decision here. Windows OpenSSH `sshd`
**tears down its entire process tree when the session disconnects** — unlike
Unix, where a backgrounded process keeps running. So if you start the server
directly from an SSH command, it dies the instant you close the SSH app.

Processes launched by the **Task Scheduler service** are owned by that service
instead of by `sshd`, so they keep running. `start` therefore asks Task
Scheduler to run the stack, and your SSH session can hang up immediately.

---

## One-time setup

### 1. On the PC — run the setup script (elevated)

```powershell
cd "$HOME\Documents\PythonScripts\bridge"
.\setup-remote-access.ps1 -GenerateKeyPair
```

It will pop a UAC prompt and then:

1. Install **Tailscale** (via winget) if it isn't already there
2. Install and start the built-in **Windows OpenSSH Server** at boot
3. Add a firewall rule so SSH is reachable **only from your Tailscale network**
   (`100.64.0.0/10`) and disable the default wide-open OpenSSH rule
4. Generate an SSH key pair for your phone and authorise it, then **disable
   password logins**
5. Register the `BridgeStack` task

Options:

| Switch | Effect |
|---|---|
| `-GenerateKeyPair` | Create a new key pair on the PC (private key path is printed) |
| `-PublicKey "<key>"` | Instead of generating, authorise a key made on your phone |
| `-RunWithoutLogon` | Also lets the stack start when **nobody is logged on** at the PC |
| `-SkipTailscale` / `-SkipOpenSSH` | Skip that part |

Everything it does is written to `remote_logs\setup.log`.

> **Follow-up step:** sign in to Tailscale on the PC (tray icon → *Log in*) if
> the script tells you it isn't logged in yet. Use the same account you'll use
> on your phone.

### 2. On the phone — Tailscale

1. Install **Tailscale** from your app store.
2. Sign in with the **same account** you used on the PC.
3. Turn the VPN switch **on**. Your phone can now reach the PC by name from
   anywhere in the world — there is no port forwarding and nothing is exposed
   to the public internet.

### 3. On the phone — an SSH app (Termius)

Install **Termius** (free) — or Blink, Termux + `ssh`, JuiceSSH, etc.

Add a new host:

| Field | Value |
|---|---|
| Address / Hostname | your PC's Tailscale name (run `.\bridge-remote.ps1 status` on the PC to print it) — e.g. `desktop.tailxxxx.ts.net` |
| Username | your Windows username |
| Key | the private key printed by setup (`~\.ssh\bridge_phone_ed25519`), or the key you generated in the app |

> ⚠️ **Your Windows username contains a space** (`Yeshwanth Somu`). Most apps and
> the `ssh` command accept that if you quote it:
> `ssh "Yeshwanth Somu"@desktop.tailxxxx.ts.net`
> If your app refuses it, either (a) quote the username in the host field, or
> (b) create a second local Windows account without a space (e.g. `bridge`) and
> authorise the key for it instead. Scripts launched as that user still work
> fine as long as it has access to this folder.

### 4. On the phone — save the snippets

In Termius, open the host and save these as **snippets** so they become one-tap
buttons (Termius → *Snippets* → *New*; you can pin them to the host):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" status
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" start
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" stop
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" shutdown -Minutes 5
```

---

## Daily use

| Snippet | What happens |
|---|---|
| `status` | Is Ollama up? Is the server up? Uptime, HTTP check, **and the exact URL to open on your phone** |
| `start` | Starts Ollama if needed, then the Bridge server, and waits until it's actually serving |
| `stop` | Stops the server **and Ollama** (use `-KeepOllama` to stop only the server) |
| `restart` | `stop` then `start` |
| `logs` | Tails the server / worker / Ollama logs — `logs -Tail 80` for more |
| `shutdown` | Stops the stack, then powers the PC off after a countdown (`-Minutes 5`) |
| `cancel` | Aborts a pending shutdown |

A typical session from your phone:

1. Tap **status** → `Bridge server : listening on 8000` (or `not listening`)
2. If it's down, tap **start** → wait for `[OK] Bridge is up.`
3. Open `http://<pc-tailscale-name>:8000` in your phone browser and translate
4. When you're done, tap **stop**, or **shutdown -Minutes 5** to power the PC off

### Things worth knowing

- **First start is slow.** The models (Whisper, Kokoro, Piper, Chatterbox) take
  roughly **40–90 seconds** to load. `start` waits for you (default 300s) and
  prints live progress from the logs if it times out.
- **`stop` also stops Ollama**, including the `ollama app.exe` tray helper —
  otherwise the tray silently respawns the server. If you'd rather keep Ollama
  running, use `stop -KeepOllama`.
- **`shutdown` force-closes running apps** after the countdown (Windows implies
  `/f` whenever a timeout is set), so save your work — or use `-Minutes 5` to
  leave a generous window and `cancel` if you change your mind.
- **Logs live in `remote_logs\`**: `worker.log` (the launcher), `server.log`
  (stdout), `server.err.log` (the server's real log output), `ollama.log`.

---

## Using the translation UI from your phone

Once the stack is up, open this in your phone's browser (with Tailscale on):

```
http://<pc-tailscale-name>:8000
```

`server.py` already binds to `0.0.0.0`, and its WebSocket origin check compares
the browser's `Origin` against the `Host` it was opened on — which matches for
both the Tailscale hostname and the Tailscale IP. So **no server changes and no
`run_bridge.ps1`/localtunnel are needed** for personal use. You can keep
localtunnel as a fallback for sharing with people who aren't on your tailnet.

> Because the UI uses a WebSocket, the phone and PC must stay connected; if
> Tailscale drops, the session stops. Reconnect and hit *Start Listening* again.

---

## Security

| What | How it's protected |
|---|---|
| SSH entry point | Firewall allows TCP 22 **only** from `100.64.0.0/10` (Tailscale's range). The default wide-open `OpenSSH-Server-In-TCP` rule is disabled, so SSH is **not** reachable from your Wi-Fi/LAN or the public internet. |
| Authentication | Public-key only. `PasswordAuthentication no` is written to `sshd_config` (original backed up as `sshd_config.bridge.bak`). |
| Key file ACLs | `administrators_authorized_keys` is locked to `SYSTEM` + `Administrators`, which sshd requires. |
| Tailscale | You must be signed in to your tailnet on both devices; devices can be revoked from the Tailscale admin console. |
| Traffic | Tailscale is WireGuard end-to-end; translation audio never leaves your tailnet. |

To revoke access: remove the device in the Tailscale admin console, and/or delete
the key line from `C:\ProgramData\ssh\administrators_authorized_keys`.

---

## Troubleshooting

**`Could not start the task ... user is not logged on`**
The `BridgeStack` task uses an Interactive logon, so it can only run while
someone is logged in at the PC. Either log in on the PC (a *locked* session is
fine), or run `.\setup-remote-access.ps1 -RunWithoutLogon` once and enter your
Windows password so the task can start with nobody logged in.

**`Permission denied (publickey)` when connecting**
- Check the username is exactly your Windows account name, and **quoted** if it
  contains a space.
- Confirm the private key in the phone app is the one whose public half landed
  in `C:\ProgramData\ssh\administrators_authorized_keys`.
- Give it 10–30 seconds after setup and retry — `sshd` was restarted.

**SSH connects but `bridge-remote.ps1` isn't found**
`$HOME` in the snippet resolves to the SSH user's profile. If you created a
second Windows account, use the absolute path instead:
`C:\Users\Yeshwanth Somu\Documents\PythonScripts\bridge\bridge-remote.ps1`.

**`start` reports the port never opened**
Read the log tail it prints. The most common causes are a missing `llama3.2`
model (`ollama pull llama3.2`) and GPU/CUDA DLL problems — both appear verbatim
in `remote_logs\server.err.log`.

**Phone can't reach `http://<pc>:8000` but SSH works**
Run `status` on the PC — it prints "Tailscale not detected" when Tailscale isn't
installed/logged in. Also check the phone's Tailscale VPN switch is on.

**Port 8000 is occupied again straight after `stop`**
`stop` releases the port by killing whatever holds it; if it returns
immediately, something else (e.g. a leftover `start.ps1` window) is respawning
it.

**Running `setup-remote-access.ps1` opened it in Notepad instead of running it**
Notepad is the default handler for `.ps1` files on Windows, so launching the file
*as a file* — a double-click, from `cmd`, or via the Run box — opens the source
instead of executing it. It only runs when you type it at a **PowerShell prompt**.
If in doubt, use the explicit form, which always executes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup-remote-access.ps1" -GenerateKeyPair
```

**`shutdown` prints shutdown.exe's usage text**
You're on an older copy of the script — the `/c` comment used to contain double
quotes, which mangles the command line. Pull the current `bridge-remote.ps1`.

**A snippet fails with `the -File parameter does not exist`**
Windows' default SSH shell is **cmd.exe**, and `$HOME` is not a cmd variable — it
is passed through literally. The prompt tells you which shell you got:
`PS C:\...>` is PowerShell, whereas `user@HOSTNAME C:\...>` is cmd.exe.

Fix it once on the PC in an **elevated** PowerShell, then disconnect and
reconnect from the phone (the change only affects new sessions):

```powershell
$k='HKLM:\SOFTWARE\OpenSSH'
$ps='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Set-ItemProperty $k -Name DefaultShell -Value $ps
```

`setup-remote-access.ps1` now does this automatically. Until you reconnect, the
snippets must use absolute paths instead of `$HOME`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<you>\Documents\PythonScripts\bridge\bridge-remote.ps1" status
```

**Tailscale says `NoState` / "Tailscale is starting" / the phone times out**
The Tailscale backend can wedge after an install or an upgrade. A **reboot fixes
it** — the node key is stored, so it normally re-registers by itself. If
`tailscale status` then reports `Logged out`, click the tray icon → *Log in*.

While it is wedged there is no tunnel, so port 22 **times out even though sshd is
listening** — the virtual adapter exists but nothing is behind it. That is why
this looks so much like a firewall problem. `restart-tailscale.ps1` tries a
service restart first (cheap, sometimes enough); a reboot is the reliable fix.

**Still stuck — run the diagnostics**

```powershell
.\diagnose-ssh-firewall.ps1
```

Dumps firewall profiles, network categories, every enabled inbound block rule,
the Tailscale adapter state and a live port-22 test, then applies the minimum fix
and re-tests. Add `-ReportOnly` to look without changing anything.

---

## Powering the PC on (later)

Power-on needs hardware or firmware help, which is why it's out of scope:

- **Wake-on-LAN** — enable it in BIOS and on the NIC, then use a WoL app on the
  phone. Getting the magic packet to your LAN from outside needs a router app
  that supports WoL, or an always-on device on your LAN as a relay.
- **Smart plug** + BIOS "Restore on AC power loss" — the simplest hardware route:
  flip the plug off/on and the PC boots.
- Many **router vendor apps** (ASUS, TP-Link, Netgear) expose WoL reachable from
  anywhere through the vendor's cloud.

Once the PC is on, everything in this document works unchanged.

---

## Files added

| File | Purpose |
|---|---|
| `bridge-remote.ps1` | The remote control script (all actions) |
| `setup-remote-access.ps1` | One-time elevated setup (Tailscale, OpenSSH, keys, task) |
| `restart-tailscale.ps1` | Recovery helper — restarts a Tailscale backend wedged in `NoState` |
| `diagnose-ssh-firewall.ps1` | Troubleshooting — firewall/adapter report, then the minimum fix and a re-test |
| `REMOTE_ACCESS.md` | This document |
| `remote_logs/` | Runtime logs (gitignored) |

The `BridgeStack` scheduled task is the only thing registered outside the repo.
Undo it with:

```powershell
Unregister-ScheduledTask -TaskName BridgeStack -Confirm:$false
```

To fully reverse the setup: uninstall Tailscale, then
`Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` (elevated),
and delete the `Bridge-OpenSSH-TailscaleOnly` firewall rule.
