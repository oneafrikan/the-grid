---
paths:
  - "**/app/Jobs/**/*.php"
---
# Laravel jobs

- A job holding an Eloquent model fails with `ModelNotFoundException` if the row is deleted while it waits; `public $deleteWhenMissingModels = true;` makes Laravel quietly discard the job without raising an exception.
- Raise `$tries` (or define `retryUntil()`) on a job that uses `WithoutOverlapping` or `RateLimited` or calls `release()`; the default of one attempt stops the released job from running again.
- Implement `ShouldBeUnique` only where the cache driver supports atomic locks (`redis`, `memcached`, `dynamodb`, `database`, `file`, `array`); unique constraints do not apply to jobs within batches.
