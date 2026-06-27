#!/usr/bin/env python3
"""Stamp access-blocking tags onto listed OSM way_ids in a .pbf before tile build."""
import argparse
import sys

import osmium

BLOCK_TAGS = {
    "access": "no",
    "motor_vehicle": "no",
    "motorcar": "no",
    "taxi": "no",
    "psv": "no",
}


def load_blocked_ids(paths):
    blocked = set()
    for path in paths:
        with open(path) as fh:
            for raw in fh:
                line = raw.split("#", 1)[0].strip()
                if line:
                    blocked.add(int(line))
    return blocked


class BlockRewriter(osmium.SimpleHandler):
    def __init__(self, writer, blocked):
        super().__init__()
        self.writer = writer
        self.blocked = blocked
        self.hits = set()

    def node(self, n):
        self.writer.add_node(n)

    def way(self, w):
        if w.id in self.blocked:
            tags = {t.k: t.v for t in w.tags}
            tags.update(BLOCK_TAGS)
            self.writer.add_way(w.replace(tags=tags))
            self.hits.add(w.id)
        else:
            self.writer.add_way(w)

    def relation(self, r):
        self.writer.add_relation(r)


def main():
    ap = argparse.ArgumentParser(description="Block OSM way_ids in a .pbf for Valhalla")
    ap.add_argument("--in", dest="infile", required=True, help="input .osm.pbf")
    ap.add_argument("--out", dest="outfile", required=True, help="output .osm.pbf")
    ap.add_argument("--blocklist", action="append", required=True, help="way_id list file (repeatable)")
    args = ap.parse_args()

    blocked = load_blocked_ids(args.blocklist)
    if not blocked:
        print("apply_blocked_ways: blocklist empty; nothing to do", file=sys.stderr)
        return 0

    writer = osmium.SimpleWriter(args.outfile)
    handler = BlockRewriter(writer, blocked)
    handler.apply_file(args.infile)
    writer.close()

    missing = blocked - handler.hits
    print(f"apply_blocked_ways: blocked {len(handler.hits)}/{len(blocked)} way(s)", file=sys.stderr)
    if missing:
        print(f"WARNING: {len(missing)} way_id(s) not found in extract: {sorted(missing)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
