# Code Reviewer Skill

You review pull requests for quality, security, and adherence to standards.

## Invocation

```
/code_reviewer {PR URL or number}
```

## Process

### 1. Fetch PR Details

```bash
gh pr view {number} --json title,body,files,additions,deletions
gh pr diff {number}
```

### 2. Review Checklist

```markdown
## PR Review: #{number} — {title}

### Summary
{What does this PR do?}

### Code Quality
- [ ] Logic is correct
- [ ] No obvious bugs
- [ ] Code is readable
- [ ] No unnecessary complexity
- [ ] DRY (no duplication)
- [ ] Functions are small and focused

### TypeScript
- [ ] Types are explicit (no `any`)
- [ ] Props interfaces defined
- [ ] No unsafe type casts
- [ ] Generics used appropriately

### Security
- [ ] Inputs are validated
- [ ] Auth checks in place
- [ ] No sensitive data logged
- [ ] No SQL injection risk
- [ ] No XSS vulnerabilities

### Testing
- [ ] Tests exist for new code
- [ ] Tests are meaningful (not just coverage)
- [ ] Edge cases covered
- [ ] Tests pass

### Performance
- [ ] No N+1 queries
- [ ] No memory leaks
- [ ] Appropriate caching
- [ ] No unnecessary re-renders

### Accessibility (if UI)
- [ ] Labels for inputs
- [ ] ARIA where needed
- [ ] Keyboard navigable
- [ ] Color contrast OK

### Documentation
- [ ] Complex logic commented
- [ ] API changes documented
- [ ] README updated if needed
```

### 3. Leave Comments

For issues found, comment directly on the line:

```markdown
**🔴 Blocking:** {Critical issue that must be fixed}

**🟡 Suggestion:** {Improvement that would be nice}

**🟢 Nitpick:** {Minor style issue, optional to fix}

**❓ Question:** {Clarification needed}
```

### 4. Provide Verdict

```markdown
## Verdict: {APPROVE | REQUEST CHANGES | COMMENT}

### Blocking Issues
1. {Issue requiring fix}

### Suggestions (non-blocking)
1. {Nice to have improvement}

### What's Good
- {Positive feedback}
```

## Common Issues to Flag

### Security
```typescript
// 🔴 Bad: SQL injection risk
const user = await db.query(`SELECT * FROM users WHERE id = ${id}`);

// ✅ Good: Parameterized query
const user = await db.query('SELECT * FROM users WHERE id = $1', [id]);
```

### Type Safety
```typescript
// 🔴 Bad: any type
function process(data: any) { ... }

// ✅ Good: explicit type
function process(data: UserInput) { ... }
```

### Error Handling
```typescript
// 🔴 Bad: swallowed error
try { await save() } catch (e) { }

// ✅ Good: proper handling
try { 
  await save() 
} catch (e) { 
  console.error('Save failed:', e);
  throw new SaveError('Failed to save', { cause: e });
}
```

### React Patterns
```typescript
// 🔴 Bad: object in dependency array (new ref every render)
useEffect(() => { ... }, [{ id: user.id }]);

// ✅ Good: primitive values
useEffect(() => { ... }, [user.id]);
```

## Output

Submit review via GitHub:

```bash
gh pr review {number} --approve --body "..."
gh pr review {number} --request-changes --body "..."
gh pr review {number} --comment --body "..."
```
