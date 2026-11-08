# Changelog

## 1.0.4

- Added an option "Clean up bags after looting and selling" (on by default) that runs the game's bag clean-up (Taschen aufräumen / Sort Bags) after you loot an item and after items were sold at a vendor. It waits until combat ends and combines rapid looting into one clean-up.

## 1.0.3

- Added WoW Forever support while retaining Classic Era compatibility.
- Added fallbacks for item-info layouts, missing item APIs, and older UI/timer APIs.
- Fixed Alt+Left-click in your bags doing nothing on WoW Forever. Clicks are now detected directly under the mouse cursor, so they work with the combined bag and the new bag UI.
- Fixed item lookups on WoW Forever: item info now uses `C_Item.GetItemInfo`, and item IDs are read from the bag slot when the bag API returns only an item name instead of a link.
- Fixed the coin marker not showing on registered items in your bags.
- Added `/asmm debug` to print what is under the mouse on click, for troubleshooting.

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
