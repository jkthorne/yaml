require "./spec_helper"

describe "Integration" do
  it "parses shard.yml" do
    content = File.read("shard.yml")
    parser = Yaml::PullParser.new(content)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          keys = [] of String
          while parser.kind != Yaml::EventKind::MAPPING_END
            keys << parser.read_scalar
            parser.skip
          end
          keys.should contain("name")
          keys.should contain("version")
          keys.should contain("crystal")
        end
      end
    end
  end

  it "round-trips a simple mapping through builder" do
    result = Yaml::Builder.build do |builder|
      builder.mapping do
        builder.scalar("name")
        builder.scalar("yaml")
        builder.scalar("version")
        builder.scalar("0.1.0")
      end
    end

    # Parse the output back
    parser = Yaml::PullParser.new(result)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("name")
          parser.read_scalar.should eq("yaml")
          parser.read_scalar.should eq("version")
          parser.read_scalar.should eq("0.1.0")
        end
      end
    end
  end

  it "handles multiline plain scalars" do
    yaml = "key: this is\n  a multiline\n  value"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("key")
          val = parser.read_scalar
          val.should eq("this is a multiline value")
        end
      end
    end
  end

  it "handles multiple documents" do
    yaml = "---\nfirst\n---\nsecond\n..."
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_scalar.should eq("first")
      end
      parser.read_document do
        parser.read_scalar.should eq("second")
      end
    end
  end

  it "handles complex nested structure" do
    yaml = <<-YAML
    database:
      host: localhost
      port: 5432
      credentials:
        user: admin
        pass: secret
    features:
    - logging
    - monitoring
    YAML
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("database")
          parser.read_mapping do
            parser.read_scalar.should eq("host")
            parser.read_scalar.should eq("localhost")
            parser.read_scalar.should eq("port")
            parser.read_scalar.should eq("5432")
            parser.read_scalar.should eq("credentials")
            parser.read_mapping do
              parser.read_scalar.should eq("user")
              parser.read_scalar.should eq("admin")
              parser.read_scalar.should eq("pass")
              parser.read_scalar.should eq("secret")
            end
          end
          parser.read_scalar.should eq("features")
          parser.read_sequence do
            parser.read_scalar.should eq("logging")
            parser.read_scalar.should eq("monitoring")
          end
        end
      end
    end
  end

  it "handles literal block scalar" do
    yaml = "content: |\n  line one\n  line two\n"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("content")
          val = parser.read_scalar
          val.should eq("line one\nline two\n")
        end
      end
    end
  end

  it "handles folded block scalar" do
    yaml = "content: >\n  folded\n  text\n"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("content")
          val = parser.read_scalar
          val.should eq("folded text\n")
        end
      end
    end
  end

  it "handles tags" do
    yaml = "!!str 42"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.kind.should eq(Yaml::EventKind::SCALAR)
        parser.tag.should eq("tag:yaml.org,2002:str")
        parser.value.should eq("42")
        parser.read_next
      end
    end
  end

  it "parses node tree from complex YAML" do
    yaml = "users:\n- name: Alice\n  age: 30\n- name: Bob\n  age: 25"
    doc = Yaml::Nodes::Parser.new(yaml).parse
    root = doc.nodes[0].as(Yaml::Nodes::Mapping)
    key = root.nodes[0].as(Yaml::Nodes::Scalar)
    key.value.should eq("users")
    seq = root.nodes[1].as(Yaml::Nodes::Sequence)
    seq.nodes.size.should eq(2)
    first_user = seq.nodes[0].as(Yaml::Nodes::Mapping)
    (first_user.nodes[0].as(Yaml::Nodes::Scalar)).value.should eq("name")
    (first_user.nodes[1].as(Yaml::Nodes::Scalar)).value.should eq("Alice")
  end

  it "handles double-quoted escape sequences" do
    yaml = %("tab:\\there\\nnewline")
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_scalar.should eq("tab:\there\nnewline")
      end
    end
  end

  it "handles empty values in mapping" do
    yaml = "key:"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("key")
          parser.read_scalar.should eq("")
        end
      end
    end
  end

  it "handles nested flow collections" do
    yaml = "{a: [1, 2], b: {c: 3}}"
    parser = Yaml::PullParser.new(yaml)
    parser.read_stream do
      parser.read_document do
        parser.read_mapping do
          parser.read_scalar.should eq("a")
          parser.read_sequence do
            parser.read_scalar.should eq("1")
            parser.read_scalar.should eq("2")
          end
          parser.read_scalar.should eq("b")
          parser.read_mapping do
            parser.read_scalar.should eq("c")
            parser.read_scalar.should eq("3")
          end
        end
      end
    end
  end
end
