module BenchFixtures
  def self.trivial : String
    "hello world"
  end

  def self.flat_mapping(n : Int32 = 100) : String
    String.build do |io|
      n.times do |i|
        io << "key_" << i << ": value_" << i << '\n'
      end
    end
  end

  def self.nested(depth : Int32 = 5, breadth : Int32 = 4) : String
    String.build do |io|
      build_nested_mapping(io, depth, breadth, 0)
    end
  end

  private def self.build_nested_mapping(io : IO, depth : Int32, breadth : Int32, indent : Int32) : Nil
    prefix = "  " * indent
    breadth.times do |i|
      io << prefix << "key_" << indent << "_" << i << ":"
      if depth > 1
        io << '\n'
        build_nested_mapping(io, depth - 1, breadth, indent + 1)
      else
        io << " value_" << indent << "_" << i << '\n'
      end
    end
  end

  def self.flow_collections(n : Int32 = 50) : String
    String.build do |io|
      io << "sequences:\n"
      n.times do |i|
        io << "  seq_" << i << ": [" << (0...5).map { |j| "item_#{i}_#{j}" }.join(", ") << "]\n"
      end
      io << "mappings:\n"
      n.times do |i|
        io << "  map_" << i << ": {a: " << i << ", b: " << i * 2 << ", c: " << i * 3 << "}\n"
      end
    end
  end

  def self.block_scalars(n : Int32 = 20) : String
    String.build do |io|
      n.times do |i|
        if i.even?
          io << "literal_" << i << ": |\n"
          3.times do |line|
            io << "  Line " << line << " of block " << i << "\n"
          end
        else
          io << "folded_" << i << ": >\n"
          3.times do |line|
            io << "  Paragraph " << line << " of block " << i << "\n"
          end
        end
      end
    end
  end

  def self.anchors_aliases(n : Int32 = 20) : String
    String.build do |io|
      io << "definitions:\n"
      n.times do |i|
        io << "  def_" << i << ": &anchor_" << i << "\n"
        io << "    name: definition_" << i << "\n"
        io << "    value: " << i * 100 << "\n"
      end
      io << "references:\n"
      n.times do |i|
        io << "  ref_" << i << ": *anchor_" << i << "\n"
      end
    end
  end

  def self.multi_document(n : Int32 = 20) : String
    String.build do |io|
      n.times do |i|
        io << "---\n"
        io << "document: " << i << "\n"
        io << "title: Document number " << i << "\n"
        io << "items:\n"
        3.times do |j|
          io << "  - item_" << i << "_" << j << "\n"
        end
      end
      io << "...\n"
    end
  end

  def self.large_config(services : Int32 = 50, env_vars : Int32 = 20) : String
    String.build do |io|
      io << "apiVersion: v1\n"
      io << "kind: ConfigMap\n"
      io << "metadata:\n"
      io << "  name: bench-config\n"
      io << "  namespace: default\n"
      io << "  labels:\n"
      io << "    app: benchmark\n"
      io << "    version: \"1.0\"\n"
      io << "services:\n"
      services.times do |i|
        io << "  service_" << i << ":\n"
        io << "    name: svc-" << i << "\n"
        io << "    image: registry.example.com/app-" << i << ":latest\n"
        io << "    replicas: " << (i % 5 + 1) << "\n"
        io << "    ports:\n"
        io << "      - containerPort: " << (8000 + i) << "\n"
        io << "        protocol: TCP\n"
        io << "      - containerPort: " << (9000 + i) << "\n"
        io << "        protocol: UDP\n"
        io << "    env:\n"
        env_vars.times do |j|
          io << "      ENV_" << j << ": \"value_" << i << "_" << j << "\"\n"
        end
        io << "    resources:\n"
        io << "      requests:\n"
        io << "        cpu: \"" << (100 + i * 10) << "m\"\n"
        io << "        memory: \"" << (64 + i * 8) << "Mi\"\n"
        io << "      limits:\n"
        io << "        cpu: \"" << (200 + i * 10) << "m\"\n"
        io << "        memory: \"" << (128 + i * 8) << "Mi\"\n"
        io << "    health:\n"
        io << "      liveness: /healthz\n"
        io << "      readiness: /ready\n"
        io << "      initialDelaySeconds: " << (5 + i % 10) << "\n"
      end
    end
  end

  def self.strings_heavy(n : Int32 = 50) : String
    String.build do |io|
      n.times do |i|
        io << "double_" << i << ": \"line1\\nline2\\ttabbed\\\\backslash " << i << "\"\n"
        io << "single_" << i << ": 'it''s a single-quoted string number " << i << "'\n"
        io << "plain_" << i << ": just a plain scalar value " << i << "\n"
      end
    end
  end
end
