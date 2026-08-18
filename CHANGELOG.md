# Changelog

The `## <version> — <date>` section matching a release tag becomes the GitHub
release body **and** the in-app Sparkle update notes. Write it for users:
what changed and why they'd care, not commit titles.

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
