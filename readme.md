# OBS-Zoom-To-Mouse

An OBS lua script to zoom a display-capture source to focus on the mouse. 

I made this for my own use when recording videos as I wanted a way to zoom into my IDE when highlighting certain sections of code. My particular setup didn't seem to work very well with the existing zooming solutions so I created this.

Built with OBS v29.1.3

Inspired by [tryptech](https://github.com/tryptech)'s [obs-zoom-and-follow](https://github.com/tryptech/obs-zoom-and-follow)

## Example
![Usage Demo](obs-zoom-to-mouse.gif)

## Install
1. Git clone the repo (or just save a copy of `obs-zoom-to-mouse.lua`)
1. Launch OBS
1. In OBS, add a `Display Capture` source (if you don't have one already)
1. In OBS, open Tools -> Scripts
1. In the Scripts window, press the `+` button to add a new script
1. Find and add the `obs-zoom-to-mouse.lua` script
1. For best results use the following settings on your `Display Capture` source
   * Transform:
      * Positional Alignment - `Top Left`
      * Bounding Box type -  `Scale to inner bounds`
      * Alignment in Bounding Box - `Top Left`
      * Crop - All **zeros**
   * If you want to crop the display, add a new Filter -> `Crop/Pad`
      * Relative - `False`
      * X - Amount to crop from left side
      * Y - Amount to crop form top side
      * Width - Full width of display minus the value of X + amount to crop from right side
      * Height - Full height of display minus the value of Y + amount to crop from bottom side
   
   **Note:** If you don't use this form of setup for your display source (E.g. you have bounding box set to `No bounds` or you have a `Crop` set on the transform), the script will attempt to **automatically change your settings** to zoom compatible ones. 
   This may have undesired effects on your layout (or just not work at all).

## Usage
1. You can customize the following settings in the OBS Scripts window:
   * **Zoom Source**: The display capture in the current scene to use for zooming
   * **Force transform update**: Click to refresh the internal zoom data if you manually change the transform/filters on your zoom source
   * **Zoom Factor**: How much to zoom in by
   * **Zoom Speed**: The speed of the zoom in/out animation
   * **Auto follow mouse**: True to track the cursor automatically while you are zoomed in, instead of waiting for the `Toggle follow` hotkey to be pressed first
   * **Follow outside bounds**: True to track the cursor even when it is outside the bounds of the source
   * **Follow Speed**: The speed at which the zoomed area will follow the mouse when tracking
   * **Follow Border**: The %distance from the edge of the source that will re-enable mouse tracking
   * **Lock Sensitivity**: How close the tracking needs to get before it locks into position and stops tracking until you enter the follow border
   * **Auto Lock on reverse direction**: Automatically stop tracking if you reverse the direction of the mouse.
   * **Set manual monitor position**: True to override the calculated x,y topleft position for the selected display
   * **X**: The coordinate of the left most pixel of the display
   * **Y**: The coordinate of the top most pixel of the display
   * **Width**: The width of the display in pixels
   * **Height**: The height of the display in pixels
   * **More Info**: Show this text in the script log
   * **Enable debug logging**: Show additional debug information in the script log

1. In OBS, open File -> Settings -> Hotkeys 
   * Add a hotkey for `Toggle zoom to mouse` to zoom in and out
   * Add a hotkey for `Toggle follow mouse during zoom` to turn mouse tracking on and off (*Optional*)

### More information on how mouse tracking works
When you press the `Toggle zoom` hotkey the script will use the current mouse position as the center of the zoom. The script will then animate the width/height values of a crop/pan filter so it appears to zoom into that location. If you have `Auto follow mouse` turned on, then the x/y values of the filter will also change to keep the mouse in view as it is animating the zoom. Once the animation is complete, the script gives you a "safe zone" to move your cursor in without it moving the "camera". The idea was that you'd want to zoom in somewhere and move your mouse around to highlight code or whatever, without the screen moving so it would be easier to read text in the video.

When you move your mouse to the edge of the zoom area, it will then start tracking the cursor and follow it around at the `Follow Speed`. It will continue to follow the cursor until you hold the mouse still for some amount of time determined by `Lock Sensitivity` at which point it will stop following and give you that safe zone again but now at the new center of the zoom.

How close you need to get to the edge of the zoom to trigger the 'start following mode' is determined by the `Follow Border` setting. This value is a pertentage of the area from the edge. If you set this to 0%, it means that you need to move the mouse to the very edge of the area to trigger mouse tracking. Something like 4% will give you a small border around the area. Setting it to full 50% causes it to begin following the mouse whenever it gets closer than 50% to an edge, which means it will follow the cursor *all the time* essentially removing the "safe zone".

You can also modify this behavior with the `Auto Lock on reverse direction` setting, which attempts to make the follow work more like camera panning in a video game. When moving your mouse to the edge of the screen (how close determined by `Follow Border`) it will cause the camera to pan in that direction. Instead of continuing to track the mouse until you keep it still, with this setting it will also stop tracking immediately if you move your mouse back towards the center. 

## Known Limitations
* Currently this script only works on **Windows**
   * Internally it uses [FFI](https://luajit.org/ext_ffi.html) to get the mouse position by loading the Win32 `GetCursorPos()` function

* Only works on `Display Capture` sources
   * In theory it should be able to work on window captures too, if there was a way to get the mouse position relative to that specific window

## Development Setup
* Clone this repo
* Edit `obs-zoom-to-mouse.lua`
* Click `Reload Scripts` in the OBS Scripts window

##
And to anyone brave enough to use this - Good Luck!
