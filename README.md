# yaml

A pure Crystal YAML 1.1 parser and emitter. No C dependencies — no libyaml, no FFI.

The API mirrors Crystal's stdlib `YAML::PullParser` and `YAML::Builder`, so switching from the stdlib is straightforward. The module is named `Yaml` (not `YAML`) to coexist with the stdlib without conflict.

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
parser = Yaml::PullParser.new("name: Crystal\nversion: 1.19")

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
  parser = Yaml::PullParser.new(file)
  # ...
end
```

**Nodes::Parser** builds a DOM tree:

```crystal
doc = Yaml::Nodes::Parser.new("users:\n- Alice\n- Bob").parse
root = doc.nodes[0].as(Yaml::Nodes::Mapping)

key = root.nodes[0].as(Yaml::Nodes::Scalar)
key.value # => "users"

seq = root.nodes[1].as(Yaml::Nodes::Sequence)
seq.nodes.size # => 2
```

### Emitting

**Builder** generates YAML text:

```crystal
yaml = Yaml::Builder.build do |builder|
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
yaml = Yaml::Builder.build do |builder|
  builder.mapping(style: Yaml::MappingStyle::FLOW) do
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
builder.scalar("has\nnewlines", style: Yaml::ScalarStyle::LITERAL)
```

### Anchors and aliases

```crystal
parser = Yaml::PullParser.new("- &default config\n- *default")
parser.read_stream do
  parser.read_document do
    parser.read_sequence do
      parser.anchor # => "default"
      parser.value  # => "config"
      parser.read_next

      parser.kind   # => Yaml::EventKind::ALIAS
      parser.anchor # => "default"
      parser.read_next
    end
  end
end
```

### Tags

Standard YAML tag shorthands (`!!str`, `!!int`, etc.) are resolved automatically:

```crystal
parser = Yaml::PullParser.new("!!str 42")
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
