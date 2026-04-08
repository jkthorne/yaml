require "./bench_helper"

puts "=== Parse Benchmarks ==="
puts "Validating fixtures..."
BenchHelper.validate!

fixtures = BenchHelper::FIXTURES

puts "\n--- IPS: Nodes::Parser.parse ---"
Benchmark.ips do |x|
  fixtures.each do |name, yaml|
    x.report("parse #{name}") { Yaml::Nodes::Parser.new(yaml).parse }
  end
end

BenchHelper.memory_section("Nodes::Parser.parse") do
  fixtures.each do |name, yaml|
    BenchHelper.memory_report("parse #{name}") { Yaml::Nodes::Parser.new(yaml).parse }
  end
end

puts "\n--- IPS: PullParser (consume all events) ---"
Benchmark.ips do |x|
  fixtures.each do |name, yaml|
    next if name == "multi_document" # PullParser.read_stream handles this differently
    x.report("pull #{name}") do
      parser = Yaml::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          loop do
            case parser.kind
            when .scalar?       then parser.read_next
            when .alias?        then parser.read_next
            when .sequence_start? then parser.read_next
            when .sequence_end?   then parser.read_next
            when .mapping_start?  then parser.read_next
            when .mapping_end?    then parser.read_next
            else                  break
            end
          end
        end
      end
    end
  end
end

BenchHelper.memory_section("PullParser (consume all events)") do
  fixtures.each do |name, yaml|
    next if name == "multi_document"
    BenchHelper.memory_report("pull #{name}") do
      parser = Yaml::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          loop do
            case parser.kind
            when .scalar?       then parser.read_next
            when .alias?        then parser.read_next
            when .sequence_start? then parser.read_next
            when .sequence_end?   then parser.read_next
            when .mapping_start?  then parser.read_next
            when .mapping_end?    then parser.read_next
            else                  break
            end
          end
        end
      end
    end
  end
end
