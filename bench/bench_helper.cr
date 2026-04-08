require "benchmark"
require "../src/yaml"
require "./generate_fixtures"

module BenchHelper
  FIXTURES = {
    "trivial"          => BenchFixtures.trivial,
    "flat_mapping"     => BenchFixtures.flat_mapping,
    "nested"           => BenchFixtures.nested,
    "flow_collections" => BenchFixtures.flow_collections,
    "block_scalars"    => BenchFixtures.block_scalars,
    "anchors_aliases"  => BenchFixtures.anchors_aliases,
    "multi_document"   => BenchFixtures.multi_document,
    "large_config"     => BenchFixtures.large_config,
    "strings_heavy"    => BenchFixtures.strings_heavy,
  }

  def self.fixture(name : String) : String
    FIXTURES[name]
  end

  def self.validate!
    FIXTURES.each do |name, yaml|
      Yaml::Nodes::Parser.new(yaml).parse
      print "  ✓ #{name} (#{yaml.bytesize} bytes)\n"
    end
  end

  def self.memory_section(title : String, &)
    puts "\n--- Memory: #{title} ---"
    yield
    puts ""
  end

  def self.memory_report(label : String, &block)
    bytes = Benchmark.memory { block.call }
    if bytes >= 1_048_576
      puts "  #{label}: #{(bytes / 1_048_576.0).round(2)} MiB"
    elsif bytes >= 1024
      puts "  #{label}: #{(bytes / 1024.0).round(2)} KiB"
    else
      puts "  #{label}: #{bytes} B"
    end
  end
end
