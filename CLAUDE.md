# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pure Crystal YAML 1.1 parser and emitter with no C dependencies (no libyaml, no FFI). The module is named `Yaml` (not `YAML`) to coexist with Crystal's stdlib. Requires Crystal >= 1.19.1.

## Commands

```bash
# Run all tests
crystal spec

# Run a single test file
crystal spec spec/yaml_spec.cr

# Run a specific test by line number
crystal spec spec/yaml_spec.cr:42

# Type-check without compiling
crystal build src/yaml.cr --no-codegen

# Run benchmarks (release mode)
bash bench/run.sh

# Run a single benchmark
crystal run --release bench/scan_bench.cr
```

## Architecture

### Parsing Pipeline

```
Input (String|IO) → Scanner → EventParser → PullParser → Nodes::Parser
                   (tokens)    (events)     (SAX API)     (DOM tree)
```

- **Scanner** (`scanner.cr`, 1667 LOC) — The largest component. Handles tokenization, indent tracking, all five scalar styles, flow/block context, simple key management, BOM detection, and UTF-16 transcoding. Reader functionality is inlined directly (no separate Reader class) for performance.
- **EventParser** (`parser.cr`) — 24-state machine converting tokens to events. States handle block/flow sequences, mappings, documents, and directives.
- **PullParser** (`pull_parser.cr`) — Public SAX-style API with `read_stream`/`read_document`/`read_mapping`/`read_sequence`/`read_scalar` convenience methods.
- **Nodes::Parser** (`nodes/parser.cr`) — Builds a DOM tree (`Document` containing `Scalar`/`Sequence`/`Mapping`/`Alias` nodes) from PullParser events. Resolves anchors via a hash map.

### Emission Pipeline

```
Builder (high-level API) → Emitter (state machine) → IO
```

- **Builder** (`builder.cr`) — Fluent API: `Builder.build { |b| b.mapping { b.scalar("key"); b.scalar("value") } }`. Wraps Emitter with event construction.
- **Emitter** (`emitter.cr`, 878 LOC) — 17-state machine converting events to YAML text. Handles style selection, scalar analysis, indentation, and event buffering for look-ahead.

### Key Types

- **Token** (`token.cr`) — `struct` (value type, no heap allocation). Carries `kind`, `start_mark`, `end_mark`, plus fields for scalar value/style, tag handle/suffix, directive version.
- **Event** (`event.cr`) — Intermediate between parser and consumer. Carries kind, marks, anchor, tag, value, styles, directives.
- **Mark** (`mark.cr`) — Position tracking: `index` (byte), `line`, `column` (both 0-based).

### Performance Design

- Scanner works at byte level for ASCII structural characters, only decoding UTF-8 for scalar content
- Plain scalar fast path extracts buffer substrings directly (string input only, single-line ASCII)
- Anchor/alias/directive names use byte-level scanning with `byte_slice` instead of `String.build`
- Token is a struct to avoid heap allocation per token

## Testing

- `yaml_spec.cr` — Core PullParser and Builder tests
- `integration_spec.cr` — Round-trip parsing, real-world YAML structures
- `error_context_spec.cr` — Error messages with context and source snippets
- `reader_spec.cr` — Scanner's peek/advance/mark/UTF-8 handling (tests Scanner directly)
- `utf16_spec.cr` — BOM detection and UTF-16 transcoding
- `yaml_test_suite_spec.cr` — 355 cases from the official yaml-test-suite submodule, compared via `EventSerializer`

## Commits

When committing, do not include a Co-Authored-By line.

## Limitations

- YAML 1.1 only (not 1.2)
- No schema/type resolution (scalars are always strings)
- Simple keys limited to 1024 characters
