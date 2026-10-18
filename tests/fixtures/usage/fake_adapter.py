"""Test double for the adapter seam: a second "harness" yielding fixed events.

Used with `extract.py --registry fake_adapter:REGISTRY` (PYTHONPATH set to this
directory) to prove the extractor needs nothing harness-specific.
"""


class Fake:
    name = "fake"

    def available(self):
        return True

    def events(self, since_day=None):
        yield {"day": "2026-10-08", "kind": "skill", "name": "alpha"}
        yield {"day": "2026-10-08", "kind": "skill", "name": "alpha"}
        yield {"day": "2026-10-09", "kind": "agent", "name": "beta"}
        yield {"day": "2026-10-09", "kind": "listing", "skills": 3, "chars": 100}

    def wired(self):
        return {"skills": ["alpha"], "agents": ["beta"]}


REGISTRY = [Fake]
