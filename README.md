# Snowfall OS

A cartoon winter village for your Mac. Your real Desktop folders sit along little snow lanes in front of the bakery. The windows warm as your pointer passes. Click a cottage and Flurry steps outside to throw a snowball. Double-click the door to open your files in Finder.

![Flurry playing snowball catch between the illustrated sample cottages](docs/desktop-preview.jpg)

[Download for Mac](https://github.com/ult666666/snowfall-os/releases/latest/download/Snowfall-OS-macOS.zip) · [Explore the village in your browser](https://ult666666.github.io/snowfall-os/?v=4.1.0)

## Move into the village

On macOS 12 or later, unzip the download and open **Snowfall OS.app**. The snowflake in the menu bar controls the live scene. The app is built for Apple silicon and Intel. Its public binary has an ad-hoc signature and has not been notarized by Apple.

1. In **Folder Houses**, choose **Style Desktop Folders as Houses** to give your immediate Desktop folders painted cottage icons. Double-click a cottage to open its files as usual. New eligible Desktop folders receive houses while styling is enabled.
2. Pass over a cottage to warm its window. Click it to meet Flurry. When the ball lands, brush the mitten or click it to return the throw. After three returns, or a few idle seconds, the snow clears.
3. Right-click a cottage in Finder and choose **Services → Open House Widgets**. You can also choose **Folder Houses → Open a House…** from the snowflake menu. A notebook and timer belong to that folder even after a rename. Radio and snow settings are shared.
4. Enable **Frame Desktop Widgets** for painted eaves around visible system widgets that macOS exposes on the desktop. macOS keeps drawing the original widget and handling its clicks. Widget contents and folder names stay on the Mac.
5. In **Wallpaper Image**, choose **Set Village as Mac Wallpaper** to keep the painted scene as your desktop picture after the app quits. The live effects run while Snowfall is open.

On macOS versions with **Click wallpaper to reveal desktop**, choose **Only in Stage Manager** in **System Settings → Desktop & Dock** to keep ordinary wallpaper clicks quiet when Stage Manager is off. Snowfall leaves this system-wide preference under your control.

**To undo the desktop changes**, use **Folder Houses → Restore Original Folder Icons** and **Wallpaper Image → Restore Previous Mac Wallpaper and Quit**. Snowfall saves the original icon state before styling. It skips apps, packages, aliases, and hidden items.

![A sample folder cottage showing the widgets available inside](docs/house-room.jpg)

## How the cottages meet the snow

The live layer reads the positions Finder saves for Desktop icons. It anchors a soft shadow and footprints at the door and draws short paths between nearby houses. A native target follows the cottage. A second, temporary target follows the mitten during a round. One click brings Flurry onto the snow beside the house. Double-click opens the real folder. Right-click a door to open its folder or its widgets. Finder still handles the surrounding desktop.

The app reads a single display’s saved free or grid layout locally. For other layouts it can use Finder coordinates when Automation permission is already available. Stacks and unrecognized positions have no ground effects. If macOS temporarily hides its desktop icons, the wallpaper draws the same folder houses and names at their saved positions. Their doors still work. The public demo has three sample cottages. Double-click a sample house or use **Houses** to reach its widgets. The bakery and lantern cottage also play catch.

Each folder uses one compact 256-pixel image for its Finder icon. Snowfall keeps any original custom icon locally so it can be restored. The Mac app bundles the scenery and generates music with Web Audio.

## Snow play

Choose **Roll a Snowball** three times to build Flurry directly on your wallpaper. Another roll prompts a return toss. **Send the Snowplow** pushes the next pile into a snowbank. For a full game, choose **Play in Snow**, challenge Flurry, and dodge with the arrow keys. The first to land three hits wins.

The browser preview uses fictional sample folders. It runs the same widget and game code and stores sample notes locally. Finder integration, desktop widget frames, and system wallpaper changes are available in the Mac app.

## Build on your Mac

Install Apple’s Command Line Tools, then run these commands from the project folder.

```sh
./build-mac.sh
open "build/Snowfall OS.app"
```

The bundled app works offline. To run its isolated integration check, execute `"build/Snowfall OS.app/Contents/MacOS/SnowfallOS" --smoke-test`. It exercises folder styling and restoration using temporary folders.

## Learn how an AI product takes shape

The same illustrated roof, snow edge and light direction appear in the landscape and folder icons. The artwork is bundled once. Flurry’s timing, throws and replies run locally with zero model calls. Follow one porch click from Finder’s mouse event to a short game, then inspect how the game cancels its timers when you leave. [Finder click handling](macos/DesktopHouseInteraction.swift) · [Snowball exchange](porch.js) · [Full snow yard](yard.js)

**Try a design exercise.** A visitor writes “I have half an hour to finish my sketch” but doesn’t know which tool to open. How could a future guide help?

1. **Pick one outcome.** The visitor reaches the focus timer in one click after describing their goal.
2. **Limit the model’s choices.** Give it the visitor’s request and four allowed actions, `focus`, `notes`, `radio`, and `clarify`. A result such as `{"action":"focus"}` would let the app show an **Open focus timer** button for the visitor to choose.
3. **Plan for uncertainty.** If the response is invalid, arrives too late, or asks for clarification, show the ordinary list of tools. The visitor stays in control.
4. **Test it.** Gather 20 requests and label the intended tool together with their authors. Include requests with no clear match. Compare the proposed guide with a simple keyword rule on the same requests. Count correct suggestions, incorrect suggestions, and cases handed back to the visitor.

For a first code walkthrough, type a sentence into a cabin note and follow its `input` event into local storage. Then find how the timer remembers a deadline across sessions. [Mini-app source](apps.js) · [Native Mac implementation](macos/main.swift)
