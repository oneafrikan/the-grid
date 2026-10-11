# laravel

Laravel conventions from the official documentation (12.x): configuration, Eloquent, migrations, queued jobs, validation and authorization. Written fresh, not adapted from another rule set.

Path scope is by Laravel directory (`app/`, `routes/`, `app/Models/`, `database/migrations/`, `app/Jobs/`, `app/Http/`), one topic per file. These files also load alongside the `php` pack. Files outside those directories (for example `config/`, `database/factories/`, Blade views and `bootstrap/app.php`) match no rule file here; a `config/` or `bootstrap/` edit gets only the `php` pack.

## Sources

| Rule file | Source |
|---|---|
| structure.md | https://laravel.com/docs/12.x/configuration https://laravel.com/docs/12.x/eloquent https://laravel.com/docs/12.x/eloquent-relationships |
| eloquent.md | https://laravel.com/docs/12.x/eloquent https://laravel.com/docs/12.x/eloquent-relationships |
| migrations.md | https://laravel.com/docs/12.x/migrations |
| queues.md | https://laravel.com/docs/12.x/queues |
| security.md | https://laravel.com/docs/12.x/validation https://laravel.com/docs/12.x/authorization https://laravel.com/docs/12.x/queries https://laravel.com/docs/12.x/csrf |
