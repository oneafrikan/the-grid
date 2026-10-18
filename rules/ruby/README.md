# ruby

Ruby and Rails hazards: `rescue` and `Hash` pitfalls, injection and deserialization, Rails controller, model and view risks, RSpec behaviour. Adapted from affaan-m/ECC's Ruby rules, then cut to what a cited official source supports.

## Scope

- `style.md` loads on `.rb` and `.rake` files; its bullets are plain Ruby.
- `security.md` loads on `.rb` files. Its Active Record bullet is conditional on the project using Active Record.
- `rails-controllers.md`, `rails-models.md` and `rails-views.md` load on the standard Rails directories (`app/controllers`, `app/models`, `app/views` plus `app/helpers`). Rails is detected by directory layout only: a non-Rails project that has an `app/models/` directory loads them too, and a Rails app that keeps controllers elsewhere does not.
- `rspec.md` loads under `spec/`, RSpec's default directory; a project using another layout is not matched. Minitest is not covered: its only candidate bullet (Rails `use_transactional_tests`) was deleted after review (B8: `test/` also holds non-Rails suites).
- `rails-views.md` loads on `.erb` views only: `.haml`, `.slim` and `.jbuilder` views are not matched.
- `Gemfile`, `*.gemspec`, `config.ru` and `config/` files are not matched; no cited source supports a bullet for them.
- RuboCop configuration and a Ruby or Rails version target are not covered.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://rubystyle.guide/ |
| security.md | https://guides.rubyonrails.org/security.html https://guides.rubyonrails.org/active_record_querying.html https://docs.ruby-lang.org/en/3.4/Marshal.html https://docs.ruby-lang.org/en/3.4/Psych.html |
| rails-controllers.md | https://guides.rubyonrails.org/action_controller_overview.html https://api.rubyonrails.org/classes/ActionController/Redirecting.html https://api.rubyonrails.org/classes/ActionController/DataStreaming.html |
| rails-models.md | https://guides.rubyonrails.org/active_record_validations.html https://guides.rubyonrails.org/active_record_callbacks.html https://guides.rubyonrails.org/active_record_querying.html |
| rails-views.md | https://api.rubyonrails.org/classes/String.html |
| rspec.md | https://rspec.info/documentation/3.13/rspec-core/RSpec/Core/MemoizedHelpers/ClassMethods.html https://rspec.info/documentation/3.13/rspec-core/RSpec/Core/Hooks.html |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/ruby/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | style.md | Kept: the specific-`rescue` topic (rewritten from the Ruby Style Guide). Dropped: the Ruby 3.3+ target, YJIT, the `frozen_string_literal` convention, the RuboCop and `rubocop-rails-omakase` mandate, binstub and `bin/rails` preferences, "keep controllers transport-focused" and service-object advice, the `puts`/`pp`/`debugger` ban, the "See skill" pointer. |
| patterns.md | none | Dropped: "Rails Way first", PostgreSQL, Solid Queue, Sidekiq, Hotwire and Devise recommendations (stack choices, not conventions; no cited source), the "See skill" pointer. |
| security.md | security.md, rails-controllers.md, rails-models.md, rails-views.md | Kept: parameterized SQL, strong parameters, `html_safe` and `raw` as security-sensitive. Dropped: CSRF "keep enabled" (no cited source gives a hazard for a given line of code), the credentials advice, the session rotation, account-recovery and rate-limiting lines, `bundle-audit` and `brakeman` commands (no cited official source), the gem-review advice, file-upload validation, the Rails 8 authentication generator and Devise advice, the "See skill" pointer. Added from the Rails and Ruby documentation: open redirects, `send_file`, `permit!`, `Marshal.load`, YAML, `system`. |
| testing.md | rspec.md | Kept: the RSpec topic. Dropped: the framework-choice rules, the test pyramid, fixtures versus `factory_bot`, SimpleCov and coverage thresholds, "add regression tests before changing code" (a workflow mandate), the command list, the "See skill" pointer. Added from the RSpec documentation: `let!`, `before(:context)`. Minitest is not covered. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not Ruby. |
