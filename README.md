# Last Flight to Vice City

A farewell event for FiveM roleplay servers. Players say goodbye to Los Santos with one last flight out of LSIA, or a last scenic drive around the island first.

Built for **Qbox** with **ox_lib**, **ox_inventory** and **ox_target**.

---

## What it does

### The last flight
- A free bus at Legion Square takes players to the airport (target the driver and pick **Ride to LSIA**).
- Players buy a ticket at the LSIA check-in desk and get a ticket item.
- A shuttle can take them out to the jet, where everyone boards one shared flight together.
- They buckle up with **B**, the captain makes an announcement, and the jet taxis out and takes off.
- The jet circles the whole island for about 10 minutes while music plays.
- It heads out over the ocean and the screen fades to **ENJOY YOUR TIME IN GTA VI**.
- Players keep a torn ticket stub as a souvenir.

### The farewell highway drive
- A driver at Legion Square offers a last drive around the island (look at the driver with your target eye and pick **Farewell highway drive**). Riders buckle up with **B** once seated.
- Groups of up to 12 people can go together, in up to 4 cars with an NPC driver and 3 passengers each.
- A group's cars leave together as a convoy. The next group can head out 2 minutes later, with up to 8 cars on the road at once.
- The drive comes with its own soundtrack, and place names with short quotes pop up as you pass landmarks.
- Traffic is cleared for riders, so the road is all theirs.
- It ends at the airport check-in desk, ready for the flight.

> **A note on the driving:** the cars are driven by GTA's own AI. Most of the time it's smooth, but now and then a car might take a corner a little wide, hesitate at a junction or do something a bit odd. It wouldn't be GTA if the driving wasn't a little weird sometimes.

### How long it takes

| Trip | Time |
|---|---|
| The flight (ticket, shuttle, boarding, flight) | about 15 minutes |
| Highway drive (Legion Square to the airport) | about 26 minutes |
| Highway drive, then the flight | about 41 minutes |

---

## For server owners

- **Easy setup in game:** admins use the Flight Logbook item to open a setup panel. Every location, route and stop can be placed in game, with nothing to type.
- **Three modes:**
  - **Test:** nobody is kicked.
  - **Live - Return:** players come back to Legion Square at the end.
  - **Live - Kick:** players are disconnected at the end.
- **Red lights switch:** choose whether the NPC drivers stop at red lights or drive through them.
- **Highway drive tools:** edit the route, blocked roads and pop-ups, and test any part of the drive from where you stand.
- **One folder:** drag it in and start it.

## Install

1. Copy the **`lastflight`** folder into your server's `resources` folder.
2. Add `ensure lastflight` to your `server.cfg`, below qbx_core, ox_lib, ox_inventory and ox_target.
3. Add the ticket items and images from the **`LastFlightItems`** folder to ox_inventory.
4. Allow the jet in Qbox's entity blacklist.
5. Restart your server.

Full step-by-step instructions, admin commands and troubleshooting are in the **[Setup Guide](SETUP_GUIDE.md)**.

## Requirements

- FiveM server with OneSync
- Qbox (qbx_core)
- ox_lib, ox_inventory, ox_target

---

## Music

Original music by **mrincognito**.
