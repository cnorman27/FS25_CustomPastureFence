# Custom Pasture Fence (FS25)

Farming Simulator 25 mod that lets you choose the fence type of animal pastures (sheep, cows, pigs, horses, chickens) instead of the fixed fence each barn ships with, such as the orange sheep netting.

## Usage

- **When building:** in construction mode, select a barn that comes with a pasture and press **"Pasture fence"** (`H` by default, the construction screen's fourth action). Pick any fence available in your game, including fences from other mods. The preview updates right away, and the barn is built with that fence. The game's "Customize fence?" step then draws with the chosen fence too.
- **Existing pastures:** stand inside one of your pastures on foot and press the activate key on **"Change pasture fence"**. The fence is rebuilt in place and keeps its shape.
- Pick **Original fence** to go back to the barn's default fence.

The choice is saved with the savegame. Before removing the mod, set changed pastures back to **Original fence**: the savegame stores the segments of the chosen fence, and without the mod the base game loads them against the barn's original fence, which may not know those segments.

## Why the base game can't do this

- Each barn XML hard-codes one fence in `placeable.husbandry.fence#xmlFilename`, and `PlaceableHusbandryFence:onLoad` builds the pasture's single `Fence` from that file.
- The "Customize fence" step only lets you redraw the route of that same fence type.
- The savegame stores fence segment ids and positions, but not the fence file, so the type is re-read from the barn XML on every load.

## How it works

- Wraps `PlaceableHusbandryFence.onLoad` to load the chosen fence XML, and wraps `saveToXMLFile` to store the choice as `husbandryFence#customFenceXml`.
- Maps segment ids that the chosen fence doesn't define (for example `SEGMENT`) onto that fence's own segment templates.
- When you change an existing pasture, rebuilds each segment at its old start and end points, then rebuilds the animals' navigation mesh.
- Adds the fence picker to `ConstructionBrushHusbandry` through the construction screen's fourth action, and reloads the placement preview with the chosen fence.
- Installs its hooks when a savegame loads and removes them when you leave, so they don't stack up on reload.

## Limitations

- Singleplayer only.
- If the new fence has no gate, gates of an existing pasture are left as openings. A new barn built with such a fence gets a closed fence instead of its gates.
- If any segment of the new fence cannot be built, the change is cancelled and the old fence stays.
- Fences with long panels may leave small gaps at corners.
- Changing the fence is free.
