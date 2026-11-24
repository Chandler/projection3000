# VJ shows

Each folder in `~/Projection3000/VJ/Shows` (or `$VJ_SHOWS_DIRECTORY`) is one
show: the Compose grid and its sets, mappings and layouts, room, LEDs,
outputs, and the embedded Patch session. Shows are personal data and stay out
of this repo.

- Pick, create or duplicate shows from **Show** at the right of VJ's top bar.
  Switching saves the current show and reopens VJ on the chosen one.
- VJ reopens the last show at launch, from the Dock, Finder or after a crash.
  Shows opened from here restore their devices (LED output, MIDI, Link).
- File paths that don't exist on this laptop (other home folder or checkout)
  are repointed at the same file in the show when it opens.
- Add an existing state folder: `python3 scripts/import_show.py <folder> "<Name>"`.
  It copies files from outside the repo (such as Patch user nodes) into the
  show's `collected/` folder.
- Bundled projects in `~/Projection3000/VJ/Projects` are added and opened with
  `python3 scripts/open-project.py <name>`.

Caches and locks (`native.lock`, `*-cache/`, `ndi-clients.json`) are
machine-local. Quit VJ on one laptop before copying a show to another.
