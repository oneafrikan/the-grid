# PRD Writer Skill

You write Product Requirements Documents with clear acceptance criteria.

## Invocation

```
/prd_writer {feature description}
```

## Output Format

```markdown
# PRD: {Feature Name}

## Overview
{2-3 sentences describing what we're building and why}

## Problem Statement
{What problem does this solve? Who has this problem?}

## User Stories

### Primary User
- As a {user type}, I want to {action} so that {benefit}

### Secondary Users
- As a {user type}, I want to {action} so that {benefit}

## Scope

### In Scope
- {What we ARE building}

### Out of Scope
- {What we are NOT building — prevents scope creep}

## Technical Approach

### Architecture
{High-level technical decisions}

### Data Model
{Key entities and relationships}

### APIs
{Endpoints needed}

## Tasks

### Frontend
- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}

### Backend
- [ ] {Specific, measurable task}
- [ ] {Specific, measurable task}

### Testing
- [ ] {Test requirement}

### DevOps
- [ ] {Infrastructure requirement}

## Acceptance Criteria

### Functional
- [ ] {Specific, testable criterion with clear pass/fail}
- [ ] {Specific, testable criterion}

### Non-Functional
- [ ] Page loads in < 2 seconds
- [ ] Works on mobile browsers
- [ ] Accessible (WCAG AA)

### Security
- [ ] {Security requirement}

## Dependencies

### Internal
- {Component/service we depend on}

### External
- {Third-party service or API}

## Timeline

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Planning | 1 day | None |
| Implementation | X days | Planning |
| QA | X days | Implementation |
| Deploy | 1 day | QA |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| {Risk} | Medium | High | {Plan} |

## Success Metrics
- {How we know this feature is successful}
- {Quantifiable metric}

## Open Questions
- {Questions that need answers before/during implementation}
```

## Guidelines

### Tasks Must Be:
- **Specific:** "Add email validation to sign-up form" not "improve forms"
- **Measurable:** Can definitively say done or not done
- **Independent:** Can be worked on without blocking others (when possible)
- **Small:** 2-8 hours of work each

### Acceptance Criteria Must Be:
- **Testable:** Can write an automated test for it
- **Specific:** No ambiguity about what "done" means
- **User-focused:** Describes behavior, not implementation

### Bad vs Good

❌ Bad: "User can log in"
✅ Good: "User can log in with email/password; invalid credentials show error message; successful login redirects to dashboard"

❌ Bad: "Make it fast"
✅ Good: "Page loads in < 2 seconds on 3G connection"

❌ Bad: "Add tests"
✅ Good: "Unit tests for validation logic; integration tests for API endpoints; 80% coverage minimum"
