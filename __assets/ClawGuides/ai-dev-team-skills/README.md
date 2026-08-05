# Web Development Team for OpenClaw

Build a complete AI web development team using OpenClaw. This template includes skills for architecture planning, frontend development, backend APIs, testing, and deployment.

## The Pipeline

```
┌─────────────┐    ┌─────────────────┐    ┌──────────────┐    ┌─────────────┐
│  tech_lead  │ → │   frontend_dev  │ → │  backend_dev │ → │ qa_engineer │
│ (planning)  │    │   (UI/React)    │    │  (APIs/DB)   │    │  (testing)  │
└─────────────┘    └─────────────────┘    └──────────────┘    └─────────────┘
                                                                     │
                                                              ┌──────▼──────┐
                                                              │   devops    │
                                                              │  (deploy)   │
                                                              └─────────────┘
```

**Start here:** `/tech_lead {feature description}` — runs the full pipeline.

---

## What's Included

### Orchestrators (entry points)

| Skill | What it does | Hands off to |
|-------|--------------|--------------|
| `/tech_lead` | Architecture + PRD creation | → `/frontend_dev` + `/backend_dev` |
| `/project_manager` | Sprint planning, task tracking | → delegates to specialists |

### Development Skills

| Skill | What it does |
|-------|--------------|
| `/frontend_dev` | Build React/Next.js components, pages, styling |
| `/backend_dev` | Build APIs, database schemas, integrations |
| `/qa_engineer` | Write tests, find bugs, validate acceptance criteria |
| `/devops` | CI/CD, deployment, infrastructure |

### Utility Skills (used by specialists)

| Skill | What it does |
|-------|--------------|
| `/prd_writer` | Generate PRDs with testable acceptance criteria |
| `/code_reviewer` | Review PRs for quality, security, patterns |
| `/test_writer` | Write unit, integration, and e2e tests |
| `/api_designer` | Design RESTful/GraphQL APIs with OpenAPI specs |
| `/db_architect` | Design database schemas, migrations |

---

## Quick Start

### The Full Workflow

```bash
# Step 1: Describe what you want to build
/tech_lead Build user authentication with email/password and OAuth (Google, GitHub). 
Use Clerk for auth. Store user preferences in Postgres.

# After planning, tech_lead creates PRD and hands off

# Step 2: Parallel Development (automatic)
# → frontend_dev builds sign-in/sign-up pages
# → backend_dev builds user preferences API
# → Each creates PR when done

# Step 3: QA Review (automatic)
# → qa_engineer reviews PRs
# → Writes integration tests
# → Validates acceptance criteria

# Step 4: Deploy (requires approval)
# → devops deploys to staging
# → Human smoke test
# → devops deploys to production
```

### Running Individual Skills

```bash
/tech_lead {feature description}     # Full planning pipeline
/frontend_dev {UI task}              # Just build UI
/backend_dev {API task}              # Just build API
/qa_engineer {PR URL}                # Just test/review
/code_reviewer {PR URL}              # Just code review
/devops deploy staging               # Deploy to staging
/devops deploy production            # Deploy to prod (approval required)
```

---

## Setup

### 1. Add Skills to Your Workspace

Copy the `skills/` folder to your OpenClaw workspace:

```bash
cp -r web-dev-team/skills/ ~/openclaw/workspace/skills/
```

Or symlink if you want updates:

```bash
ln -s ~/openclaw/workspace/web-dev-team/skills ~/openclaw/workspace/skills/web-dev
```

### 2. Configure Multi-Agent (Optional)

For parallel execution with separate agent identities, add to your OpenClaw config:

```yaml
agents:
  list:
    - id: tech_lead
      model: anthropic/claude-opus-4
      identity:
        name: "Arch"
        emoji: "🏗️"
        
    - id: frontend
      model: anthropic/claude-sonnet-4
      identity:
        name: "Pixel"
        emoji: "🎨"
        
    - id: backend
      model: anthropic/claude-sonnet-4
      identity:
        name: "Data"
        emoji: "⚙️"
        
    - id: qa
      model: anthropic/claude-sonnet-4
      identity:
        name: "Checker"
        emoji: "🔍"
        
    - id: devops
      model: anthropic/claude-sonnet-4
      identity:
        name: "Ship"
        emoji: "🚀"

tools:
  agentToAgent:
    enabled: true
    allow: [tech_lead, frontend, backend, qa, devops]
```

### 3. Environment Variables

Copy and configure:

```bash
cp .env.example .env
```

Required:
- `GITHUB_TOKEN` - For PR management
- `VERCEL_TOKEN` - For deployment (if using Vercel)
- Database connection strings as needed

---

