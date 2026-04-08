require "./bench_helper"

puts "=== Round-trip Benchmarks (parse → emit → parse) ==="

rt_fixtures = {
  "flat_mapping"     => BenchHelper.fixture("flat_mapping"),
  "nested"           => BenchHelper.fixture("nested"),
  "flow_collections" => BenchHelper.fixture("flow_collections"),
  "block_scalars"    => BenchHelper.fixture("block_scalars"),
  "anchors_aliases"  => BenchHelper.fixture("anchors_aliases"),
  "large_config"     => BenchHelper.fixture("large_config"),
}

puts "\n--- IPS: Full round-trip ---"
Benchmark.ips do |x|
  rt_fixtures.each do |name, yaml|
    x.report("roundtrip #{name}") do
      doc = YAML::Nodes::Parser.new(yaml).parse
      emitted = YAML::Builder.build do |b|
        doc.nodes.each &.to_yaml(b)
      end
      YAML::Nodes::Parser.new(emitted).parse
    end
  end
end

BenchHelper.memory_section("Full round-trip") do
  rt_fixtures.each do |name, yaml|
    BenchHelper.memory_report("roundtrip #{name}") do
      doc = YAML::Nodes::Parser.new(yaml).parse
      emitted = YAML::Builder.build do |b|
        doc.nodes.each &.to_yaml(b)
      end
      YAML::Nodes::Parser.new(emitted).parse
    end
  end
end
