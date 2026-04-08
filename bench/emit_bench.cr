require "./bench_helper"

puts "=== Emit Benchmarks ==="

# Pre-parse fixtures into document trees for re-emission benchmarks
emit_fixtures = {
  "flat_mapping"     => BenchHelper.fixture("flat_mapping"),
  "nested"           => BenchHelper.fixture("nested"),
  "flow_collections" => BenchHelper.fixture("flow_collections"),
  "block_scalars"    => BenchHelper.fixture("block_scalars"),
  "large_config"     => BenchHelper.fixture("large_config"),
}

documents = {} of String => Yaml::Nodes::Document
emit_fixtures.each do |name, yaml|
  documents[name] = Yaml::Nodes::Parser.new(yaml).parse
end

puts "\n--- IPS: Builder.build (programmatic construction) ---"
Benchmark.ips do |x|
  x.report("build flat mapping (100)") do
    Yaml::Builder.build do |b|
      b.mapping do
        100.times do |i|
          b.scalar("key_#{i}")
          b.scalar("value_#{i}")
        end
      end
    end
  end

  x.report("build nested (5 levels)") do
    Yaml::Builder.build do |b|
      5.times do
        b.mapping do
          4.times do |i|
            b.scalar("key_#{i}")
            b.sequence do
              3.times { |j| b.scalar("val_#{j}") }
            end
          end
        end
      end
    end
  end

  x.report("build flow sequences (50)") do
    Yaml::Builder.build do |b|
      b.mapping do
        50.times do |i|
          b.scalar("seq_#{i}")
          b.sequence(style: Yaml::SequenceStyle::FLOW) do
            5.times { |j| b.scalar("item_#{j}") }
          end
        end
      end
    end
  end
end

BenchHelper.memory_section("Builder.build (programmatic construction)") do
  BenchHelper.memory_report("build flat mapping (100)") do
    Yaml::Builder.build do |b|
      b.mapping do
        100.times do |i|
          b.scalar("key_#{i}")
          b.scalar("value_#{i}")
        end
      end
    end
  end

  BenchHelper.memory_report("build nested (5 levels)") do
    Yaml::Builder.build do |b|
      5.times do
        b.mapping do
          4.times do |i|
            b.scalar("key_#{i}")
            b.sequence do
              3.times { |j| b.scalar("val_#{j}") }
            end
          end
        end
      end
    end
  end
end

puts "\n--- IPS: Re-emit parsed documents (Node#to_yaml) ---"
Benchmark.ips do |x|
  documents.each do |name, doc|
    x.report("emit #{name}") do
      Yaml::Builder.build do |b|
        doc.nodes.each &.to_yaml(b)
      end
    end
  end
end

BenchHelper.memory_section("Re-emit parsed documents (Node#to_yaml)") do
  documents.each do |name, doc|
    BenchHelper.memory_report("emit #{name}") do
      Yaml::Builder.build do |b|
        doc.nodes.each &.to_yaml(b)
      end
    end
  end
end
