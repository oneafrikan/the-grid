   **Model-routing learnings go to `docs/model-selection.md` instead.** If an
   approved learning is about *which model to use for which job* — a model that
   failed at a task class, a cheaper model that turned out good enough, a
   retry/turn-count observation, an actual measured cost — it belongs in that
   document's decision table or its "Known gaps" section, not buried in
   `LEARNINGS.md` as prose. That file exists to answer "which model for X", and
   lived experience is better evidence than a vendor benchmark. Still write the
   `LEARNINGS.md` entry (the hash ledger depends on it) — but also update
   `docs/model-selection.md` and say so in the step-9 summary.

   This matters most for the token-efficiency question that document flags as
   an open evidence gap: no published cross-model turns-to-completion study
   exists, so observations mined from real history here are the only data
   the-grid will ever have on it. Don't let them evaporate.
