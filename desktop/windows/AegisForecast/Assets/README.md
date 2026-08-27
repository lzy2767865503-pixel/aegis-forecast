# Quant Scenario Studio Store artwork

These are first-party assets created by **LAI ZEYU（来泽宇）** for Quant
Scenario Studio.
They use the repository's `QS` identity, research shield, scenario curve and
quantitative bars; no external image or trademark asset is incorporated.

`BrandMaster.svg` is the editable vector source. The pinned Pillow generator at
`scripts/windows/generate_store_assets.py` produces:

- all manifest base PNGs;
- scale 100/125/150/200/400 variants;
- 16/24/32/48/256 target-size and unplated taskbar variants;
- a 300×300 Partner Center listing logo;
- a 1024×1024 archival master.

Run `python scripts/windows/generate_store_assets.py` to regenerate and use
`--check` in CI. Visual review of the actual installed package is still part of
the native Windows gate; a successful pixel check cannot validate Windows tile
cropping or high-contrast behavior.
