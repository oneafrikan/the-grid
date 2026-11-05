# Experiment mode: principle to test

Same method as the `growth-hacker` role (hypothesis, one variable, pre-set sample and duration, guardrails, honest readout). No metric, no experiment: ask for the target metric and funnel step first.

## Steps

1. **Find the leak.** List funnel steps with volume and drop-off. Pick the step with the worst leak and the most upstream volume. Get the baseline for its metric; if unknown, that is the first task.
2. **Pick the principle.** From the `principles-*.md` check columns, name the principle the leak most plausibly violates or could use. A hypothesis without a principle or an observed behaviour is a hunch.
3. **Write the hypothesis**, one sentence:
   `Because [principle], changing [one variable] will move [primary metric] from [A] to [B] for [segment].`
   Examples: lead form (Cognitive Load: cut 7 fields to 4, enquiry rate 3.1% to 3.8%, paid-search visitors); signup (Feedforward: add "no card, 2 minutes" under the button, signup rate 8% to 9.5%, new visitors); purchase (Loss Aversion: show refund terms beside Pay, checkout completion 52% to 56%, returning visitors).
4. **Score with ICE.** Impact, Confidence, Ease, each 1-10; ICE = mean. Run the highest score that fits the risk and spend budget. Score every candidate; a favourite idea with a low score waits.
5. **One variable.** Control versus a single change. Bundled changes teach nothing; split them.
6. **Metrics.** One primary metric. Guardrails the change could damage (refund rate, downstream conversion, lead quality, support load, retention), each with a tolerance that forces a kill.
7. **Sample and duration sanity check.** Per arm, n is about `16 * p * (1 - p) / d^2` (80% power, 5% significance; p = baseline rate, d = absolute lift). Baseline 5%, target 6%: n is about 7,600 per arm. Duration = 2n / eligible visitors per day, rounded up to whole weeks (at least one full business cycle). If that is longer than the team will wait, pick a bigger change, a higher-traffic step or a different metric. Do not run an underpowered test and call it a result.
8. **Instrument first.** Fire a test event and confirm the primary and guardrail events land, once, on the right arm. No decision on unvalidated data.
9. **Stop rule.** Fix sample, end date and success threshold before launch. No peeking decisions. The only early stop is a guardrail breach.
10. **Readout.** Effect size, sample, interval, guardrail results, decision (ship, kill, iterate), the learning, and the next test. Report losses as plainly as wins. A lift with a regressed guardrail goes to a human. Log every test.

## Escalate, do not decide

- Changes touching consent, pricing shown, PII or a shared production surface (signup, checkout, billing).
- Any variant that works by deception. A dark pattern is off the table whatever its ICE score; offer the ethical variant of the same principle.
- Paid spend above the operator's authorisation.

## Brief template

Goal and funnel step | Baseline and source | Principle | Hypothesis | Control vs variant | Primary metric | Guardrails and tolerances | Sample per arm, eligible traffic, end date | Success threshold | Instrumentation check | Owner and readout date

## Low traffic

When n is out of reach, say so. Use qualitative checks (session recordings, five-user walkthroughs, flow mode) or a before/after read, and label it directional, not causal.
