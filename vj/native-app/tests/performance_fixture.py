"""Create isolated 4-projector / 16-video benchmark state. Never overwrite state.

Usage: python3 tests/performance_fixture.py SEED_JSON VIDEO_MP4 NEW_STATE_ROOT
Run with VJ_CHECK_PERFORMANCE_ONLY=1 and VJ_PERFORMANCE_RESULTS=/tmp/results.json.
"""
import copy
import json
from pathlib import Path
import shutil
import sys

seed, video, root = map(Path, sys.argv[1:])
root.mkdir()  # Deliberately fail for any existing directory.
(root / "media").mkdir()
shutil.copy2(video, root / "media" / "stress.mp4")
state = json.loads(seed.read_text())
state["outputCount"] = 4
state["outputRouting"] = dict(displayAssignments={}, ndiProjectors={})
state["controls"]["fixtures"] = []
grid = state["grid"]
grid["rows"] = [dict(id=f"video-{i}", name=f"Video {i+1}", blend="normal", enabled=True,
    clips={"column_0": dict(id=f"clip-video-{i}", name=f"Video {i+1}", gen="video", opacity=.5,
        params=dict(file="native-media://stress.mp4", speed=1., position=i/32))}) for i in range(16)]
grid["running"] = dict.fromkeys(("program", "out2", "out3", "out4"), True)
grid["selections"] = {bus: {f"video-{i}": "column_0" for i in range(16) if i % 4 == b}
                      for b, bus in enumerate(grid["running"])}
grid["selections_b"] = {bus: {} for bus in grid["running"]}
grid["crossfade"] = dict.fromkeys(grid["running"], 0.)
grid["control_focus"] = dict(bus="program", row="video-0", column="column_0")
state["showContents"] = {}
rect = copy.deepcopy(state["mappings"]["1"]["project"]["rects"][0])
rect.update(corners=[[0, 0], [1, 0], [1, 1], [0, 1]], mode="live", kind="surface")
for mid, mapping in state["mappings"].items():
    surface = copy.deepcopy(rect)
    surface.update(id="perf-" + mid, source="out" + mid)
    mapping["project"].update(rects=[surface], collections=[], groups=[], traces=[])
    mapping["project"]["output"].update(enabled=True, boundsGrid=False, rotation=0)
(root / "native-state.json").write_text(json.dumps(state))
