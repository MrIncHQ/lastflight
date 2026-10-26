# Last Flight to Vice City — Setup Guide

## 1. Install

1. Copy the **`lastflight`** folder into your server's `resources` folder.
2. Add this to `server.cfg`, below qbx_core, ox_lib, ox_inventory and ox_target:
   ```
   ensure lastflight
   ```

## 2. Add the items

1. Copy the item entries from **`LastFlightItems/items.txt`** into **`ox_inventory/data/items.lua`**.
2. Copy the images from **`LastFlightItems/Inventory Images/`** into **`ox_inventory/web/images/`**:
   - `lastflight_ticket.png`
   - `lastflight_ticket_stub.png`
   - `flightlogbook.png`
3. Restart ox_inventory.

## 3. Allow the jet (Qbox)

Qbox deletes jets as soon as they spawn. To allow it:

1. Open `qbx_smallresources/qbx_entitiesblacklist/config.lua`
2. Delete the line `` [`JET`] = true, ``
3. Restart qbx_smallresources.

## 4. Start it up

Restart the server.

## 5. Admin setup

Any server admin can set it up.

1. Type `/lastflight logbook` to get the **Flight Logbook**.
2. Use the logbook to open the **Flight Setup** panel. Close it with the **×** or **ESC**, or by using the logbook again.
3. Pick a mode at the top:
   - **Test**: nobody is kicked; players return to Legion Square
   - **Live - Return**: the live event; players return to Legion Square
   - **Live - Kick**: the live event; players are disconnected at the end
4. To move a location, stand where you want it and click **Set here**. For routes, click **Record**, drive the path and press **F6** at each point. Press **F7** to bring the panel back.
5. Click **Save as default**.

## If something goes wrong

| Problem | Fix |
|---|---|
| Plane appears for a second then vanishes | Do step 3, then type `/lastflight spawn` |
| No music | Make sure the files in `lastflight/audio/` weren't renamed or removed, then `restart lastflight` |
| Items or images missing | Redo step 2 and restart ox_inventory |
| "No permission" | You need to be a server admin |
| Players got kicked while testing | Switch the mode to **Test** |
