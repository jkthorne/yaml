# yaml

A pure Crystal YAML 1.1 parser and emitter. No C dependencies — no libyaml, no FFI.

This is a pure Crystal replacement for Crystal's stdlib YAML module (which wraps libyaml). The API mirrors the stdlib's `YAML::PullParser` and `YAML::Builder`, so switching is straightforward. Do not require both this shard and Crystal's stdlib `yaml` in the same program.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  yaml:
    github: jackthorne/yaml
```

Then run `shards install`.

## Usage

```crystal
require "yaml"
```

### Parsing

**PullParser** provides SAX-style event-driven parsing:

```crystal
parser = YAML::PullParser.new("name: Crystal\nversion: 1.19")

parser.read_stream do
  parser.read_document do
    parser.read_mapping do
      key = parser.read_scalar   # => "name"
      value = parser.read_scalar # => "Crystal"
      key = parser.read_scalar   # => "version"
      value = parser.read_scalar # => "1.19"
    end
  end
end
```

Works with `IO` too:

```crystal
File.open("config.yml") do |file|
  parser = YAML::PullParser.new(file)
  # ...
end
```

**Nodes::Parser** builds a DOM tree:

```crystal
doc = YAML::Nodes::Parser.new("users:\n- Alice\n- Bob").parse
root = doc.nodes[0].as(YAML::Nodes::Mapping)

key = root.nodes[0].as(YAML::Nodes::Scalar)
key.value # => "users"

seq = root.nodes[1].as(YAML::Nodes::Sequence)
seq.nodes.size # => 2
```

### Emitting

**Builder** generates YAML text:

```crystal
yaml = YAML::Builder.build do |builder|
  builder.mapping do
    builder.scalar("name")
    builder.scalar("my-app")
    builder.scalar("dependencies")
    builder.sequence do
      builder.scalar("pg")
      builder.scalar("redis")
    end
  end
end

puts yaml
# --- 
# name: my-app
# dependencies:
# - pg
# - redis
# ...
```

Flow style collections:

```crystal
yaml = YAML::Builder.build do |builder|
  builder.mapping(style: YAML::MappingStyle::FLOW) do
    builder.scalar("a")
    builder.scalar("1")
  end
end
# {a: 1}
```

### Scalar styles

The parser preserves and the builder accepts all five YAML scalar styles:

| Style | Syntax | Example |
|---|---|---|
| `PLAIN` | unquoted | `hello` |
| `SINGLE_QUOTED` | `'...'` | `'it''s'` |
| `DOUBLE_QUOTED` | `"..."` | `"line\nbreak"` |
| `LITERAL` | `\|` | preserves newlines exactly |
| `FOLDED` | `>` | folds newlines to spaces |

```crystal
builder.scalar("has\nnewlines", style: YAML::ScalarStyle::LITERAL)
```

### Anchors and aliases

```crystal
parser = YAML::PullParser.new("- &default config\n- *default")
parser.read_stream do
  parser.read_document do
    parser.read_sequence do
      parser.anchor # => "default"
      parser.value  # => "config"
      parser.read_next

      parser.kind   # => YAML::EventKind::ALIAS
      parser.anchor # => "default"
      parser.read_next
    end
  end
end
```

### Tags

Standard YAML tag shorthands (`!!str`, `!!int`, etc.) are resolved automatically:

```crystal
parser = YAML::PullParser.new("!!str 42")
# parser.tag => "tag:yaml.org,2002:str"
# parser.value => "42"
```

## Architecture

The processing pipeline follows libyaml's design:

```
Bytes --> Reader --> Scanner --> Parser --> PullParser
                    (tokens)   (events)   (high-level API)

Events --> Emitter --> Builder --> IO/String
           (text)     (high-level API)

Events --> Nodes::Parser --> Document tree
```

| Component | File | Lines | Role |
|---|---|---|---|
| Reader | `reader.cr` | ~180 | UTF-8 input with lookahead and position tracking |
| Scanner | `scanner.cr` | ~1,250 | Tokenizer: indent tracking, simple keys, scalar styles |
| Parser | `parser.cr` | ~730 | 24-state machine: tokens to events |
| PullParser | `pull_parser.cr` | ~210 | High-level parse API |
| Emitter | `emitter.cr` | ~880 | Events to YAML text with style analysis |
| Builder | `builder.cr` | ~160 | High-level emit API |
| Nodes | `nodes/` | ~300 | DOM tree: Scalar, Sequence, Mapping, Alias |

## What's supported

- All five scalar styles (plain, single-quoted, double-quoted, literal block, folded block)
- Block and flow collections (sequences and mappings)
- Anchors and aliases
- Tags (primary `!`, secondary `!!`, named `!handle!`, verbatim `!<uri>`)
- Directives (`%YAML`, `%TAG`)
- Multiple documents (`---` / `...`)
- BOM detection
- Multiline plain scalar folding
- Escape sequences in double-quoted scalars (`\n`, `\t`, `\xNN`, `\uNNNN`, `\UNNNNNNNN`)
- Nested structures of arbitrary depth

## Limitations

- YAML 1.1 only (1.2 differences like `0o` octal prefix and restricted booleans are not yet implemented)
- UTF-8 input only (UTF-16 detection is recognized but not decoded)
- No schema/type resolution (scalars are always strings — apply your own schema layer)
- Simple key limit of 1024 characters (matching libyaml)

## Performance

Comparison against Crystal's stdlib YAML (which wraps libyaml, a C library). Measured with `Benchmark.ips` on Crystal 1.19, `--release` mode. Ratio > 1.0x means pure Crystal is faster.

| Fixture | Size | stdlib (libyaml) | pure Crystal | Ratio | Memory (stdlib) | Memory (pure) |
|---|---|---|---|---|---|---|
| trivial | 11 B | 333k ips | 429k ips | **1.29x** | 640 B | 0 B |
| flat_mapping | 1.7 KB | 12.0k ips | 12.4k ips | **1.03x** | 29.7 KiB | 46.2 KiB |
| flow_collections | 4.8 KB | 4.7k ips | 5.2k ips | **1.12x** | 71.5 KiB | 78.1 KiB |
| nested | 32 KB | 1.02k ips | 989 ips | 0.97x | 200.8 KiB | 497.5 KiB |
| block_scalars | 1.6 KB | 28.9k ips | 24.5k ips | 0.85x | 8.8 KiB | 16.2 KiB |
| strings_heavy | 6.9 KB | 8.9k ips | 5.2k ips | 0.59x | 49.7 KiB | 57.5 KiB |
| large_config | 49 KB | 727 ips | 656 ips | 0.90x | 520.4 KiB | 787.6 KiB |

**Summary:** Competitive with libyaml on small-to-medium inputs (up to ~1.3x faster), with some overhead on large documents and string-heavy workloads. The pure Crystal implementation avoids all C/FFI overhead and allocates zero bytes for trivial inputs.

### Running benchmarks

```sh
bash bench/run.sh                             # full suite
bash bench/compare.sh                         # vs stdlib (libyaml)
crystal run --release bench/parse_bench.cr    # parsing only
crystal run --release bench/scan_bench.cr     # tokenizer only
crystal run --release bench/emit_bench.cr     # emitter only
crystal run --release bench/roundtrip_bench.cr # parse → emit → parse
```

The comparison benchmark compiles two separate binaries (one using this library, one using stdlib) since they cannot coexist in the same program.

## Development

```sh
crystal spec     # run tests
crystal build src/yaml.cr --no-codegen  # type-check without codegen
```

## Contributing

1. Fork it (<https://github.com/jackthorne/yaml/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

MIT - see [LICENSE](LICENSE).
