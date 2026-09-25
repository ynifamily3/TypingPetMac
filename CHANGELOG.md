# Changelog

## 0.8.0 - 2026-09-25

- Add an optional pointer-avoidance mode for click-through position lock.
- Move away with damped spring motion while remaining inside the current display.
- Choose an alternate escape direction when the nearest screen edge blocks movement.

## 0.7.0 - 2026-09-25

- Replace distance-based fading with configurable resting and hover opacity settings.
- Default to 100% resting opacity and 30% hover opacity.
- Apply hover entry and exit opacity immediately without a transition.

## 0.6.0 - 2026-09-25

- Fade the pet image smoothly based on pointer proximity, down to 30% opacity on hover.
- Keep hide and resize controls fully visible while the pet image fades.

## 0.5.1 - 2026-09-25

- Center the image-layer anchor so hover and pressed spring effects scale around the pet's midpoint.

## 0.5.0 - 2026-09-25

- Add velocity-based drag inertia with smooth friction and screen-edge containment.
- Add springy hover enlargement and pressed-down drag feedback.

## 0.4.0 - 2026-09-25

- Show hover controls for hiding and resizing the pet.
- Allow proportional corner resizing and keep it synchronized with the size setting.
- Make the close control hide only the pet while the menu bar app and key monitor continue running.
- Add a menu item for showing the hidden pet again.

## 0.3.0 - 2026-09-25

- Add a dedicated settings window with general, gallery, and key-reaction tabs.
- Add reusable image-set galleries with migration from the earlier single-set format.
- Add exact key and modifier-combination reactions.
- Add four bounce-strength levels.
- Add an original CC0 keyboard-cat placeholder image set and app icon.
- Add Developer ID-aware build and notarization scripts.
