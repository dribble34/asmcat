# asmcat

A terminal pet, written entirely in x86-64 assembly (MASM) for Windows. No
CRT, no C, just raw Win32 console API calls: manual x64 calling convention,
hand-rolled prologues/epilogues, a software framebuffer flushed to the
console with `WriteConsoleOutputA`.

The cat lives in your terminal. Move your mouse near it, feed it, throw it
a ball, or send it to bed.

## Controls

- Move the mouse while **Play** is on to have the cat follow your cursor
- `P` — toggle Play (cursor-following) mode
- Left click — throw a ball; the cat will chase it down
- `F` — drop food at the cursor; the cat will walk over and eat
- `S` — send the cat to bed in the corner (press again to cancel/wake it)
- `Q` — quit

Hunger and happiness slowly decay over time (paused while asleep) and are
restored by feeding and playing.

## Building

Requires Visual Studio Build Tools with the "Desktop development with C++"
workload (for `ml64.exe` and `link.exe`) and the Windows SDK.

```powershell
.\build.bat
```

Produces `build\asmcat.exe`. Run it from a normal terminal window (it takes
over the console's screen buffer and mouse input while running).

## How it works

- `src\main.asm` is the entire program: no external dependencies beyond
  `kernel32.dll`.
- Every proc uses the plain x64 calling convention by hand (arguments in
  `RCX`/`RDX`/`R8`/`R9`, 32-byte shadow space reserved before every `call`) —
  no MASM `INVOKE`/high-level `PROC` parameter macros are used, since this
  was built against a MASM toolchain where that layer was broken.
- Each frame is drawn into an in-memory character buffer and flushed to the
  console in one `WriteConsoleOutputA` call to avoid flicker.
- Input (mouse moves, clicks, key presses) is read via
  `ReadConsoleInputA` in a non-blocking poll each tick.
