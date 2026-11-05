# Deliverable: structure, scoring and styling

Used by audit and flow modes. Experiment mode ends in its own brief and readout (`experiments.md`).

## Delivery

- In Claude Code, deliver one self-contained HTML file through the Artifact tool: inline CSS and JS, no external requests, system font stack.
- Elsewhere, or if asked for markdown or another format, mirror the same structure in that format.

## Structure (in this order)

1. **Header:** subject audited (linked), date, one-line verdict, overall score /100.
2. **Scoreboard:** five subscores 0-10 with a one-liner each: Clarity, Attention and hierarchy, Motivation (value and proof), Friction (ease of action), Trust.
3. **The visitor:** 2-3 sentences. Who arrives, from where, wanting what; what the page or flow wants; the conversion type.
4. **First 5 seconds** (audit): what, who, why, next, answered or not.
5. **Walkthrough:** in scroll or step order. Each finding is a card:
   - Verdict: working / friction / hurting / missing opportunity (use the matching emoji).
   - The observation, quoting real copy or describing the real element.
   - **Principle callout:** category marker, principle name, one-line definition.
   - Why it matters for this goal.
   - **The fix:** actual replacement copy or the specific element change, with Impact and Effort badges.
6. **Prioritised fix list:** table sorted by impact per effort: # / fix / principle / impact / effort. Mark quick wins.
7. **What is already working:** 3-5 things to keep.
8. **Method note:** capture method (fetched copy, screenshots, both), what could not be verified, and the credit to growth.design's catalogue.

## Scoring

- Overall = Clarity 25%, Motivation 25%, Friction 20%, Trust 20%, Attention 10%.
- 85+ strong, tune-ups only. 70-84 solid, clear leaks. 50-69 significant leaks, fix before scaling spend or traffic. Under 50, rebuild.
- Be honest. Most decent pages land 60-80. A flattering audit helps no one.
- Same page re-audited later: keep the rubric, so scores compare.

## Badges

Category markers: 🙈 Information, 🔮 Meaning, ⏰ Time, 💾 Memory. Impact: 🔴 high (blocks the primary action or hits every visitor above the fold), 🟠 medium, 🟡 low (polish). Effort: 🟢 copy or setting, 🟡 new section or asset, 🔴 structural redesign. Verdicts: ✅ working, ⚠️ friction, ❌ hurting, 💡 missing.

## HTML styling

- Light background, generous whitespace, column about 760px wide, 16-18px body text.
- Principle callouts: soft tinted box, rounded corners, bold name, definition in quotes. One tint per category: Information blue, Meaning purple, Time amber, Memory green.
- Verdict emoji leads each finding heading; impact and effort as small pills.
- Copy fixes as two stacked blocks: muted "before", highlighted "after".
- Scoreboard as a row of stat tiles; no chart libraries.
- Optional sticky table of contents for long reports.
- Tone: conversational first-person visitor narration in the walkthrough ("I still don't know what it costs..."), plain and professional in the fix list.
