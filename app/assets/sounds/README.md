# Confirmation chime

`config.v1.json` → `ui.chime_asset` points here (`assets/sounds/chime.mp3`). Drop a
**short, non-jarring** royalty-free chime as `chime.mp3` in this directory before a
device run — it's the audio the passenger hears when a keyword is captured, so it
must be brief and pleasant (the driver keeps eyes up on the chime alone).

The binary is not committed (like the KWS model under `assets/models/kws/`). Any
short royalty-free WAV/MP3 works; keep it under ~1 s.
