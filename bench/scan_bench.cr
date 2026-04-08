require "./bench_helper"

puts "=== Scanner Benchmarks ==="

scan_fixtures = {
  "flat_mapping"     => BenchHelper.fixture("flat_mapping"),
  "nested"           => BenchHelper.fixture("nested"),
  "flow_collections" => BenchHelper.fixture("flow_collections"),
  "block_scalars"    => BenchHelper.fixture("block_scalars"),
  "strings_heavy"    => BenchHelper.fixture("strings_heavy"),
  "large_config"     => BenchHelper.fixture("large_config"),
}

puts "\n--- IPS: Scanner (consume all tokens) ---"
Benchmark.ips do |x|
  scan_fixtures.each do |name, yaml|
    x.report("scan #{name}") do
      scanner = YAML::Scanner.new(yaml)
      loop do
        token = scanner.scan
        break if token.kind == YAML::TokenKind::STREAM_END
      end
    end
  end
end

BenchHelper.memory_section("Scanner (consume all tokens)") do
  scan_fixtures.each do |name, yaml|
    BenchHelper.memory_report("scan #{name}") do
      scanner = YAML::Scanner.new(yaml)
      loop do
        token = scanner.scan
        break if token.kind == YAML::TokenKind::STREAM_END
      end
    end
  end
end
