# Web Dev Team — Tools Setup

## Required Tools

### Core

| Tool | Purpose | Install |
|------|---------|---------|
| Node.js 20+ | Runtime | `brew install node` |
| Git | Version control | `brew install git` |
| GitHub CLI | PR management | `brew install gh` |

### Deployment

| Tool | Purpose | Install |
|------|---------|---------|
| Vercel CLI | Deploy Next.js | `npm i -g vercel` |

### Database

| Tool | Purpose | Install |
|------|---------|---------|
| Prisma CLI | Schema management | `npm i -D prisma` |
| PostgreSQL | Local database | `brew install postgresql` |

### Testing

| Tool | Purpose | Install |
|------|---------|---------|
| Vitest | Unit tests | `npm i -D vitest` |
| Playwright | E2E tests | `npm i -D @playwright/test` |

## Environment Variables

Copy `.env.example` to `.env.local` and configure:

```bash
# Database
DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"

# Auth (Clerk)
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_...
CLERK_SECRET_KEY=sk_test_...

# Payments (Stripe)
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_...

# Deployment
VERCEL_TOKEN=...
VERCEL_ORG_ID=...
VERCEL_PROJECT_ID=...

# Monitoring
SENTRY_DSN=...
SENTRY_AUTH_TOKEN=...
```

## GitHub CLI Setup

```bash
# Authenticate
gh auth login

# Verify
gh auth status
```

## Vercel Setup

```bash
# Login
vercel login

# Link project
vercel link

# Get project IDs for CI
vercel project ls
```

## Database Setup

```bash
# Start local Postgres
brew services start postgresql

# Create database
createdb myapp_dev

# Apply migrations
npx prisma migrate dev

# Seed data (if available)
npx prisma db seed
```

## Running Tests

```bash
# Unit tests
npm run test

# Unit tests with coverage
npm run test -- --coverage

# E2E tests
npm run test:e2e

# E2E tests with UI
npm run test:e2e -- --ui
```

## Common Commands

```bash
# Development
npm run dev           # Start dev server
npm run build         # Build for production
npm run lint          # Run linter
npm run typecheck     # Type checking

# Database
npx prisma studio     # Visual editor
npx prisma generate   # Generate client
npx prisma migrate dev --name {name}  # Create migration

# Git
gh pr create          # Create PR
gh pr view            # View current PR
gh pr merge           # Merge PR

# Deploy
vercel                # Deploy preview
vercel --prod         # Deploy production
```

## Troubleshooting

### "Cannot find module" errors

```bash
rm -rf node_modules
npm install
```

### Database connection issues

```bash
# Check if Postgres is running
brew services list

# Restart Postgres
brew services restart postgresql
```

### Prisma client out of sync

```bash
npx prisma generate
```

### Vercel deployment fails

```bash
# Check build locally
npm run build

# Check logs
vercel logs
```
