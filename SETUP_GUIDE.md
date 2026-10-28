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

Any server admin can set it up. Being an admin in the **txAdmin** web panel is not enough on its own: the player also has to be a server admin in `server.cfg`.

**Making someone a server admin:**
1. In the txAdmin web panel, open **Players**, click the player and copy their `fivem:` ID (a number).
2. Add this line to `server.cfg`, below the other `add_principal` lines:
   ```
   add_principal identifier.fivem:1234567 group.admin
   ```
3. Restart the server and have them reconnect.

**Using the logbook:**
1. Type `/lastflight logbook` to get the **Flight Logbook**.
2. Use the logbook to open the **Flight Setup** panel. Close it with the **×** or **ESC**, or by using the logbook again.
3. Pick a mode at the top:
   - **Test**: nobody is kicked; players return to Legion Square
   - **Live - Return**: the live event; players return to Legion Square
   - **Live - Kick**: the live event; players are disconnected at the end
4. To move a location, stand where you want it and click **Set here**. For routes, click **Record**, drive the path and press **F6** at each point. Press **F7** to bring the panel back.
5. Click **Save as default**.

**Highway drive:** the Legion Square driver also offers a farewell drive around the island (press **G** at the NPC). To change its loop, open the **Highway drive** section, click **Clear** on the loop, then **Record** with **Auto** on and drive the highways once. Save when you're back.

## 6. Highway drive pop-ups

During the highway drive, place names and short quotes pop up as the car passes. Change them in `lastflight/config.lua` under `Config.Tour.viewpoints`. Each pop-up is one line:

```lua
{ pos = vec3(-149.12, 6219.83, 30.20), label = 'Paleto Bay', quote = 'Small towns, big memories.' },
```

- **label**: the place name
- **quote**: the line under it. Leave it out to show only the place name
- **pos**: where it pops up. Stand there in game and type `/lastflight coords` to get it
- Add or delete lines to add or remove pop-ups. Each one shows once per drive
- For an apostrophe, wrap the quote in double quotes: `quote = "This isn't goodbye."`

Restart the resource after changing them: `restart lastflight`.

## If something goes wrong

| Problem | Fix |
|---|---|
| Plane appears for a second then vanishes | Do step 3, then type `/lastflight spawn` |
| No music | Make sure the files in `lastflight/audio/` weren't renamed or removed, then `restart lastflight` |
| Items or images missing | Redo step 2 and restart ox_inventory |
| "No permission" or the logbook does nothing | Make them a server admin (see step 5) and reconnect |
| txAdmin in-game menu won't open | In txAdmin, edit the admin and make sure their **Cfx.re** or **Discord** ID matches the account they play on |
| Players got kicked while testing | Switch the mode to **Test** |
| Highway car leaves the highway | Re-record the **Highway drive** loop (see step 5) |
| Resource won't start after editing pop-ups | A quote with an apostrophe must use double quotes (see step 6) |