## Outputs

The pipeline generates files in your `output/` folder:

```
output/
├── {project}/
│   ├── PRD.md                    # Product requirements document
│   ├── architecture/
│   │   ├── DECISIONS.md          # Architecture Decision Records
│   │   ├── schema.prisma         # Database schema
│   │   └── api-spec.yaml         # OpenAPI specification
│   ├── tasks/
│   │   ├── frontend/             # Frontend task breakdown
│   │   └── backend/              # Backend task breakdown
│   ├── reviews/
│   │   └── {pr-number}.md        # Code review notes
│   └── test-reports/
│       └── {date}-report.md      # Test execution reports
```

---

## Checkpoints & Approvals

Built-in checkpoints where you review and approve:

1. **After PRD creation** — Review architecture, approve task breakdown
2. **After implementation** — QA reviews code, human spot-checks
3. **Before staging deploy** — Automated tests must pass
4. **Before production deploy** — Human explicit approval required

---

## The Ralph Loop (Coding Pattern)

For complex coding tasks, specialists use the Ralph loop:

```bash
# Fresh context on each iteration
# Loop until all PRD tasks are checked off
ralphy --codex --prd PRD.md -C /tmp/feature-branch

# Why it works:
# - Context is a cache, not state
# - Fresh restarts beat accumulated confusion  
# - Deterministic acceptance criteria (checkboxes)
```

---

## Safety Rails

### Trust Levels

| Agent | Autonomous | Needs Approval |
|-------|------------|----------------|
| tech_lead | Write PRDs, review code | New dependencies, breaking changes |
| frontend_dev | Implement UI, write tests | Delete components, change auth |
| backend_dev | Implement APIs, write tests | Schema migrations, security changes |
| qa_engineer | Write tests, file issues | Block releases |
| devops | Deploy to staging, run CI | Deploy to production |

### Non-Negotiable Rules

1. **No production deploys without human approval**
2. **No schema migrations without review**
3. **No security-related changes without explicit clearance**
4. **When in doubt, ask**

---

## Memory Architecture

Each agent maintains tacit knowledge:

- **Tech Lead:** Architecture patterns, tech stack decisions, dependency choices
- **Frontend:** Component patterns, design tokens, accessibility standards
- **Backend:** API patterns, database schemas, integration quirks
- **QA:** Known edge cases, flaky tests, regression patterns
- **DevOps:** Infrastructure state, deployment runbooks, incident history

Updated via nightly extraction cron job.

---

## Cost Optimization

| Role | Model | Why |
|------|-------|-----|
| Tech Lead | Opus | Architecture needs best reasoning |
| Frontend Dev | Sonnet/Codex | Fast execution, code-focused |
| Backend Dev | Sonnet/Codex | Fast execution, code-focused |
| QA Engineer | Sonnet | Good enough for systematic testing |
| DevOps | Sonnet | Deployment is procedural |
| Heartbeats | Haiku | Just monitoring, cheapest model |

**Rule:** Opus for thinking, Sonnet for doing, Haiku for watching.

---

## File Structure

```
web-dev-team/
├── README.md                    # This file
├── TOOLS.md                     # Setup guide
├── .env.example                 # Environment template
│
├── assets/
│   └── templates/
│       ├── PRD-template.md      # Product requirements template
│       ├── ADR-template.md      # Architecture decision template
│       └── PR-template.md       # Pull request template
│
├── skills/
│   ├── README.md                # Skills overview
│   │
│   │   # Orchestrators
│   ├── tech-lead/
│   ├── project-manager/
│   │
│   │   # Specialists
│   ├── frontend-dev/
│   ├── backend-dev/
│   ├── qa-engineer/
│   ├── devops/
│   │
│   │   # Utilities
│   ├── prd-writer/
│   ├── code-reviewer/
│   ├── test-writer/
│   ├── api-designer/
│   └── db-architect/
│
└── output/                      # Generated artifacts
```

---

## Requirements

- **OpenClaw** with shell + GitHub access
- **Node.js 18+** for Next.js projects
- **Git** for version control
- **GitHub CLI** (`gh`) for PR management
- Deployment platform (Vercel, Railway, etc.)

---

## Tips

1. **Start with `/tech_lead`** — Good PRDs make everything downstream easier
2. **Parallelize when possible** — Frontend and backend can work simultaneously
3. **Trust the checkpoints** — Review at each stage
4. **Use TDD prompts** — "Write failing test first, then implement"
5. **Fresh context beats long sessions** — Ralph loops for complex tasks

---

## License

MIT — Use freely, modify as needed.

---

*Inspired by the Marketing Team Template and "How to Hire an AI" by Felix Craft.*
