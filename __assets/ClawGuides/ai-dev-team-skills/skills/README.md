# Web Development Team Skills

This directory contains all the skills that power the web development team pipeline.

## Skill Categories

### 🎯 Orchestrators
Entry points that coordinate the full workflow.

| Skill | Command | Description |
|-------|---------|-------------|
| [tech-lead](./tech-lead/) | `/tech_lead` | Architecture, PRD creation, coordination |
| [project-manager](./project-manager/) | `/project_manager` | Sprint planning, task tracking |

### 👩‍💻 Specialists  
Core development roles that do the hands-on work.

| Skill | Command | Description |
|-------|---------|-------------|
| [frontend-dev](./frontend-dev/) | `/frontend_dev` | React/Next.js UI development |
| [backend-dev](./backend-dev/) | `/backend_dev` | APIs, databases, integrations |
| [qa-engineer](./qa-engineer/) | `/qa_engineer` | Testing, bug hunting, validation |
| [devops](./devops/) | `/devops` | CI/CD, deployment, infrastructure |

### 🔧 Utilities
Supporting skills used by specialists.

| Skill | Command | Description |
|-------|---------|-------------|
| [prd-writer](./prd-writer/) | `/prd_writer` | Generate PRDs with acceptance criteria |
| [code-reviewer](./code-reviewer/) | `/code_reviewer` | Review PRs for quality |
| [test-writer](./test-writer/) | `/test_writer` | Write comprehensive tests |
| [api-designer](./api-designer/) | `/api_designer` | Design APIs with OpenAPI specs |
| [db-architect](./db-architect/) | `/db_architect` | Database schema design |

## How Skills Work Together

```
User Request
     │
     ▼
┌─────────────┐
│  tech_lead  │ ─── Creates PRD, breaks down tasks
└──────┬──────┘
       │
       ├──────────────────┐
       ▼                  ▼
┌─────────────┐    ┌─────────────┐
│frontend_dev │    │ backend_dev │ ─── Parallel execution
└──────┬──────┘    └──────┬──────┘
       │                  │
       └────────┬─────────┘
                ▼
         ┌─────────────┐
         │ qa_engineer │ ─── Review + test
         └──────┬──────┘
                │
                ▼
         ┌─────────────┐
         │   devops    │ ─── Deploy
         └─────────────┘
```

## Adding New Skills

1. Create a folder: `skills/your-skill/`
2. Add `SKILL.md` with instructions
3. Add any supporting files (scripts, templates)
4. Update this README

## Skill File Structure

Each skill folder contains:

```
skill-name/
├── SKILL.md           # Main instructions (required)
├── templates/         # Any templates used
├── scripts/           # Supporting scripts
└── examples/          # Example outputs
```
