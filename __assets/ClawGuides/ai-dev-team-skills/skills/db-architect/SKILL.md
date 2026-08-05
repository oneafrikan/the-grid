# Database Architect Skill

You design database schemas and migrations.

## Invocation

```
/db_architect {feature or data model}
```

## Process

### 1. Understand Data Requirements

- What entities exist?
- What are the relationships?
- What queries will be common?
- What's the expected scale?

### 2. Design Schema

#### Prisma Schema Format

```prisma
// prisma/schema.prisma

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

// ============================================
// USER DOMAIN
// ============================================

model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String
  role      Role     @default(USER)
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  // Relations
  preferences UserPreferences?
  sessions    Session[]
  orders      Order[]

  @@index([email])
  @@index([createdAt])
}

model UserPreferences {
  id                 String   @id @default(cuid())
  userId             String   @unique
  user               User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  
  theme              String   @default("system")
  emailNotifications Boolean  @default(true)
  weeklyReports      Boolean  @default(false)
  
  createdAt          DateTime @default(now())
  updatedAt          DateTime @updatedAt
}

enum Role {
  USER
  ADMIN
  MODERATOR
}

// ============================================
// AUTH DOMAIN
// ============================================

model Session {
  id        String   @id @default(cuid())
  userId    String
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  
  token     String   @unique
  expiresAt DateTime
  ipAddress String?
  userAgent String?
  
  createdAt DateTime @default(now())

  @@index([token])
  @@index([userId])
  @@index([expiresAt])
}

// ============================================
// BUSINESS DOMAIN
// ============================================

model Order {
  id          String      @id @default(cuid())
  userId      String
  user        User        @relation(fields: [userId], references: [id])
  
  status      OrderStatus @default(PENDING)
  totalCents  Int
  currency    String      @default("USD")
  
  items       OrderItem[]
  
  createdAt   DateTime    @default(now())
  updatedAt   DateTime    @updatedAt

  @@index([userId])
  @@index([status])
  @@index([createdAt])
}

model OrderItem {
  id        String @id @default(cuid())
  orderId   String
  order     Order  @relation(fields: [orderId], references: [id], onDelete: Cascade)
  
  productId String
  quantity  Int
  unitCents Int
  
  @@index([orderId])
}

enum OrderStatus {
  PENDING
  PROCESSING
  SHIPPED
  DELIVERED
  CANCELLED
}
```

### 3. Generate Migration

```bash
# Create migration from schema changes
npx prisma migrate dev --name add_user_preferences

# Review the generated SQL
cat prisma/migrations/*/migration.sql
```

### 4. Document Decisions

```markdown
# Database Design: {Feature}

## Entities
- **User**: Core user account
- **UserPreferences**: User settings (1:1)
- **Order**: Purchase record (1:many)

## Key Decisions

### Why cuid() over uuid?
- Shorter (25 chars vs 36)
- URL-safe
- Sortable by creation time

### Why separate UserPreferences?
- Keeps User table lean
- Preferences change frequently
- Easy to add new preference fields

### Indexes
- `email` for login lookup
- `createdAt` for sorting
- `status` for filtering active orders

## Queries Optimized For
- Get user by email (login)
- List user's orders (dashboard)
- Count orders by status (admin)
```

## Schema Patterns

### Soft Delete
```prisma
model Post {
  id        String    @id @default(cuid())
  deletedAt DateTime?

  @@index([deletedAt])
}
```

### Timestamps
```prisma
model Entity {
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
}
```

### Polymorphic Relations
```prisma
model Comment {
  id            String  @id @default(cuid())
  content       String
  
  // Polymorphic
  targetType    String  // "post" | "product"
  targetId      String
  
  @@index([targetType, targetId])
}
```

### Many-to-Many
```prisma
model Post {
  id   String @id
  tags Tag[]
}

model Tag {
  id    String @id
  posts Post[]
}
```

### JSON Fields (when appropriate)
```prisma
model Product {
  id         String @id
  attributes Json   // Flexible schema
}
```

## Migration Safety

### Before Production Migration

1. **Backup database**
2. **Test on staging first**
3. **Check for data loss**
4. **Plan rollback**

### Safe Migration Patterns

```sql
-- Add nullable column (safe)
ALTER TABLE users ADD COLUMN bio TEXT;

-- Add column with default (safe)
ALTER TABLE users ADD COLUMN is_active BOOLEAN DEFAULT true;

-- Rename column (dangerous - coordinate with code)
-- 1. Add new column
-- 2. Backfill data
-- 3. Update code to use new column
-- 4. Drop old column

-- Delete column (dangerous)
-- 1. Remove code references first
-- 2. Deploy code
-- 3. Then drop column
```

## Output

- Schema: `prisma/schema.prisma`
- Design docs: `output/{project}/architecture/database-design.md`
- ERD: Generate with `npx prisma-erd-generator`
