# Snowfall OS

A little winter desktop for your Mac. Settle into Frostpine Hollow, say hello to Pip the snow hare, and build a snowman who throws snowballs back.

## Open the cabin

On macOS 12 or later, download **Snowfall-OS-macOS.zip** from the latest release, unzip it, and open **Snowfall OS.app**. Choose **View → Use as Desktop** to place the cabin behind your regular windows. Choose **Return to Window** from the app’s Dock menu to bring it back. [Download for Mac](https://github.com/ult666666/snowfall-os/releases/latest) · [Try the browser demo](https://ult666666.github.io/snowfall-os/)

![Snowfall OS desktop with a snowy cabin, Pip, and the Cabin Radio player](docs/desktop-preview.jpg)

### Build your own copy

With Apple’s Command Line Tools installed, run these commands from the project folder on your Mac. The script builds a universal app for Apple silicon and Intel. The downloadable app uses an ad-hoc signature. If macOS blocks it on first launch, building locally gives you a copy compiled on your Mac.

```sh
./build-mac.sh
open "build/Snowfall OS.app"
```

## A few things to try

- **Cabin Radio.** Press play, skip between three original instrumentals, or tap the heart to save a favorite. The music keeps playing when you close its little window.
- **Quick launch.** Open it from the desktop or press **⌘K**. Search for the focus timer to start a 25-minute session or a five-minute break.
- **Field guide.** Work through three short decisions about what a language model could help a cabin visitor do. Each answer comes with feedback.
- **Snow settings.** Select the weather control to change the snowfall or turn on **Reduce motion**. Say hello to Pip by clicking the hare.

### Play in the snow yard

Open **Snow yard** from the desktop to build. Click the parked yellow plow to jump straight to clearing a path.

- **Build.** Choose **Roll & stack** or tap the loose snowball. Let each roll land. Three rolls build Flurry. He stays outside the cabin when you leave the yard. Click him there for a rematch.
- **Snowball fight.** Click Flurry to throw, or use **Throw**. Move your mitten away from the marked landing spot with the arrow keys or on-screen arrows. First to three hits wins.
- **Plow.** Tap a pile or choose **Plow next pile** to send the little plow across the yard. Clear all three, then choose **Fresh snowfall** to refill it.

Your notes, snowman, timer state, radio favorites, and settings use local storage. The Mac app and browser demo each keep their own copy. Clearing the demo’s site data erases its saved items.

## Learn how an AI product takes shape

The wallpaper and album covers were generated with AI during development. The shipped app makes zero model calls. Hand-coded rules decide how the snow yard responds, and Web Audio plays a score by turning note numbers into oscillator frequencies. The bundled Mac app works offline. [Game rules](yard.js) · [Radio scores and synthesis](radio.js)

**Design exercise.** Imagine a visitor who writes “I have half an hour to finish my sketch” but doesn’t know which desktop tool to open. Try designing a guide that can suggest one next action.

1. **Define success.** The visitor reaches the focus timer with one click after entering their request.
2. **Limit the model’s choices.** Send the visitor’s request and a small list of allowed actions. Accept a single result such as `{"action":"focus"}`. Other allowed values could be `notes`, `radio`, and `clarify`. Show a button for the visitor to accept the suggestion.
3. **Handle uncertainty.** If the model returns an unknown action, times out, or picks `clarify`, show the ordinary launcher. The visitor can choose a tool and carry on.
4. **Test whether AI helps.** Ask friends for 20 requests and label the intended tool together, including requests with no clear match. Compare the model with a simple keyword rule on those same requests. Count correct suggestions, wrong-tool suggestions, and how often each option hands the choice back to the visitor.

To trace a real interaction, open a note, type a sentence, and follow the `input` event into local storage. The same file contains the focus timer and field-guide lessons. [Mini-app source](apps.js) · [Mac window implementation](macos/main.swift)

The bundled fonts are distributed under the SIL Open Font License. [DM Sans license](assets/fonts/DMSans-LICENSE.txt) · [Pixelify Sans license](assets/fonts/PixelifySans-LICENSE.txt)
