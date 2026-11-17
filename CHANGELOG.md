# Changelog

## 1.1.0

- **New: auto-buy list.** Keep items such as water, food or reagents stocked. Set an amount per item. At a vendor that sells the item, AutoSellMinMax buys what is missing until you carry that amount.
  - **Ctrl+Alt+Left-click** an item in your bags to add it to the auto-buy list or remove it (AltGr+Left-click works on many keyboards). New items start at one full stack.
  - Items on the auto-buy list show a small **vendor bag icon** in the top-right corner in your bags. The sell coin stays in the top-left.
  - The options window has a new **"Items to auto buy"** column. Drag items onto it from your bags *or straight from the vendor window*. Left-click an icon to type an amount, use the mouse wheel for +/-1 (Shift: one stack), and right-click to remove it. Each icon shows its amount.
  - Order at the vendor: sell, then repair, then buy, so the gold from the sale can pay for repairs and purchases.
  - Purchases are limited by your gold, your free bag space and the vendor's stock. The chat shows what was bought, and tells you if gold or bag space ran out.
  - Items bought with tokens or other non-gold currency are never bought automatically.
  - New option "Auto buy items at vendors" (on by default).
- An item can be on only one list at a time. Adding it to one list removes it from the other, and items on the auto-buy list are never sold.
- The option "Separate auto-sell list per character" is now "Separate sell/buy lists per character" and applies to both lists.
- The options window is wider and has two columns: options and auto-sell on the left, auto-buy on the right.

## 1.0.7

- Added an option "Auto repair all items at vendors" (on by default). When you open a vendor that can repair, all your gear is repaired automatically. Repairs happen after selling, so the gold from the sale can pay for them. The chat shows what the repair cost, or warns you if you do not have enough gold.
- Added an option "Use guild funds for repairs first" (off by default). When on, and your guild rank allows it and the guild bank can cover the cost, repairs are paid from the guild bank. Otherwise your own gold is used.
- Both settings are shown at startup and in the minimap button tooltip.

## 1.0.6

- Grey (junk) items are now sold with the game's own "Sell All Junk Items" function when the client has it (WoW Forever), instead of one by one. Registered items are still sold one after another. Clients without that function keep the old behaviour.

## 1.0.5

- Added an option "Separate auto-sell list per character" (on by default for new installs). When on, every character has its own list of registered items; turning it on copies the shared list to a character the first time it is used, and the shared list is kept untouched. The setting is shown at startup and in the minimap button tooltip.

## 1.0.4

- Added an option "Clean up bags after looting and selling" (on by default) that runs the game's bag clean-up (Taschen aufräumen / Sort Bags) after you loot an item and after items were sold at a vendor. It waits until combat ends and combines rapid looting into one clean-up. The current setting is shown at startup and in the minimap button tooltip.

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
