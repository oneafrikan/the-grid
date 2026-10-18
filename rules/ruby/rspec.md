---
paths:
  - "**/spec/**/*.rb"
---
# RSpec

- Use `let!` when an example needs a record to exist without referencing it; `let` is memoized on first call, while `let!` runs its block in an implicit `before` hook.
- In rspec-rails, create database records in `before` (per example), not `before(:context)`; `before(:context)` state is not wrapped in a transaction, so clean it up in `after(:context)`.
