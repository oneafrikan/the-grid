"""The ONE schema number of the usage host files (<private>/usage/<host>.json).

Writer: extract.py. Reader: aggregate.py. Both import SCHEMA from here, so they can
never disagree (two separate `SCHEMA = 1` lines used to exist, and a bump of one
silently made the other ignore every file).

Migration plan, for the day a bump is needed:
  1. aggregate.py learns to read BOTH the old and the new schema; ship that first.
  2. extract.py then writes the new schema. It exits 1 and leaves an existing file
     untouched when that file has a schema other than SCHEMA, so each host needs the
     new extract.py plus a deliberate re-seed (delete the host file; max-merge restarts
     from the transcripts that still exist) or a one-off converter.
  3. Only then raise SCHEMA here. Additive keys do NOT need a bump (the readers ignore
     what they do not know); `wired_first_seen` was added that way, schema stays 1.
"""
SCHEMA = 1
