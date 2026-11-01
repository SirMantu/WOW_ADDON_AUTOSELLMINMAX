# Changelog

## 1.0.2

- Fixed selling stopping partway at the vendor when many items were registered. Items are now sold one after another instead of all at once, and the summary is shown when selling is finished.
- Selling is cancelled cleanly if you close the vendor window.

## 1.0.1

- Quest items can no longer be added to the auto-sell list; a message explains why.
- Quest items are never sold at a vendor, even if they were registered earlier or are grey.
- Added an AutoSellMinMax entry under Esc -> Options -> AddOns with author, version, GitHub and CurseForge links.

## 1.0.0

- Initial release: auto-sells grey items and items you register (Alt+Left-click in your bags).
- Options panel with minimap button and `/asmm`, including protection for green, blue, epic and legendary items.
