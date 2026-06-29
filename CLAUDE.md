# Project notes

## Testing

- **Use Minitest, not RSpec.** Tests live in `test/`, files named `*_test.rb`,
  classes inherit from `Minitest::Test`. Run with `rake test` or
  `ruby -Ilib -Itest test/<file>_test.rb`.
- Test helper: `test/test_helper.rb` (sets `$LOAD_PATH` and requires
  `minitest/autorun` + `amplitude`).
- Use WebMock for HTTP stubbing. Redis sink tests should be gated on a
  `REDIS_URL` env var and skipped otherwise.

## Ruby

- Target Ruby 3.0+ (`.ruby-version` pins 3.4.4).
- **Prefer endless `def` for single-expression methods.** Available since
  Ruby 3.0 (stabilised in 3.1) and the gem targets 3.0+.
  - Good fit: simple readers / delegators / one-line predicates / aliases.
    `def size = @count`, `def valid? = !empty?`, `def stop = flush`,
    `def with_redis(&b) = @pool.with(&b)`.
  - Skip when the body needs `begin/rescue`, mutation across multiple lines,
    or a `yield` block where the classic form is more readable.
  - For methods that genuinely do nothing, use `def foo = nil` instead of
    `def foo; end` — keeps it on one line and explicit.

## Layout

See `llm/plans/port-plan.md` for the SDK port plan and design rationale.
