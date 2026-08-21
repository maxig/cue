# Changelog

The `## <version> — <date>` section matching a release tag becomes the GitHub
release body **and** the in-app Sparkle update notes. Write it for users:
what changed and why they'd care, not commit titles.

## 1.6.5 — 2026-08-21

The microphone meter now tells you when your input volume is the problem.

- If your Mac's input volume is turned down, your voice is recorded far too
  quietly to caption — but the meter just sat still, looking exactly like a
  microphone that wasn't working at all. It now moves for quiet sound instead
  of going flat, tells you what your input volume is currently set to, and
  takes you straight to the setting that fixes it.

## 1.6.4 — 2026-08-21

Captions work in your own language now.

- Cue wrote captions in the language of its own menus — English — whatever
  language you were actually speaking. If you speak anything else it listened
  for the wrong words, found none, and told you it couldn't make out any speech
  in the recording. It now starts from the language your Mac is set to, and you
  can still pick a different one under Settings ▸ Captions.
- When Cue genuinely can't make out any speech, it now says which language it
  was listening for and where to change it, so a mismatch is obvious instead of
  looking like a microphone problem.

## 1.6.3 — 2026-08-21

Fixes a crash introduced in 1.6.2: the app quit the moment you started a
recording or chose an area of the screen to record.

- Cue no longer quits on Start Recording, or when you pick the part of the
  screen to record. Both of those switch off the microphone level meter added
  in 1.6.2, and switching it off while it was running brought the whole app
  down. Only sessions with the microphone turned on ever hit it — which is
  most of them.
- The meter now hands the microphone over cleanly before a recording claims it,
  and can no longer flicker back to life for a moment after recording has
  started.
- If Cue asked for microphone access and you took a moment to answer, it could
  start listening again after your recording had already begun. It now checks
  that it's still wanted before starting.

## 1.6.2 — 2026-08-18

You can now see whether your microphone is actually hearing you, before you
record instead of after.

- The microphone row shows a live level meter while the Cue menu is open. Say
  something: if the bar moves, you're being picked up. If it stays flat, the
  recording would have captured silence — which until now you only found out
  once it was finished and the captions came back empty.
- Cue asks for microphone access if it never has. It used to ask only during
  first-time setup, so if you skipped that step you could reach Start Recording
  having never been asked, and recordings would come out silent with nothing
  explaining why. The meter now says when access is missing and offers to ask.
- When a recording really did capture no sound, Cue says so and points at the
  microphone, instead of reporting that it couldn't make out any speech. The two
  read the same to a user but need completely different fixes.

## 1.6.1 — 2026-08-18

Choosing the part of the screen to record actually works now. The picker in
1.6.0 was rough enough to be unusable.

- The controls sit in the middle of the area you're choosing and move with it,
  instead of floating somewhere else on the screen looking like a stray dark
  bar. They also show how big your selection is in real pixels, and say so when
  it's smaller than the video it will be stretched to.
- Choosing an area no longer leaves you looking at an empty screen. Opening the
  picker closes the Cue menu, so there was nothing left to press Record in — the
  main button is now Start Recording and goes straight into the countdown. Save
  Area is still there for setting up your framing ahead of time.
- The corner handles show a resize pointer, and the area itself shows a hand, so
  it's clear what you can drag.
- Getting the edges right is much easier: the rectangle snaps to the sides and
  middle of your screen when it's close, resizing snaps to exactly full screen
  height, and it can't be dragged half off the display any more.

## 1.6.0 — 2026-08-18

Vertical recordings can now frame any part of your screen, and the two things
that stopped Creative Mode working in 1.5.0 are fixed.

- Screen Fill no longer has to use the middle of your display. Turn on Creative
  Mode and click Choose next to Area, then drag a rectangle over whatever you
  want in shot — a browser window, one half of a wide screen, the corner of an
  app. It keeps the tall shape of the finished video, so nothing gets cropped a
  second time, and the outline you see while recording marks exactly what will
  be in it. Cue remembers the area for next time, and Reset goes back to the
  middle of the screen.
- The script panel can be typed into. It couldn't before: the panel was never
  able to take keyboard focus, so anything you typed went to whatever window
  was behind it. It also no longer takes the keyboard once you start recording,
  so the app you're recording keeps receiving what you type.
- Captions work. Cue was never actually asking permission to listen to your
  recordings — it only checked whether it already had it, then told you to turn
  it on in System Settings, where Cue wasn't listed precisely because it had
  never asked. It now asks the first time you switch Creative Mode on, and if
  you've previously said no, Settings has a button that opens the right pane.
- Cue no longer claims it can record a selected region of the screen in the
  older, non-vertical mode. That was never built. Choosing a 9:16 area in
  Creative Mode is the way to record part of your screen.

## 1.5.0 — 2026-08-18

Cue can now make vertical videos — the tall kind that go on YouTube Shorts,
TikTok and Instagram Reels — with you cut out of your background, captions for
people watching with the sound off, and your script beside you as you record.

- Turn on Creative Mode and Cue records in the tall shape those apps expect, so
  nothing gets cropped or letterboxed when you upload. Pick how it's framed:
  your screen filling the frame with you in front of it, your screen on top and
  you underneath, or just you.
- Cue removes the background behind you and drops the webcam rectangle
  altogether, so you appear as yourself rather than as a square in the corner.
- A new editor lets you drag yourself wherever you like in the frame, resize,
  mirror, and change the layout — then re-render. Cue replaces the video in
  place, and the editor plays your real composition while you work, so what you
  see is what you get.
- Cue listens back to what you said and puts it on screen in time with your
  voice, which is the difference between a video people scroll past on mute and
  one they actually watch. Four looks to choose from, all built to stay readable
  over a busy screen. It all happens on your Mac, so it works offline and
  nothing is sent anywhere.
- Write or paste a script into a floating panel and read from it while you
  record. It scrolls itself at a speed you set, pauses when you point at it, and
  never appears in the finished video. Whatever you read from is kept alongside
  the recording in your library.
- Recordings you already made can be reframed as vertical too — open one from
  the library and pick a layout.

## 1.4.2 — 2026-07-30

A small polish pass on the new settings tabs.

- The tab bar is cleaner and easier to read: tab labels now line up evenly,
  and the selected tab is highlighted with a subtle accent tint instead of a
  heavy bordered pill.

## 1.4.1 — 2026-07-30

Settings no longer scrolls forever in the small popover window.

- Settings is now organized into five tabs — Recording, Camera, Canvas,
  Sharing, and General — each showing only its own options.
- Canvas gathers everything that shapes the final video frame in one place:
  aspect ratio, background style, and padding.
- Cue remembers which tab you were on, so if setup opens your browser you
  come back right where you left off.
