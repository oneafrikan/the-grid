## Purpose

Publish only the landing page and its listed assets to GitHub Pages, without Jekyll and without serving the repository's submodule trees.

## ADDED Requirements

### Requirement: Pages deploys an explicit file list by GitHub Actions
The `pages` workflow SHALL, on every push to `main`, stage exactly the paths listed in `site-files.txt` with `scripts/stage-site.sh` and deploy that staged directory with the GitHub Pages actions, without checking out submodules.

#### Scenario: Only listed files are staged
- **WHEN** `scripts/stage-site.sh <out>` runs with `site-files.txt` listing `index.html` and one image
- **THEN** `<out>` contains exactly those two files

#### Scenario: Unsafe or missing entries are refused
- **WHEN** `site-files.txt` lists a path under `repos/`, `.git` or `.github`, an absolute path, or a path containing `..`
- **THEN** the script exits 2 and names the line
- **AND** a listed path that does not exist makes it exit 1 and name the path

#### Scenario: Landing page references resolve
- **WHEN** the real `site-files.txt` is staged
- **THEN** every relative `src` or `href` in `index.html` exists in the staged directory
- **AND** no `repos/` directory is staged

#### Scenario: Post-merge check
- **WHEN** the change is merged to `main` and the Pages source is set to GitHub Actions
- **THEN** the `pages` run concludes `success`, a HEAD request to the site URL returns 200, and a HEAD request to `<site>/repos/` returns 404

### Requirement: Legacy fallback marker
The repository root SHALL keep an empty `.nojekyll` file so the legacy branch source still builds if the Pages source is switched back.

#### Scenario: Marker present
- **WHEN** the test suite runs
- **THEN** `.nojekyll` exists at the repo root
