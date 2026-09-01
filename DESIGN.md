# Quill Hebrew — Design System

## Design language

Native macOS control center: a dark, composed pre-flight surface that makes
recording feel intentional. The feather is the sole brand motif. It appears in
the header as a quiet status emblem, not as decorative artwork.

## Color

Use AppKit semantic colors so the surface follows macOS appearance and
accessibility settings:

- Canvas: `windowBackgroundColor`
- Elevated settings surfaces: `controlBackgroundColor` with a subtle semantic
  separator, not a decorative shadow.
- Primary text: `labelColor`; supporting text: `secondaryLabelColor`.
- Accent and primary CTA: `controlAccentColor`.
- Recording state: `systemRed`; ready state: `systemGreen` only when it
  communicates verified readiness.

No gradients, tinted glass panels, or hard-coded low-contrast gray text.

## Typography

Use the system SF family. Header: 24 pt bold; section titles: 13 pt semibold;
body: 13 pt regular; small supporting text: 11–12 pt regular. Respect semantic
weights and default content-size behavior rather than custom display fonts.

## Layout

The controls window is 640 × 720 pt, with a 28 pt perimeter. A small header
contains the feather mark, title, local-processing reassurance, and an
explicit state badge. The body contains:

1. A two-column pre-flight grid for language/engine and transcript/readability
   choices.
2. A full-width files card with destination and latest session actions.
3. A full-width primary record/stop button anchored at the bottom.

Settings groups have 12 pt corners, 16 pt interior padding, and 16–20 pt gaps.
Avoid nested cards and oversized rounding. At narrow widths the two columns
stack in a predictable order.

## Components

- Primary action: native prominent button, full width, title changes between
  “Start recording” and “Stop recording”.
- Status badge: compact rounded semantic label; red only while recording.
- Settings rows: title, one-line explanation, and native pop-up/checkbox.
- File rows: secondary path text with an adjacent native reveal button.
- Disabled controls retain readable semantic text and remain unavailable while
  a recording is active.

## Interaction

Controls change immediately through existing callbacks. Starting/stopping is
the only strongly accented action. Avoid decorative animation; AppKit's normal
control feedback is sufficient. The window supports keyboard focus, standard
shortcuts, and VoiceOver labels.
