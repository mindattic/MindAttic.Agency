# Unity vs Unreal: building the same Manalith twice

On 2026-11-22 the same Meshy "Midnight Geode" FBX became the Manalith in two engines: GridGame (Unity 6000.4,
built-in pipeline, GG-T679/GG-T680) and SpaceGod (Unreal, C++, US-T458/US-T460). Both builds follow one spec,
`docs/MANALITH_VISUAL_SPEC.md`, kept word for word in both repos. This page records what lined up, what had to be
translated, and what still doesn't match. It comes from both builders' engine notes (MAT-T186).

Reference frames: `Unity.GridGame/docs/images/manalith-unity-00.png` and `SpaceGod/docs/images/manalith-unreal-00.png`.

## The spec idea that made it work

Every distance is in **D, the satellite's diameter**, and every random choice comes from **seed 1337**. That made the
spec independent of each engine's units (Unity metres vs Unreal centimetres) and of SpaceGod's real/game scale toggle.
Both builds normalise the mesh the same way: centre its bounds and scale the longest edge to 1 (Unity) or to D under
the body's root (Unreal).

## Side by side

| Spec item | Unity (GridGame) | Unreal (SpaceGod) | Lined up? |
|---|---|---|---|
| **Mesh import** | Decimated in Blender 3.3 to 40k tris; FBX on Git LFS; an asset postprocessor rule (Resources textures default to sRGB, no mips) | Decimated in Blender 3.3 to 60k faces and recentred; imported by `UnrealEditor-Cmd -run=pythonscript` launched from PowerShell (Git Bash's MSYS mangles `/Game` paths) | Yes, after decimating both. The 1.2M-tri original was too heavy for either |
| **Units / axes** | Metres, Y-up, left-handed. View +z (toward the viewer) is world −z | Centimetres, Z-up, left-handed. SpaceGod has a Unity-convention compatibility layer for axes and handedness | Yes. Because of that layer, `Euler(15,0,25)` means the same rotation in both, rotation order included |
| **Tumble** | Closed form: `Euler(15,0,25) * AngleAxis(\|ω\|t, ω̂) * Euler(wobble,0,0)`, ZXY order | The same closed form through the compatibility layer | Yes, exactly. Being a function of t rather than stepped per frame makes it frame-rate independent and comparable |
| **PBR maps** | Standard surface shader. Metallic and roughness packed into one texture (R = metallic, A = 1 − roughness, Unity's "smoothness") | A material using the maps directly. The **normal map needed its green channel flipped** (DirectX vs OpenGL convention) | Translated. Smoothness vs roughness and the normal's green channel are the two classic gotchas |
| **Fresnel rim** | Rim in Emission. Gotcha: once a surface shader writes `o.Normal`, its `viewDir` is in **tangent space** | Custom HLSL node computing `pow(1 − N·V, 3)`. All emissives go through SpaceGod's `SG_Expose3` exposure helper | Same formula, but Unreal's rim reads weaker after tonemapping (see below) |
| **Debris** | Mesh particles in world space. Gotcha: a single `Emit()` permanently stopped the system's own emission, so bursts are precomputed `SetBursts`. "Random axis at 30–180°/s" isn't possible, so spin is ±104°/s per axis. The 80/20 glow split is a step gradient. Runtime play, not `Simulate` (hand-stepping crashed the player, GG-T684) | A pooled set of meshes, not Niagara, driven by a xorshift generator seeded 1337 | Close in behaviour. Neither engine's built-in particles honoured the spec as written, and the random generators differ, so the shards don't land in the same places |
| **Lighting** | The spec's white key at (−0.5, 0.7, 0.5) plus a mana-blue rim light. Unity's default ambient isn't controlled | The **system's star is the key light**, which is warm | **No.** This is the main colour difference |
| **Bloom / tone** | Custom `OnRenderImage` bloom (needs `[ExecuteAlways]` for batchmode), half-float target, MSAA 4. Gamma colour space, **no tonemapper** | Engine post-processing: **filmic tonemapper plus auto-exposure** | **No.** The same emissive values come out differently |
| **Framing** | Rendered to a RenderTexture, shown with `Background.FromRenderTexture` in UI Toolkit (the bloom combine un-premultiplies alpha) | In the world. The game re-eases its FOV every frame, so the spec's 30° didn't stick | Partly. Unreal needs a shot mode that holds the FOV |
| **Build / verify loop** | `tools/unity.ps1 -Method …ManalithShot`, then the Windows dev build | `sg.Manalith shot <file> quit` console command, then UBT. Gotchas: comma-joined `static constexpr` members on a DLL-exported class don't compile (C2487), and a UBT run stopped part-way left SpaceGodCore stale until a source file was touched | Both have a scripted shot that loads the scene, frames it and saves a picture, which is what made the comparison possible |

## What the two frames show

Unity's Manalith reads **cool lavender-blue on black** with a bright rim and bloom. Unreal's reads **warm maroon
against a sepia starfield**, with a weaker rim. The mesh, pose maths and textures are the same. The difference comes
from the pipeline:

1. **Key light.** The spec says a white key light. SpaceGod lights the Manalith with Nightglass's warm star.
2. **Tonemapping.** Unreal's filmic tonemapper and auto-exposure compress and warm the highlights. Unity's built-in
   pipeline in gamma space shows emissive values almost as written. The same `#7590C8 × 1.5` rim doesn't give the
   same pixels.
3. **Different moments.** The frames were taken at different tumble times, so the same object faces different ways.

Fix filed as **US-T462**: a reference-shot mode in SpaceGod with the spec's white key, fixed exposure, a held 30° FOV
and the same t as Unity's frame. Then tune the rim until the frames match. The warm star light can stay in normal
play.

## Takeaways

- **Spec in engine-neutral terms** (diameters, degrees per second, a seed, hex colours) and both engines can follow it.
  Values in engine units would have needed translating twice.
- **Make motion a closed-form function of time**, not stepped per frame. It's the one thing that matched exactly, and
  it lets both engines render "the frame at t = 12.5 s".
- **Lighting and post-processing are where engines differ most.** The same material numbers give different pixels
  under a tonemapper. Parity needs a matched reference setup (key light, exposure, tonemapping), not just matched
  material values.
- **Texture conventions to check every time:** normal-map green channel (DirectX in Unreal, OpenGL in Unity), packed
  smoothness vs roughness, and sRGB vs linear for data textures.
- **Built-in particles rarely follow a spec literally.** Expect to write that logic yourself (Unity's precomputed
  bursts, SpaceGod's pooled meshes) and to share the random generator if shards must land in the same places.
- **A scripted reference shot in each engine** is what makes engine comparison possible. Build it before tuning.
