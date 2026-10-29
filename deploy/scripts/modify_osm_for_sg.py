"""Apply LTA's temporary AMK Ave 3 realignment at AMK Hub (DHL-32612) to an SG OSM extract when AMK_REALIGNMENT=on."""
import os
import shutil
import sys
import time

import osmium
from osmium.osm import mutable

time_start = time.time()

if len(sys.argv) != 3:
    print("Usage: python modify_osm_for_sg.py <osm_file> <output_file>")
    sys.exit(1)

OSM_FILE = sys.argv[1]
OUTPUT_FILE = sys.argv[2]

mode = os.environ.get("AMK_REALIGNMENT", "off")
if mode not in ("on", "off"):
    print(f"AMK_REALIGNMENT={mode}, expected on or off")
    sys.exit(1)
if mode == "off":
    shutil.copyfile(OSM_FILE, OUTPUT_FILE)
    print(f"AMK Ave 3 realignment not applied (AMK_REALIGNMENT=off); copied {OSM_FILE} to {OUTPUT_FILE}")
    sys.exit(0)

BUS_ONLY = [651971809, 174886145, 633162286, 654724769, 174049653, 788794245]
LOOP = 591264491
LOOP_EAST, LOOP_WEST = 5644580997, 5644581001
WESTBOUND, EXIT_SIGNAL = 74671109, 5644580998
CARPARK_EXIT, CARPARK_JUNCTION, EASTBOUND_AFTER_CARPARK = 646141627, 435031680, 630488641

ACCESS_KEYS = ("access", "vehicle", "motor_vehicle", "motorcar", "taxi", "psv", "oneway:taxi", "oneway:psv", "lanes:psv")

NEW_EXIT_WAY = 2100000001
NEW_RESTRICTION = 2100000001

NEW_EXIT = mutable.Way(
    id=NEW_EXIT_WAY,
    nodes=[LOOP_EAST, EXIT_SIGNAL],
    tags={"highway": "service", "service": "driveway", "oneway": "yes"},
)
NEW_TURN_BAN = mutable.Relation(
    id=NEW_RESTRICTION,
    members=[("w", CARPARK_EXIT, "from"), ("n", CARPARK_JUNCTION, "via"), ("w", EASTBOUND_AFTER_CARPARK, "to")],
    tags={"type": "restriction", "restriction": "no_left_turn"},
)


class AmkRewriter(osmium.SimpleHandler):
    def __init__(self, writer):
        super().__init__()
        self.writer = writer
        self.errors = []
        self.seen = set()
        self.way_nodes = {}
        self.exit_written = False

    def node(self, n):
        if n.id in (LOOP_EAST, LOOP_WEST, CARPARK_JUNCTION, EXIT_SIGNAL):
            self.seen.add(("n", n.id))
        if n.id == EXIT_SIGNAL:
            self.writer.add_node(n.replace(tags={**{t.k: t.v for t in n.tags}, "highway": "traffic_signals"}))
        else:
            self.writer.add_node(n)

    def way(self, w):
        tags = {t.k: t.v for t in w.tags}
        if w.id == NEW_EXIT_WAY:
            self.errors.append(f"way {w.id} already exists; the patch ids collide with real data")
        if w.id in BUS_ONLY:
            self.seen.add(("w", w.id))
            access_tags = sorted(k for k in tags if any(k == p or k.startswith(p + ":") for p in ACCESS_KEYS))
            if access_tags:
                self.errors.append(f"way {w.id} already has access tags {access_tags}; OSM may already show the realignment or reopen it")
            self.writer.add_way(w.replace(tags={**tags, "motor_vehicle": "no", "motorcar": "no", "taxi": "no", "bus": "designated"}))
            return
        if w.id in (LOOP, WESTBOUND, CARPARK_EXIT, EASTBOUND_AFTER_CARPARK):
            self.seen.add(("w", w.id))
            self.way_nodes[w.id] = [n.ref for n in w.nodes]
        if w.id == LOOP:
            if tags.get("oneway") != "yes":
                self.errors.append(f"way {LOOP} oneway={tags.get('oneway')}, expected yes; OSM may already show the realignment")
            self.writer.add_way(w.replace(tags={**tags, "oneway": "-1"}))
            return
        self.writer.add_way(w)

    def relation(self, r):
        self.write_exit()
        if r.id == NEW_RESTRICTION:
            self.errors.append(f"relation {r.id} already exists; the patch ids collide with real data")
        self.writer.add_relation(r)

    def write_exit(self):
        if not self.exit_written:
            self.writer.add_way(NEW_EXIT)
            self.exit_written = True


if os.path.exists(OUTPUT_FILE):
    os.remove(OUTPUT_FILE)
writer = osmium.SimpleWriter(OUTPUT_FILE)
handler = AmkRewriter(writer)
try:
    handler.apply_file(OSM_FILE)
    handler.write_exit()
    writer.add_relation(NEW_TURN_BAN)
    writer.close()
except BaseException:
    writer.close()
    os.remove(OUTPUT_FILE)
    raise

errors = handler.errors
expected = {("w", w) for w in BUS_ONLY + [LOOP, WESTBOUND, CARPARK_EXIT, EASTBOUND_AFTER_CARPARK]} | {
    ("n", n) for n in (LOOP_EAST, LOOP_WEST, CARPARK_JUNCTION, EXIT_SIGNAL)
}
missing = sorted(expected - handler.seen)
if missing:
    errors.append(f"missing from the extract: {missing}")
else:
    nodes = handler.way_nodes
    if (nodes[LOOP][0], nodes[LOOP][-1]) != (LOOP_EAST, LOOP_WEST):
        errors.append(f"way {LOOP} no longer runs {LOOP_EAST} -> {LOOP_WEST}")
    if EXIT_SIGNAL not in nodes[WESTBOUND]:
        errors.append(f"node {EXIT_SIGNAL} is no longer on westbound Ave 3 (way {WESTBOUND})")
    if CARPARK_JUNCTION not in (nodes[CARPARK_EXIT][0], nodes[CARPARK_EXIT][-1]) or nodes[EASTBOUND_AFTER_CARPARK][0] != CARPARK_JUNCTION:
        errors.append(f"node {CARPARK_JUNCTION} no longer joins ways {CARPARK_EXIT} and {EASTBOUND_AFTER_CARPARK}")

if errors:
    os.remove(OUTPUT_FILE)
    print("\n".join(errors))
    sys.exit(1)

print(f"Change file written to {OUTPUT_FILE} (AMK Ave 3 realignment applied)")
print("Time:")
print((time.time() - time_start))
