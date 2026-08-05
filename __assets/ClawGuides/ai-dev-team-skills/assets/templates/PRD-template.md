# PRD: {Feature Name}

> Generated: {Date}
> Author: Tech Lead
> Status: Draft | In Review | Approved

## Overview

{2-3 sentences describing what we're building and why}

## Problem Statement

{What problem does this solve? Who has this problem? Why now?}

## User Stories

### Primary User: {User Type}

- As a {user type}, I want to {action} so that {benefit}
- As a {user type}, I want to {action} so that {benefit}

### Secondary Users

- As an admin, I want to {action} so that {benefit}

## Scope

### In Scope ✅

- {Feature/capability we ARE building}
- {Feature/capability we ARE building}

### Out of Scope ❌

- {What we're NOT building — be explicit to prevent scope creep}
- {Future enhancement to defer}

## Technical Approach

### Architecture

{High-level technical decisions}

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │ ──▶ │    API      │ ──▶ │  Database   │
└─────────────┘     └─────────────┘     └─────────────┘
```

### Data Model

| Entity | Fields | Notes |
|--------|--------|-------|
| {Entity} | id, name, ... | {Notes} |

### APIs Required

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/... | {Description} |
| POST | /api/... | {Description} |

### Dependencies

- {Internal component or service}
- {External API or library}

## Tasks

### Frontend

- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}

### Backend

- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}

### Testing

- [ ] Unit tests for {component}
- [ ] Integration tests for {API}
- [ ] E2E test for {user flow}

### DevOps

- [ ] {Environment variable}
- [ ] {Database migration}
- [ ] {Deployment config}

## Acceptance Criteria

### Functional

- [ ] User can {specific action} and sees {specific result}
- [ ] When {condition}, then {behavior}
- [ ] {Specific, testable criterion}

### Non-Functional

- [ ] Page loads in < 2 seconds
- [ ] Works on Chrome, Firefox, Safari, and mobile browsers
- [ ] Accessible (WCAG 2.1 AA compliant)
- [ ] No console errors

### Security

- [ ] Only authenticated users can access
- [ ] Users cannot access other users' data
- [ ] Input is validated and sanitized

## Timeline

| Phase | Duration | Owner | Dependencies |
|-------|----------|-------|--------------|
| Planning | 1 day | Tech Lead | None |
| Frontend | {X} days | Frontend Dev | Design mockups |
| Backend | {X} days | Backend Dev | Planning |
| Integration | {X} days | Both | FE + BE complete |
| QA | {X} days | QA Engineer | Integration |
| Deploy | 1 day | DevOps | QA approval |

**Total: {X} days**

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| {Risk description} | Low/Med/High | Low/Med/High | {Mitigation plan} |

## Success Metrics

- {How we know this feature is successful}
- {Quantifiable metric: "X% increase in Y"}

## Open Questions

- [ ] {Question that needs answer}
- [ ] {Decision that needs to be made}

---

## Approvals

- [ ] Product: {Name}
- [ ] Engineering: {Name}
- [ ] Design: {Name}
