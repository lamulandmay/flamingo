#!/usr/bin/env python3
# A small script: comments start with '#' and must not split the file.
"""Summarise a CSV of flamingo sightings."""

import csv


def count(path):
    # Count rows per colony.
    totals = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            totals[row["colony"]] = totals.get(row["colony"], 0) + 1
    return totals


if __name__ == "__main__":
    print(count("sightings.csv"))
