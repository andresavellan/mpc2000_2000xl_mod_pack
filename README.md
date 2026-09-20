# MPC2000 / MPC2000XL — 8 mods

Final modification source, organized by feature. No version history, separate fix packages, installers, test fixtures or firmware images.

| Mod | Source | Classic | XL |
| --- | --- | :---: | :---: |
| TUNE ±360 | [01_tune.S](mods/01_tune.S) | ✓ | ✓ |
| Program Transpose ±36 | [02_program_transpose.S](mods/02_program_transpose.S) | ✓ | ✓ |
| Mute Groups 1–4 | [03_mute_groups.S](mods/03_mute_groups.S) | ✓ | ✓ |
| ALL — Bank / Program | [04_all.S](mods/04_all.S) | ✓ | ✓ |
| Folders | [05_folders.S](mods/05_folders.S) | ✓ | Native |
| TRIM Slider | [06_trim_slider.S](mods/06_trim_slider.S) | ✓ | Native |
| Track Programs | [07_track_programs.S](mods/07_track_programs.S) | ✓ | Native |
| REGIONS | [08_regions.S](mods/08_regions.S) | ✓ | ✓ |

The selected final snapshots are **Classic C17 R2 + REGIONS ALPHA23** and **XL Update 1.3 + REGIONS ALPHA02**. “Final” identifies the selected source versions; REGIONS remains experimental.

## Sources

Each `.S` file collects assembly source sections for one feature. `MOD_UNIT`
and `MOD_PART` identify separate sections. Some features share routines and
fixed addresses, so these files are not independent firmware patches.

This package is for reading and developing the modification code. It does not
contain the complete integration data or tooling needed to reproduce a working
firmware image. Native hooks, placement, relocation and resource integration
must be supplied separately for the exact target image.

No assembly, firmware generation, emulator, installer, hardware or audio tests
were performed while preparing this source-only package.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): use, modification and redistribution for permitted noncommercial purposes. Commercial use outside those permissions requires a separate agreement. A free download can still have a commercial purpose. This is a source-available release with a noncommercial restriction, not unrestricted open source. See [NOTICE.md](NOTICE.md).
