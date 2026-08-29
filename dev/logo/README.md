# Logo source files

`dev/` is tracked in git but carries `export-ignore` in `.gitattributes`, so nothing here reaches a release archive — these files live in the repository without shipping to users.

| File | Shipped as | Used at |
|---|---|---|
| `logo-full.svg` | `manual/assets/logo-full.svg` | 48px and up — README hero, print, posters |
| `logo-small.svg` | `manual/assets/logo.svg`, and the mark inside `manual/assets/favicon.svg` | 16–32px — site header, favicon |

Both are the same mark. The vessel and the single helix are byte-identical between them; only the three pools differ.

## Editing

Edit `logo-full.svg` first, then regenerate `logo-small.svg` from it rather than changing the two independently — the point of the pair is that the silhouettes match exactly.

To rebuild the favicon after a change: take `logo-small.svg`, wrap the mark in

```
<rect width="64" height="64" rx="12" fill="#252a34"/>
<g transform="translate(32,32) scale(0.883) translate(-32,-33.67)"> … </g>
```

and multiply every stroke width by 1.13 to cancel the 0.883 scale. The scale and offset come from the mark's bounding box (x 14.8–49.2, y 3.1–64.3, centre 32,33.67) fitted into the tile with 5 units of padding.

## The helix recipe

Each half-period is a single cubic: it starts and ends on the centre line, with both control points pushed to the same side.

    control offset = amplitude x 4/3

The 4/3 is because a cubic Bézier never reaches its control points — it peaks at three quarters of the way there. So to bulge 6 units off centre, put the controls 8 out. Mirror the offset for the second strand. Rungs sit at each half-period's midpoint, spaced by the **amplitude**, not the control offset.

Current values:

| | half-period | control dx | rung half-width |
|---|---|---|---|
| single helix | 12.766 | 7.587 | 5.489 |
| pool helix | 6.929 | 3.982 | 2.880 |

## Notes from getting here

**A downward fan reads as legs.** Earlier drafts had three strands meeting at an apex above a wide open base, and every one of them looked like a tripod. Closing the base into a vessel is what fixed it — a closed silhouette reads as an object.

**A double helix cannot survive 16px.** Rungs need roughly 3px of clear space between strands; a 16px favicon gives about 1. That is why `logo-small.svg` exists rather than just scaling the full mark down.

**Period matters more than amplitude.** Below roughly 2:1 period-to-amplitude a helix reads as a spring rather than DNA.

**The mark runs to the bottom edge of its canvas** (lowest stroke edge at y≈64 on a 64 canvas). That is deliberate for the standalone logo; the favicon adds its own padding via the transform above.
