require "benchmark"
require "../src/yaml"
require "./generate_fixtures"

fixtures = {
  "trivial"          => BenchFixtures.trivial,
  "flat_mapping"     => BenchFixtures.flat_mapping,
  "nested"           => BenchFixtures.nested,
  "flow_collections" => BenchFixtures.flow_collections,
  "block_scalars"    => BenchFixtures.block_scalars,
  "strings_heavy"    => BenchFixtures.strings_heavy,
  "large_config"     => BenchFixtures.large_config,
}

fixtures.each do |name, yaml|
  # Warmup
  3.times { YAML::Nodes::Parser.new(yaml).parse }

  elapsed = Time.measure do
    100.times { YAML::Nodes::Parser.new(yaml).parse }
  end
  ips = 100.0 / elapsed.total_seconds
  mem = Benchmark.memory { YAML::Nodes::Parser.new(yaml).parse }
  puts "#{name}\t#{ips}\t#{mem}\t#{yaml.bytesize}"
end
