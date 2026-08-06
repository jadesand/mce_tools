# mce_tools

Personal scripts for MCE (Multi-Channel Electronics) data taking, tuning, and
status changes, built on top of the official
[mce_script](https://github.com/multi-channel-electronics/mce_script) /
[mas](https://github.com/multi-channel-electronics/mas) toolchain
(`/usr/mce/mce_script`).

## Layout

- `python/` — Python helpers for sweeps, filtering, and servo/freeze setup
  (e.g. `sweep_target.py`, `mce_freeze_servo_mux11d.py`, `mce_filt.py`,
  `mce_butter_params.py`).
- `script/` — Shell wrappers for tuning and data acquisition (two-level
  tuning, raw acquisition, TES bias square-wave runs, multitask running).
- `noise_taking/` — Per-module noise-taking configs/scripts (`BA_L0`,
  `BA_H5`, `two_level`).

## Requirements

Assumes an MCE/MAS environment (`MAS_DATA`, `MAS_SCRIPT`, `mce_control`,
`auto_setup`, etc.) is already set up, as when sourced from
`/usr/mce/mce_script`.
