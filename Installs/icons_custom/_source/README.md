# Where these icons come from

`draw_all.py` draws every `ck_*.svg` in the parent folder from primitives in
`lib_icons.py` (rings, capsules, ellipses, hexagons, rounded frames). Edit the
numbers there and re-run it rather than hand-editing path data:

    cd Installs/icons_custom/_source && python3 draw_all.py

They are drawn on the same 24x24 grid Material Symbols uses, as **outlines**,
because the stock icons ship at FILL 0 and a solid silhouette reads far heavier
beside them. The two brand marks exist in both styles on purpose
(`ck_cockpit_wheel` / `ck_cockpit_wheel_solid`, `ck_ruggi_site` /
`ck_ruggi_site_solid`).

`Installs/merge_custom_icons.py` folds them into the font as ligatures; that
runs from `build_icon_font.sh`, which replaces the font wholesale and would
otherwise drop them on every refresh.

Two things that cost time when this was built:

- Reversing an arc's **sweep flag** flips which way it bulges. To punch a hole
  you traverse the same arc in the opposite direction. Three drafts of the hive
  came out solid before that was understood.
- Two subjects in a 24px box is one too many. "A bee hovering over a hive" never
  read at UI size; the bee alone does.
