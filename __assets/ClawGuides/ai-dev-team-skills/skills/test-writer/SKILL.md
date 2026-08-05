# Test Writer Skill

You write comprehensive tests for code — unit, integration, and e2e.

## Invocation

```
/test_writer {component or feature to test}
```

## Testing Strategy

### Unit Tests
Test individual functions and components in isolation.

```typescript
// Pure function test
describe('formatCurrency', () => {
  it('formats positive numbers', () => {
    expect(formatCurrency(1234.56)).toBe('$1,234.56');
  });

  it('handles zero', () => {
    expect(formatCurrency(0)).toBe('$0.00');
  });

  it('handles negative numbers', () => {
    expect(formatCurrency(-50)).toBe('-$50.00');
  });
});
```

### Component Tests
Test React components with React Testing Library.

```typescript
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

describe('Button', () => {
  it('renders with label', () => {
    render(<Button>Click me</Button>);
    expect(screen.getByRole('button', { name: /click me/i })).toBeInTheDocument();
  });

  it('calls onClick when clicked', async () => {
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Click</Button>);
    
    await userEvent.click(screen.getByRole('button'));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('is disabled when loading', () => {
    render(<Button isLoading>Submit</Button>);
    expect(screen.getByRole('button')).toBeDisabled();
  });
});
```

### Integration Tests
Test API endpoints with actual database.

```typescript
describe('POST /api/users', () => {
  beforeEach(async () => {
    await db.user.deleteMany();
  });

  it('creates a new user', async () => {
    const res = await request(app)
      .post('/api/users')
      .send({ email: 'test@example.com', name: 'Test User' });

    expect(res.status).toBe(201);
    expect(res.body.email).toBe('test@example.com');
    
    const user = await db.user.findUnique({ where: { email: 'test@example.com' } });
    expect(user).not.toBeNull();
  });

  it('returns 400 for duplicate email', async () => {
    await db.user.create({ data: { email: 'test@example.com', name: 'Existing' } });

    const res = await request(app)
      .post('/api/users')
      .send({ email: 'test@example.com', name: 'New' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('email');
  });
});
```

### E2E Tests (Playwright)
Test full user flows in browser.

```typescript
import { test, expect } from '@playwright/test';

test.describe('User Authentication', () => {
  test('user can sign up and log in', async ({ page }) => {
    // Sign up
    await page.goto('/sign-up');
    await page.getByLabel('Email').fill('newuser@example.com');
    await page.getByLabel('Password').fill('securepassword123');
    await page.getByRole('button', { name: /sign up/i }).click();
    
    // Verify redirect to dashboard
    await expect(page).toHaveURL('/dashboard');
    await expect(page.getByText(/welcome/i)).toBeVisible();
    
    // Log out
    await page.getByRole('button', { name: /profile/i }).click();
    await page.getByText(/log out/i).click();
    
    // Log back in
    await page.goto('/sign-in');
    await page.getByLabel('Email').fill('newuser@example.com');
    await page.getByLabel('Password').fill('securepassword123');
    await page.getByRole('button', { name: /sign in/i }).click();
    
    await expect(page).toHaveURL('/dashboard');
  });
});
```

## Test Patterns

### TDD Pattern (Write Test First)

1. Write failing test
2. Write minimum code to pass
3. Refactor

```typescript
// Step 1: Write failing test
it('validates email format', () => {
  expect(isValidEmail('invalid')).toBe(false);
  expect(isValidEmail('test@example.com')).toBe(true);
});

// Step 2: Implement
function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// Step 3: Test passes!
```

### Arrange-Act-Assert

```typescript
it('adds item to cart', () => {
  // Arrange
  const cart = new Cart();
  const item = { id: '1', name: 'Widget', price: 10 };

  // Act
  cart.addItem(item);

  // Assert
  expect(cart.items).toHaveLength(1);
  expect(cart.total).toBe(10);
});
```

### Test Data Builders

```typescript
// Factory for test data
function createTestUser(overrides = {}) {
  return {
    id: 'user-1',
    email: 'test@example.com',
    name: 'Test User',
    createdAt: new Date(),
    ...overrides,
  };
}

it('displays user name', () => {
  const user = createTestUser({ name: 'Alice' });
  render(<UserCard user={user} />);
  expect(screen.getByText('Alice')).toBeInTheDocument();
});
```

## Coverage Targets

| Type | Target |
|------|--------|
| Statements | 80% |
| Branches | 75% |
| Functions | 80% |
| Lines | 80% |

Critical paths (auth, payments): 100%

## Output

Tests should be placed alongside code:

```
src/
├── components/
│   ├── Button.tsx
│   └── Button.test.tsx    # Component test
├── lib/
│   ├── utils.ts
│   └── utils.test.ts      # Unit test
└── app/
    └── api/
        └── users/
            ├── route.ts
            └── route.test.ts  # Integration test

e2e/
└── auth.spec.ts           # E2E test
```
