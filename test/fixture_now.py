"""Print an OTLP/JSON fixture with every timestamp moved to "now".

Each *UnixNano field is shifted by the same offset, so the relative order and
spacing of records in the fixture is preserved.
Usage: python3 fixture_now.py fixtures/logs.json
"""
import json
import sys
import time

TIME_KEYS = ("timeUnixNano", "startTimeUnixNano", "observedTimeUnixNano",
             "endTimeUnixNano")


def collect(node, found):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in TIME_KEYS:
                found.append(int(v))
            else:
                collect(v, found)
    elif isinstance(node, list):
        for v in node:
            collect(v, found)


def shift(node, offset):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in TIME_KEYS:
                node[k] = str(int(v) + offset)
            else:
                shift(v, offset)
    elif isinstance(node, list):
        for v in node:
            shift(v, offset)


def main(path):
    with open(path) as f:
        doc = json.load(f)
    found = []
    collect(doc, found)
    if found:
        offset = time.time_ns() - max(found) - 1_000_000_000
        shift(doc, offset)
    json.dump(doc, sys.stdout)


if __name__ == "__main__":
    main(sys.argv[1])
