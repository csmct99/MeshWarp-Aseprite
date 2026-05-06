# Mesh Warp
An interactive deformation extension for Aseprite

Mesh Warp is a tool for Aseprite that allows you to bend, distort, and warp your pixel art using an adjustable multi-point grid. 
Whether you need to map a flat texture onto an isometric wall, create a wavy flag animation, or wrap a label around a curved potion bottle, this Mesh Warp gives you options you need right inside Aseprite.

I felt like aseprite was missing this feature I love in PS and Gimp so I made a script which does it.
Its not perfect by any means but it gets the job done. Im open to suggestions though.

## Features:
- **Adjustable Grid Resolution**: Start with a simple 1x1 perspective plane, or increase the mesh up to a 6x6 grid for complex, curved surface deformations
- **Interactive UI Viewport**: Pan (Middle/Right Click), zoom (Scroll Wheel), and drag handles precisely inside a custom popup window without destroying the original canvas
- Sampling Modes:
  - **Nearest Neighbor**: Retain hard pixel edges (for strict pixel art)
  - **Bilinear**: Smooth out the pixels with sub-pixel interpolation (for higher-res art or smooth gradients)
- **Live Contextual Preview**: See your warp happening in real-time over your actual canvas background
- **Performance Controls**: Working on a massive sprite with a 6x6 grid? Drop the "Preview Res %" slider to keep the framerate high while you adjust your nodes, then apply it at full quality
  - (in a perfect world I would improve the core code to not require this but eh ... wcyd?)
- **Non-Destructive Integration**: Safely applies to your active cel with full Aseprite undo (Ctrl+Z) support
- **Layer Support**: Respects the layers you have already configured and applies only to the selected layer


## Installation:
1. Download the MeshWarp.lua file from this repository
2. Open Aseprite
3. Navigate to File -> Scripts -> Open Scripts Folder
4. Move MeshWarp.lua into the folder that opens up in step 3
5. Back in Aseprite, go to File -> Scripts -> Rescan Scripts (or simply restart Aseprite).
6. You can now use the tool by going to File -> Scripts -> MeshWarp


## How to Use:
1. Select your art: Use the Marquee tool to select the specific part of your sprite you want to warp. (Note: If you don't select anything, the tool will grab the bounds of your entire active cel)
2. Launch the tool: Go to File -> Scripts -> MeshWarp
3. Set your grid: Adjust the Grid Size slider to add more control points
4. Deform: Click and drag the blue handles
5. Apply: Once you are happy with the preview, click Apply Mesh Warp to commit the changes to your canvas!

---

Feel free to open an issue for suggestions or bug reports. And PRs are welcome <3
