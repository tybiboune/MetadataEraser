Metadata Eraser
================

Strips EXIF, XMP, C2PA, and AI-generation metadata (Stable Diffusion "parameters",
ComfyUI "workflow"/"prompt", NovelAI, Midjourney, etc.) from PNG and JPEG images.
Works entirely offline - dropped files never leave your computer.

HOW TO RUN
----------
Double-click Start-App.bat. A window opens with a drag-and-drop area; drop your
images in, then download the cleaned versions individually or as a .zip.

The app runs a small local web server on http://127.0.0.1:8744/ (only reachable
from this computer) and opens it in Microsoft Edge, or your default browser if
Edge isn't installed. Closing that browser window/tab shuts the server down
automatically.

REQUIREMENTS
------------
- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows - nothing to install)
- A web browser (Microsoft Edge is preferred for the cleanest app-window look,
  but any default browser works)

No installation or admin rights are required, and no internet connection is
needed to clean images - the folder is fully self-contained and portable, copy
it anywhere (including a USB drive) and run Start-App.bat from there. The
refresh icon in the top-right corner checks GitHub for a newer version and
updates in place (internet required for that one action only, and only when
you click it) - see "STAYING UP TO DATE" below.

STAYING UP TO DATE
-------------------
Click the refresh icon next to the theme toggle to check for updates. A small
dot appears on it automatically if a newer version is available. Clicking it
downloads whatever changed straight from
https://github.com/tybiboune/MetadataEraser and applies it in place - no
reinstalling, no losing your settings. If backend files changed, the app
restarts itself automatically (the browser window stays open and reconnects
on its own); if only the interface changed, the page just reloads.

IF WINDOWS SHOWS A "WINDOWS PROTECTED YOUR PC" WARNING
--------------------------------------------------------
Windows tags files extracted from a zip you downloaded (email, USB transfer,
cloud storage, etc.) as coming "from another computer." Double-clicking
Start-App.bat may trigger a SmartScreen prompt because of this, not because of
anything actually wrong with it - this is expected for any unsigned script you
didn't write yourself locally. Click "More info" then "Run anyway" to proceed.

IF YOUR ANTIVIRUS FLAGS THIS
-----------------------------
Some antivirus products (Bitdefender's "Heur.BZC.*.Boxter" heuristic in
particular) have been known to flag PowerShell scripts that do low-level byte
manipulation combined with lists of AI-tool names - both of which this app
does legitimately, since detecting and removing AI-generation metadata is its
entire purpose. This is a known false-positive pattern for that heuristic
family, not a sign of anything actually malicious. If it happens, you can
inspect the source yourself (it's all plain-text PowerShell/HTML/JS in the
src/ and web/ folders - nothing is compiled or obfuscated) or report it to
your antivirus vendor as a false positive.

WHAT'S INSIDE
-------------
Start-App.bat   - double-click this to launch the app
src/            - the PowerShell backend (local web server + metadata engine)
web/            - the browser-based user interface
tests/          - automated tests for the metadata engine (optional, for
                  developers - run tests\Run-Tests.ps1 with Pester installed)
