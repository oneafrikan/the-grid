## Purpose

Define index.html as a landing page that states what the project is, lets a visitor install it, and is discoverable and shareable.

## ADDED Requirements

### Requirement: Visible H1 with the hero sentence
The page SHALL contain exactly one visible `<h1>` whose text is the approved hero sentence, identical to the README.

#### Scenario: One visible H1
- **WHEN** index.html is parsed
- **THEN** there is exactly one `h1`, it is not hidden by a visually-hidden class, and its text equals the README hero sentence

### Requirement: Copyable install command and repo links
The page SHALL show the quickstart command in a copyable element and SHALL link to the GitHub repository from a "View on GitHub" and a "Star on GitHub" button.

#### Scenario: Install matches README
- **WHEN** the element with id `install-cmd` is read
- **THEN** its text equals the README quickstart command byte for byte

#### Scenario: Repo links present
- **WHEN** the page links are listed
- **THEN** at least two anchors point to `https://github.com/oneafrikan/the-grid`

### Requirement: Light hero image
The page SHALL serve its hero as one `<img>` of a WebP file under 300 KB with explicit width and height and `fetchpriority="high"`, placed after the H1, the install command and the GitHub buttons in DOM order, with no fixed-viewport-height hero rule, and SHALL NOT reference a PNG larger than 300 KB.

#### Scenario: Weight limits
- **WHEN** the file sizes are checked
- **THEN** `assets/hero.webp` is under 300 KB and `index.html` is under 100 KB
- **AND** the source order is h1, `#install-cmd`, a GitHub link, then the hero image
- **AND** the CSS contains no `min-height: clamp(560px`
- **AND** no `the-grid.png` reference remains and the file is no longer tracked

### Requirement: Discoverability metadata
The page SHALL declare a meta description of at most 160 characters, a canonical URL equal to `og:url` and the JSON-LD `url`, SVG then PNG then apple-touch icons, `color-scheme` dark, Open Graph tags (including `og:image:type`) whose absolute `og:image` points at an existing file of exactly the declared width and height, `twitter:card` and `twitter:image:alt`, and valid JSON-LD of type SoftwareSourceCode with name, url, codeRepository, license and author name and no WebSite node. It SHALL NOT declare hreflang.

#### Scenario: Head tags
- **WHEN** the head is parsed
- **THEN** description, canonical, icon, og:title, og:description, og:image, og:image:type, og:url, twitter:card=summary_large_image are present
- **AND** the og image file's real pixel size equals og:image:width and og:image:height
- **AND** the JSON-LD parses as JSON and includes `codeRepository`

#### Scenario: Title names Claude Code
- **WHEN** the `<title>` and `og:title` are read
- **THEN** both equal `the-grid: Claude Code skills and agents on every machine`
- **AND** the meta description equals `og:description`

### Requirement: Published file list covers the page
Every file the page loads by relative URL SHALL be listed in `site-files.txt`, the list of files the Pages workflow publishes, and SHALL exist in the repository.

#### Scenario: Asset listed
- **WHEN** the relative `src` and `href` values in index.html are listed
- **THEN** each one, and `index.html` itself, is a line in `site-files.txt` and exists on disk

### Requirement: No external requests
The page SHALL load no script, stylesheet, font or image from a host other than its own origin, except the og/canonical/JSON-LD URLs, which are metadata only.

#### Scenario: Document links are absolute
- **WHEN** the anchors are listed
- **THEN** none has a relative `href` ending `.md`; repo documents are linked by absolute github.com blob URLs

#### Scenario: Self-contained
- **WHEN** `src` and stylesheet `href` attributes are listed
- **THEN** every one is a relative path

### Requirement: Landing sections ordered for the message
The page SHALL order its sections hero, Who it's for, Quickstart, Flynn pull-quote, What you get, How it works before any reference material, and SHALL NOT contain "Key files" or "Common commands" sections.

#### Scenario: Reference material removed
- **WHEN** the section headings are listed
- **THEN** Who it's for precedes Quickstart which precedes What you get
- **AND** no heading is "Key files" or "Common commands"

### Requirement: Footer and status honesty
The page footer SHALL credit the author by name with links to the repository and issues, and the Status section SHALL state that personal config is gitignored.

#### Scenario: Footer
- **WHEN** the footer is read
- **THEN** it contains "Gareth Knight" and links to the repo and its issues
- **AND** it does not contain "brainchild"
