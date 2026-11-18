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
   Under it, **Red lights** picks whether the city taxi and the highway drive stop at red lights or drive through them. It's saved straight away.
4. To move a location, stand where you want it and click **Set here**. For routes, click **Record**, drive the path and press **F6** at each point. Press **F7** to bring the panel back.
5. Click **Save as default**.

**Jet paint job:** the jet wears the Flight Leonida paint (pink body, sunset tail, FLIGHT LEONIDA on the sides). If it shows another airline, stand by the jet and type `/lastflight livery 2`. To use GTA's own paint jobs instead, set `enabled = false` on the `customLivery` line in `lastflight/config.lua`, then pick one with `/lastflight livery 0`, `1`, `2` or `3`.

**Shuttle bus paint:** both shuttle buses wear the Flight Leonida paint too. To turn it off, set `enabled = false` on the `busLivery` line in `lastflight/config.lua`. To use your own picture for a paint job, put it in `lastflight/livery/custom/` with the same file name as the one in `lastflight/livery/`. It is used instead.

**Highway drive:** the Legion Square driver also offers a farewell drive around the island (target the NPC and pick **Farewell highway drive**). To change its loop, open the **Highway drive** section, click **Clear** on the loop, then **Record** with **Auto** on and drive the highways once. Save when you're back.

To test one part of the drive without doing the whole loop, stand by that part of the route and type `/lastflight drivetest`. A farewell car spawns on the nearest point and drives on from there.

**Highway drive route:** the setup panel has a switch at the top: **Recorded line** (follows the Highway loop) or **Key pins** (drives GPS-style from pin to pin, like the airport bus). For Key pins, record **Highway pins** with F6: one on every corner it should turn at, one just past every split it should go straight through, and one every few hundred metres on highways. Blocked roads work in both.

## 6. Props (party area)

Open the setup panel and click the **PROPS** tab on its side (under **COMMANDS**).

1. Pick a prop from the list and click **Place**. A see-through copy appears.
2. Point with the mouse where it should go. Hold **right mouse** to look around. **Mouse wheel** turns it (hold **Ctrl** for small steps), **Up / Down** arrows raise or lower it.
3. **E** or **left click** places it. Hold **Shift** while placing to place another. **Backspace** cancels.

Props save straight away and every player sees them. The list under **Placed** shows them nearest first, with **Go**, **Move** and **Delete**.

- **Sign (3D text)**: type the text (for example `FINAL DEPARTURES`) and place it like a prop.
- **Custom model name**: type any GTA prop name to place something not on the list.
- **Drinks**: champagne, cocktails, beer and whisky props let players target them and pick **Pour a glass** to have a drink.
- To add props to the list, edit `Config.Props` in `lastflight/config.lua`. A prop marked "not found" doesn't exist in the game.

**Party music:** stand where the music should come from and click **Place music center here**. The party song loops from that spot at 40% volume and fades out about 45 m away, so only people at the party hear it. Players on the flight or the highway drive don't hear it. **Remove** turns it off. Change the song, volume or distance under `music` in `Config.Props`.

## 7. Highway drive pop-ups

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

## How long it takes

Plan your event around these times:

| Trip | Time |
|---|---|
| **Airport bus**: Legion Square to the airport desk | about **5 minutes** |
| **The flight**: buy a ticket, gate shuttle, boarding, the flight and the farewell message | about **16 minutes** |
| **Airport bus, then the flight** | about **21 minutes** |
| **Highway drive**: Legion Square around the island to the airport desk | about **21 minutes** |
| **Highway drive, then the flight** | about **37 minutes** |

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
| Resource won't start after editing pop-ups | A quote with an apostrophe must use double quotes (see step 7) |
