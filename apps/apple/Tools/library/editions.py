"""The edition `index_bench import-all` computed for each dictionary of the corpus, by its folder's name: what the E2E
`library` stage requires the app's library to register (plan-macos-v1 WI-5). Reads the core's own registry
(`<scratch>/data/registry.json`), never the dictionaries.

    editions.py <registry.json> <corpus>   prints {"<folder>": "mdx-sha256-v1:…"} for every folder of <corpus> not
                                           starting with `_` (the ones the stage ships); fails unless each has exactly one
"""
import json
import os
import sys

registry_path, corpus = sys.argv[1], os.path.realpath(sys.argv[2])
registry = json.load(open(registry_path, encoding="utf-8"))
folders = sorted(name for name in os.listdir(corpus)
                 if os.path.isdir(os.path.join(corpus, name)) and not name.startswith("_"))
found = {}
for record in registry.get("locations", {}).values():
    location = record.get("location", "")
    if not location.startswith("path:"):
        continue
    path = os.path.realpath(location[len("path:"):])
    folder = os.path.basename(os.path.dirname(path))
    if os.path.dirname(os.path.dirname(path)) != corpus or folder not in folders:
        continue
    if folder in found and found[folder] != record["edition"]:
        sys.exit(f"editions.py: {folder} holds two editions")
    found[folder] = record["edition"]
missing = [folder for folder in folders if folder not in found]
if missing or not found:
    sys.exit(f"editions.py: index_bench registered no edition for {missing or 'any folder'}")
json.dump(found, sys.stdout, indent=1, sort_keys=True)
print()
