---
name: ruby
description: Ruby skills bundle. Contains Ruby-oriented SOLID, TDD, clean code, Ruby Style Guide, and RSpec/Better Specs. Use when working with Ruby code.
---

# Ruby Skills

This directory holds **Ruby-specific** skills. All examples and references use Ruby (and RSpec where tests are shown). This project is a gem (no Rails).

## Available skills

- **solid** — SOLID principles, TDD, clean code, design patterns, architecture. Path: `ruby/solid/`
- **style** — [Ruby Style Guide](https://rubystyle.guide/) conventions (layout, naming, flow of control, methods, classes). Path: `ruby/style/`
- **rspec** — RSpec style and best practices from the [RSpec Style Guide](https://rspec.rubystyle.guide/) and [Better Specs](https://www.betterspecs.org/). Path: `ruby/rspec/`

Use **solid** when designing/refactoring Ruby; **style** for Ruby formatting; **rspec** when writing or reviewing specs.

---

## Using these skills for code review

When the user asks to **review code** or **fix issues** against Ruby/RSpec standards:

1. **Apply the right skills** based on what's being reviewed:
   - **Ruby code (any)** → apply **style** (Ruby Style Guide) and **solid** (SOLID, clean code, design).
   - **RSpec specs** → apply **rspec** (RSpec Style Guide + Better Specs) for layout, structure, naming, matchers, doubles.

2. **Review workflow:**
   - Read the file(s) the user opened or specified.
   - Check against the relevant skill(s): layout, naming, structure, patterns, conventions.
   - List **concrete issues** with file:line or snippet and which guideline they violate.
   - Group by category (style, rspec, solid) if helpful.
   - Then **propose or apply fixes** per issue (or batch); prefer one logical change per edit.

3. **Fixing issues:**
   - Fix one concern at a time where possible (e.g. style first, then RSpec, then solid).
   - For automated style/safety, suggest running **RuboCop** (and `rubocop-rspec` if present) and fixing reported offenses.

4. **Prompt ideas for the user:**
   - "Review this file using the Ruby skills and list issues."
   - "Check this spec against the RSpec skill and fix any violations."
   - "Review the lib directory against solid, style, and rspec skills; then fix the issues you find."
