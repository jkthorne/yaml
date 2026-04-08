require "benchmark"
require "yaml"
require "../src/yaml"
require "./generate_fixtures"

puts "=== Comparison: Pure Crystal (Yaml) vs stdlib (YAML/libyaml) ==="

fixtures = {
  "trivial"          => BenchFixtures.trivial,
  "flat_mapping"     => BenchFixtures.flat_mapping,
  "nested"           => BenchFixtures.nested,
  "flow_collections" => BenchFixtures.flow_collections,
  "block_scalars"    => BenchFixtures.block_scalars,
  "strings_heavy"    => BenchFixtures.strings_heavy,
  "large_config"     => BenchFixtures.large_config,
}

puts "\nFixture sizes:"
fixtures.each do |name, yaml|
  puts "  #{name}: #{yaml.bytesize} bytes"
end

puts "\n--- IPS: Parse comparison ---"
fixtures.each do |name, yaml|
  puts "\n  [#{name}]"
  Benchmark.ips do |x|
    x.report("stdlib YAML.parse") { YAML.parse(yaml) }
    x.report("pure Yaml parse")   { Yaml::Nodes::Parser.new(yaml).parse }
  end
end

puts "\n--- Memory: Parse comparison ---"
fixtures.each do |name, yaml|
  puts "\n  [#{name}]"
  stdlib_mem = Benchmark.memory { YAML.parse(yaml) }
  pure_mem = Benchmark.memory { Yaml::Nodes::Parser.new(yaml).parse }

  format = ->(bytes : Int64) {
    if bytes >= 1_048_576
      "#{(bytes / 1_048_576.0).round(2)} MiB"
    elsif bytes >= 1024
      "#{(bytes / 1024.0).round(2)} KiB"
    else
      "#{bytes} B"
    end
  }

  puts "    stdlib YAML.parse: #{format.call(stdlib_mem)}"
  puts "    pure Yaml parse:   #{format.call(pure_mem)}"
  if pure_mem > 0 && stdlib_mem > 0
    ratio = pure_mem.to_f / stdlib_mem
    puts "    ratio: #{ratio.round(2)}x"
  end
end
