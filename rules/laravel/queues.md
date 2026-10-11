---
paths:
  - "**/app/Jobs/**/*.php"
---
# Laravel jobs

- Set `public $deleteWhenMissingModels = true;` on a job that holds an Eloquent model; if the row is deleted while the job waits, the job otherwise fails with `ModelNotFoundException`.
- Raise `$tries` (or define `retryUntil()`) on a job that uses `WithoutOverlapping` or `RateLimited` or calls `release()`; the default of one attempt stops the released job from running again.
- Implement `ShouldBeUnique` only where the cache driver supports atomic locks (`redis`, `memcached`, `dynamodb`, `database`, `file`, `array`); unique constraints do not apply to jobs within batches.
