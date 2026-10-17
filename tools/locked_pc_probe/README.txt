AI Cockpit - locked-PC probe
============================

Question it answers: can AI Cockpit's self-supplied edition (just copied files, no installer, no admin
rights) run on THIS PC?

How to use (nothing is installed or changed):
  1. Copy this whole folder to the PC, anywhere you may write (Desktop, Documents, a USB stick...).
  2. Double-click  locked_pc_probe.exe  and read the window.
     - If Windows or your security software refuses to start it, that already is an answer: the PC runs only
       approved programs. Then double-click  locked_pc_probe.bat  instead (it uses only programs that ship with Windows).
  3. Both save a report next to themselves (locked_pc_probe_report.txt / locked_pc_probe_bat_report.txt).
     Send that file to whoever is helping you.

What it checks: where you may write; whether an unsigned program may run from your folder, %TEMP% and
%LOCALAPPDATA%; AppLocker / Software Restriction / WDAC / Smart App Control hints; PowerShell mode; whether a
program may listen on localhost; the proxy settings; and whether the AI services can be reached (a plain TLS
connection, no data is sent). It sends nothing anywhere and writes only its report (and a temporary test file).

What it cannot tell you: whether your company allows sending work data to AI services (ask IT / check the
policy), or how a company proxy that inspects traffic would treat Cockpit.

Version 1.0 (2026-10-06). Tested on Windows 11 25H2 (an unlocked test machine: every check passes there; the "blocked"
messages have not been seen on a real locked PC yet).
