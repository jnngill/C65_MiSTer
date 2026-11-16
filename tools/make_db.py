#!/usr/bin/env python3
"""Writes db.json, the MiSTer Downloader database for the C65 core.

    python3 tools/make_db.py           write db.json
    python3 tools/make_db.py --check   fail if db.json does not match the files

It lists the newest releases/C65_YYYYMMDD.rbf (installed as
_Computer/C65_YYYYMMDD.rbf) and the optional MiSTer scripts. Run it after a
new release or a change to scripts/mister/, and commit db.json with them:
Downloader refuses a file whose MD5 does not match the database. Downloader
removes the previous core when a new one replaces it in the database.

No ROMs are listed: the user supplies games/C65/boot.rom.
"""
import glob
import hashlib
import json
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_ID = "c65_mister"
RAW = "https://raw.githubusercontent.com/jnngill/C65_MiSTer/master/"
SCRIPTS = ["c65_prg_disk.sh", "c65_sd_image.sh", "c65_core_switch.sh"]


def newest_core():
    cores = [p for p in glob.glob(os.path.join(ROOT, "releases", "C65_*.rbf"))
             if re.fullmatch(r"C65_\d{8}\.rbf", os.path.basename(p))]
    if not cores:
        sys.exit("no releases/C65_YYYYMMDD.rbf")
    return max(cores, key=os.path.basename)


def entry(src, url):
    data = open(src, "rb").read()
    return {"hash": hashlib.md5(data).hexdigest(), "size": len(data), "url": url}


def entries():
    core = newest_core()
    name = os.path.basename(core)
    files = {"_Computer/" + name: entry(core, RAW + "releases/" + name)}
    for s in SCRIPTS:
        files["Scripts/" + s] = entry(os.path.join(ROOT, "scripts", "mister", s),
                                      RAW + "scripts/mister/" + s)
    return files


def main():
    db_path = os.path.join(ROOT, "db.json")
    files = entries()
    if "--check" in sys.argv:
        db = json.load(open(db_path))
        if db.get("files") != files:
            sys.exit("db.json is stale: run python3 tools/make_db.py and commit it")
        print("db.json matches")
        return
    db = {
        "v": 1,
        "db_id": DB_ID,
        "timestamp": int(time.time()),
        "files": files,
        "folders": {"_Computer": {}, "Scripts": {}, "games": {}, "games/C65": {}},
    }
    with open(db_path, "w", newline="\n") as f:
        json.dump(db, f, indent=2)
        f.write("\n")
    print("wrote", db_path)


if __name__ == "__main__":
    main()
