"""Discover bounded unittest groups and run each selected test once."""

import argparse
import fnmatch
import importlib.util
import math
import os
from pathlib import Path
import sys
import unittest


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module", type=Path)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--list-scenarios", action="store_true")
    selection.add_argument("--scenario")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(args.module.stem, args.module)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    loader = unittest.TestLoader()
    tests = list(flatten(loader.loadTestsFromModule(module)))
    if loader.errors:
        parser.error("; ".join(loader.errors))
    pattern = "*" + os.environ.get("ONLY", "") + "*"
    tests = [test for test in tests if fnmatch.fnmatchcase(test.id(), pattern)]
    # Round-robin groups spread adjacent slow tests across workers.
    count = max(1, math.ceil(len(tests) / 8))
    groups = {"python-" + str(index + 1): tests[index::count] for index in range(count)}
    if args.scenario is not None:
        groups = {key: value for key, value in groups.items() if key == args.scenario}
    if not tests or not groups or any(not group for group in groups.values()):
        parser.exit(1, "FAIL: no Python tests matched the selection\n")
    if args.list_scenarios:
        for key, group in groups.items():
            print(key + "\t" + args.module.stem + ": " + key + " (" + str(len(group)) + " tests)")
        return 0
    suite = unittest.TestSuite(tests if args.scenario is None else groups[args.scenario])
    return 0 if unittest.TextTestRunner().run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
