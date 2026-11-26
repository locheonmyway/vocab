#!/usr/bin/env python3
"""Prepare a full reviewed knowledge release; never uploads anything."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def version(s):
    return isinstance(s, str) and bool(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", s))

def check(catalog, previous=None):
    assert catalog["schemaVersion"] == 1
    assert type(catalog["releaseSequence"]) is int and catalog["releaseSequence"] >= 1
    assert version(catalog["releaseVersion"])
    units = catalog["units"]
    ids = {u["id"] for u in units}
    assert len(ids) == len(units) and len(units) >= 112
    for u in units:
        assert u["id"].startswith(u["domain"].lower()+".")
        assert u["sources"] and u["examples"] and u["evidence"]["negative"]
        scenarios = {s["id"]:s for s in u["scenarios"]}
        assert len(scenarios) == len(u["scenarios"]) and len(scenarios) >= 2
        assert u["coreScenarioIDs"] and set(u["coreScenarioIDs"]) <= scenarios.keys()
        assert all(s["interaction"] for s in scenarios.values())
        assert set(u.get("related", [])) <= ids
        assert all(s["rights"] == "reference" for s in u["sources"])
    if previous:
        assert catalog["releaseSequence"] > previous.get("releaseSequence", 0)
        assert tuple(map(int,catalog["releaseVersion"].split("."))) > tuple(map(int,previous["releaseVersion"].split(".")))
        new = {u["id"]:u for u in units}
        for old in previous["units"]:
            u = new[old["id"]]
            for key in ("domain","area","title","objective","evidence","coreScenarioIDs"):
                assert u[key] == old[key], (old["id"], key)
            scenarios = {s["id"]:s for s in u["scenarios"]}
            for s in old["scenarios"]:
                assert scenarios[s["id"]]["interaction"] == s["interaction"], s["id"]
    return len(units),sum(len(u["scenarios"]) for u in units)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--previous", type=Path)
    ap.add_argument("--min-app", default="2.2.0")
    ap.add_argument("--check", action="store_true")
    args=ap.parse_args()
    path=ROOT/"knowledge/KnowledgeCatalog.json"
    raw=path.read_bytes()
    assert b"/Users/" not in raw and b"/Volumes/" not in raw
    c=json.loads(raw)
    count,scenarios=check(c,json.loads(args.previous.read_bytes()) if args.previous else None)
    assert version(args.min_app)
    manifest=dict(sequence=c["releaseSequence"],version=c["releaseVersion"],
                  schemaVersion=c["schemaVersion"],minAppVersion=args.min_app,
                  sha256=hashlib.sha256(raw).hexdigest(),unitCount=count,scenarioCount=scenarios)
    latest=ROOT/"knowledge/latest.json"
    if args.check:
        assert json.loads(latest.read_bytes()) == manifest, "manifest/catalog mismatch"
    else:
        latest.write_text(json.dumps(manifest,indent=2)+"\n")
    print(f"{count} units, {scenarios} scenarios, {manifest['version']}")

if __name__=="__main__":
    main()
