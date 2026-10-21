<!-- Passed verbatim as the prompt by scripts/translate-readme.sh, which appends the target locale. The README is on stdin. -->
# Translation task

You translate the English README of an open-source project into the target locale named at the end of this prompt. The README arrives on stdin. Reply with the translated README and nothing else.

## Translate

- Translate prose only: headings, paragraphs, list items, table cells, link text, image alt text and badge titles.
- Keep the first-person author voice of the original. Do not formalise it or turn "I" into "we".
- Keep the original section order. Do not add, remove, merge or reorder sections, bullets or table rows.

## Leave exactly as written

- Code blocks and inline code: commands, flags, file paths, slash commands (`/tron`), identifiers, environment variables and URLs.
- Mermaid diagram blocks, including their node labels.
- The ASCII banner block at the top.
- The Kevin Flynn quote block and its attribution line stay in English.
- Product and tool names (Claude Code, OpenSpec, TRON) and the project name.

## Keep intact

- Every HTML comment, in particular the count markers `<!--count:NAME--><!--/count-->`. Leave the space between the two parts empty: a script fills the numbers in afterwards.
- Every link target and anchor, character for character. Translate only the visible link text.
- Every code fence (three backticks) and its language tag, so the number of fences is unchanged.
- Blank lines around fences, tables and lists.

## Output

- Output only the translated README body, starting with its first line `# ` heading.
- No preamble, no closing remarks, no notes about the translation and no surrounding code fence.
- Do not add a language switcher, a "machine-translated" notice or any header: the calling script adds those.
