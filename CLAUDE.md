# BrainwasherPro

Talent spec window for the Goblin Brainwashing Device, with an optional
ActionBarProfiles profile per spec. Fostercare5988's addon, based on Horyoshi's
BrainwasherPro 1.5 (GitHub starts at 1.0.0; the earlier history, 1.5 included,
is only in the local branches `backup/pre-2.0.0` and `backup/pre-1.0.0`); keep crediting him in the TOC
(`X-Credits`) and README. Regression tests: `regressions/BrainwasherPro` in
VanillaForge (29 tests).

| File | Job |
| --- | --- |
| `ClassicAPIRequirement.lua` | ClassicAPI guard; sets `ns.unsupported` so the addon stays inert |
| `ForgeUI.lua` | The shared settings kit (ForgeUI, Ember) |
| `BrainwasherPro.lua` | Menu reading, slot actions and popups, main and edit windows, bar switching |

Things to know:

- The device is recognised by its options (`Save/Activate/Buy Nth
  Specialization`, read with `C_GossipInfo.GetOptions`), not by NPC name.
  The full wording was read in play (2026-10-21) and is quoted at
  the top of `BrainwasherPro.lua`. Reset gives its price as `(1g0s0c)`;
  Activate carries the slot's split, `(41/10/0)`, which the window shows and
  saves over the addon's own record.
- The native gossip window must stay open (closing it ends the conversation),
  so it is faded and scaled to 0.01 while ours shows, and restored after.
- Every menu bumps `session`; popups carry the session they belong to, so a
  popup from an old menu does nothing. Server-confirmed (boxCoded) options
  skip our popup.
- ActionBarProfiles link: `spec.actionProfile`. After Activate, the swap counts
  as done on `CHARACTER_POINTS_CHANGED` or once the talent split differs from
  the one at Activate (in play, 2026-10-22, a swap only unlearned and learned
  spells, with no points event). The profile then loads 1.5 s after the last
  talent/spell event, waits for combat to end, and is dropped if talents do not
  change within 60 s. Uses
  only `ABP_GetProfileNames` and `ABP_LoadProfileByName`.
- Row text (spec name, split and bar profile) is cut with "..." at
  `TEXT_WIDTH` so it never runs under Edit; hovering the row shows the full
  names. Profile names have no length limit, spec names 20 letters.
- Active spec: the slot whose split (from the device, else saved) equals the
  talents you have now shows "Active"; clicking it says so instead of swapping.
- Save names the spec it replaces. A linked profile ActionBarProfiles no longer
  has shows "Bars: missing" (name in the tooltip) and is not loaded on swap.
- `CHARACTER_POINTS_CHANGED`, `SPELLS_CHANGED` and `PLAYER_REGEN_ENABLED` are
  registered only while a swap is watched (`ListenForSwap`).
- `BrainwasherProDB` is per character. The unused 1.5 talent snapshot
  (`spec.talents`) is cleared on load.
