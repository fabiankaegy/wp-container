# WP Container — App Icon Generation Prompt (Nano Banana)

Prompt material for generating the WP Container macOS app icon with Nano Banana
(Gemini image generation). Target look: a modern macOS 26/27 "Liquid Glass"-era
developer-tool icon with the craftsmanship of Parakeet's work
(https://parakeet.co/app-icons/ — Louie Mantia, Jr. & Luka Grafera): precise,
dimensional, playful-but-professional, museum-grade gradients and lighting.

---

## Main prompt (copy-paste)

> A macOS app icon in the shape of a single rounded squircle (Apple continuous-corner
> superellipse), centered on a plain neutral background with generous empty margin
> around it. Render at flawless vector-like precision, 1024×1024.
>
> Subject: a translucent frosted-glass shipping container — clean geometric box with
> subtle corrugated vertical ribs on its face — floating at a slight isometric
> three-quarter angle in the center of the squircle. Inside the glass container,
> softly glowing, sits the WordPress "W" monogram rendered as a solid milky-white
> rounded serif "W" medallion, illuminated from within like a lamp. The container's
> glass has visible thickness: crisp specular edge highlights along its top corners,
> soft internal refraction, and a faint cool blue-green tint (evoking developer
> terminals and Apple's container tooling).
>
> Background inside the squircle: a smooth, deep vertical gradient from rich indigo
> at the top to deep WordPress blue (#21759B family) at the bottom, with a very
> subtle radial glow behind the container. A faint, barely-visible grid of thin
> horizontal terminal lines (like a code editor at 4% opacity) textures the lower
> background — quiet developer-tool DNA, not literal readable code.
>
> Lighting: single soft studio key light from the top, macOS-style — gentle top-edge
> inner bevel highlight on the squircle, one restrained specular sweep across the
> glass, soft ambient occlusion where the container meets its faint contact shadow.
> The "W" casts a delicate light bloom onto the container's inner walls.
>
> Style: Apple macOS Tahoe / Liquid Glass icon language crossed with the polished
> dimensional craft of classic Parakeet / Louie Mantia app icons — glossy but
> restrained, deeply layered glass materials, immaculate gradients, no photorealism
> grunge. Colors saturated but tasteful: indigo, cyan-teal glass, warm white glow.
> Crisp silhouette readable at 16×16. Flat front-facing composition, no perspective
> distortion of the squircle itself, no text, no wordmark, nothing outside the
> squircle, no drop shadow on the outer background.

## Negative prompt / avoid

> photorealistic photograph, skeuomorphic wood or leather, paper texture, harsh
> bevels, plastic 3D-render toy look, visible keyboard/monitor/laptop, readable
> code text, multiple icons, perspective-tilted squircle, text or labels, watermark,
> busy background outside the icon, drop shadows outside the squircle, neon
> cyberpunk, low-poly, cartoon outline style, Docker whale

## Variations to request (one at a time)

1. **Dark mode variant** — same composition; background gradient near-black indigo,
   glass container edges glow slightly brighter, "W" glow warmer.
2. **Tinted/mono variant (macOS 26+ requirement)** — single-hue glass relief version:
   all shapes as translucent white glass layers on a neutral gray, no color, relying
   only on depth and highlights (Apple "clear/tinted" icon appearance).
3. **Alternative motif A** — replace the shipping container with a glass terminal
   window (rounded, with three traffic-light dots as tiny glass beads) whose screen
   holds the glowing "W".
4. **Alternative motif B** — stack of two thin glass layers like lasagna of
   squircles, the "W" sandwiched between them, an abstract nod to containers/VMs.
5. **Hero/marketing render** — the chosen icon at a slight tilt with dramatic rim
   lighting on a dark backdrop, for the README/landing page (not for the .icns).

## Output & post-processing checklist

- Generate at 1024×1024 minimum (upscale to 1024pt @2x = 2048 px if offered).
- Ask for the squircle on a solid background, then cut the squircle mask in post —
  generators rarely nail Apple's exact corner curve; final masking should use
  Apple's official icon grid/template (Icon Composer / `.icon` in Xcode 26).
- Check legibility at 512, 128, 32, and 16 px; the "W" and container silhouette
  must survive at 32 px.
- Produce the macOS 26+ appearance set: default, dark, clear/tinted — variants 1–2
  above map to these.
- Run the final PNGs through Xcode's Icon Composer to emit the layered `.icon`
  bundle so the system can apply real Liquid Glass specular behavior; keep the
  flattened `.icns` as fallback for the XcodeGen asset catalog.
