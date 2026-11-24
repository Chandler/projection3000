# Patch

Node-based video, audio and MIDI patcher (Swift, Metal). Build and test from the repo root with `make patch` / `make test-patch`.

Custom shader nodes: `User Nodes/`. HTTP API: `docs/api.md`.


## Project migration

From `patch/`, run `swift run patch-migrate --dry-run` to inventory projects, sessions, subpatches and user field shaders in `~/Projection3000` and `~/Library/Application Support/Patch`. Pass file or directory paths to select other locations.

Close editors using those files, then run `swift run patch-migrate --apply`. The converter validates the complete selection, backs up each original byte-for-byte, and atomically replaces each changed file. Its backup directory under `~/Projection3000 Migration Backups` includes a manifest of original paths and before/after SHA-256 hashes. Use `--backup-dir DIRECTORY` for another backup location. VJ package checksums and file sizes are refreshed for converted package members. Running the dry run again reports any pending documents.
