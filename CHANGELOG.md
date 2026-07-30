# Changelog

The `## <version> — <date>` section matching a release tag becomes the GitHub
release body **and** the in-app Sparkle update notes. Write it for users:
what changed and why they'd care, not commit titles.

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
