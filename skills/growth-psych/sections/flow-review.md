# Flow mode: step-by-step review

For a multi-step flow or a mock/screen, before or after build: signup, onboarding, checkout, enquiry, booking, upgrade. Work from what you can actually see (screens, mock, URL, steps described); say which.

## Steps

1. **Frame it.** Who starts the flow, from where, to do what. Define the success state and the conversion type (lead sent, account created, payment made). If the flow has competing goals, that is a finding (Hick's Law, Decision Fatigue).
2. **Map it.** List every step from entry to success, plus exits, error paths and recovery paths. Mark steps you could not see.
3. **Walk each step** and fill the table below.
4. **Write findings** in the shared format (observation, principle, why it matters, concrete fix with replacement copy or element, impact and effort).
5. **Rank** by drop-off risk, then impact per effort.

## Per-step table

| Step | User goal | Asked of them | Friction | Drop-off risk | Feedforward | Feedback |
|---|---|---|---|---|---|---|
| 1 | what they want here | fields, taps, choices, waits | count them | H/M/L and why | what happens next is stated? | success, error, loading, empty states |

## What to check at every step

- **Effort:** field count, taps, decisions, waits. Can any be removed, deferred or prefilled? (Cognitive Load, Progressive Disclosure, Spark Effect)
- **Feedforward:** does the user know what the next step is, how long it takes, what it costs? (Feedforward, Chronoception)
- **Feedback:** immediate response to every action; error messages that say what happened and how to fix it, beside the field. (Feedback Loop, Law of Proximity)
- **Four states:** default, empty, loading and error exist and are designed. In a mock, list any missing.
- **Progress:** visible, honest, no moving goalposts. (Goal Gradient, Sunk Cost: never exploit)
- **Momentum:** is the primary action obvious and the secondary action quiet? Distractions removed. (Von Restorff, Selective Attention)
- **Reversibility:** back, edit and exit without losing work. (Reactance, Zeigarnik)
- **Trust at the ask:** why this data, who sees it, what happens if I stop. (Loss Aversion, Feedforward)
- **Ending:** a clear success state with the next step. (Peak-End, Provide Exit Points)

## Flow-specific watch-points

- **Enquiry or booking:** minimum fields, response-time promise, confirmation that restates the request, calendar or reminder option.
- **Signup:** value before the wall (Reciprocity, Aha! Moment), social or passwordless options, no card unless needed, first-run state that gets to first value fast.
- **Onboarding:** one goal per screen, skippable, shaped as small wins (Shaping), empty states that teach.
- **Checkout:** guest option, total cost visible early, payment trust cues beside the pay action, risk reversal near it, no surprise fees.

## Output

Use `deliverable.md` structure with these swaps: replace "first 5 seconds" with the flow map and step table; skip the section walkthrough in favour of step-ordered findings. State clearly what was inferred from a mock and needs checking in the build. Offer to hand the findings to the designer (spec) or to experiment mode (turn the top findings into tests).
