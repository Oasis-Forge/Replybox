---
name: emulator
description: Drive the app on the Android emulator by reading on-screen labels as text instead of screenshots, and snapshot the emulator before a test so everything can be put back. Use for any hand test on the phone.
argument-hint: "[what to check]"
---

Check on the phone: $ARGUMENTS

`tool/emu.sh` does the adb work (run `bash tool/emu.sh` for every command). A screenshot costs far more than the text list, so read the screen as text and tap by label.

1. **Start.** `bash tool/emu.sh start` as a background command (it lasts as long as the emulator), then `bash tool/emu.sh ready`.
2. **Snapshot first.** The emulator holds the user's own test data. Before changing anything, `save before-test` — and read what it prints: a refused save now stops the run, because the old version reported one either way and the snapshot turned out not to exist when it was time to put things back. When done, `load before-test` and then `forget before-test`: that puts back the data, language, theme, dark mode, app lock, and files pushed to Downloads in one step, so nothing has to be undone by hand. Put back only what you changed: if apps or data are missing that you didn't remove, the user may have cleaned the emulator on purpose, so ask before loading an older snapshot.
3. **Install.** `install dist/<slug>-X.Y.Z.apk` (the artifact `/release --build` wrote), then `launch`. `launch` reads the application id from the Android build file; set `APP_ID` if the project is somewhere other than the repo root.
4. **Walk it.** `screen` lists each element as `label @ x,y (flags)`; `tap "<label>"` presses one, matching the label exactly or else by a part of it. Chain a step and its check in one call: `bash tool/emu.sh tap "Settings" && bash tool/emu.sh screen`. Taps use the phone's own coordinates, so right-to-left mirroring and screenshot scaling don't matter. Use `tap "<label>" 2` for the second match, `hold` for a long press, `type`, `key back`, `scroll down`, and `push <file>` for the file picker.
5. **Screenshots only for looks:** right-to-left layout, dark theme, overflow, a chart or PDF. `shot <scratchpad>/<name>.png`, then Read it. One per thing to judge, not one per step.

Traps:
- The first tap after `launch` can be eaten while the app starts: `screen` again and retry before calling anything broken.
- An icon button with no tooltip shows as `(no label)`; give it a tooltip (an accessibility fix too), or `tapxy` it.
- Loading a snapshot can hang, with `adb devices` showing `offline`. `stop`, then start it cold: `EMU_ARGS=-no-snapshot-load bash tool/emu.sh start`.
- `screen` fails rather than printing a screen it could not read, so an error there means something is still animating: wait and run it again. It never shows the previous screen.
- With a phone plugged in as well, every command stops and asks: set `ANDROID_SERIAL` to the emulator's id from `adb devices`.
- `type` takes ASCII only. Arabic text has to come from a file (`push` a CSV) or an existing entry.
- `screen` output from the file picker and other apps is included; only the status and navigation bars are left out.

In the PR, say what was driven on the phone and what was only compiled.
