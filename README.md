# Wi-Fi check

Finds what's slowing down your Wi-Fi. Run it on a computer connected to the Wi-Fi you want to test. It only measures; it changes no settings.

It checks:
- latency, jitter and packet loss to the router and to the internet, which shows whether the problem is your Wi-Fi or your ISP
- signal strength, band (2.4 / 5 / 6 GHz), channel, and how many nearby networks share that channel
- download and upload speed
- bufferbloat (lag when the connection is busy)

It finishes with a numbered list of what's wrong and what to change.

**Windows** (PowerShell):

    powershell -ExecutionPolicy Bypass -File wifi-check.ps1

**macOS / Linux** (Terminal):

    bash wifi-check.sh

On Linux, the Wi-Fi details need `iw` or `nmcli` (NetworkManager).
