require "./spec_helper"

describe YAML do
  it "has a version" do
    YAML::VERSION.should_not be_nil
  end

  describe YAML::PullParser do
    it "parses a simple scalar" do
      parser = YAML::PullParser.new("hello")
      parser.kind.should eq(YAML::EventKind::STREAM_START)
      parser.read_next.should eq(YAML::EventKind::DOCUMENT_START)
      parser.read_next.should eq(YAML::EventKind::SCALAR)
      parser.value.should eq("hello")
      parser.read_next.should eq(YAML::EventKind::DOCUMENT_END)
      parser.read_next.should eq(YAML::EventKind::STREAM_END)
    end

    it "parses a simple mapping" do
      yaml = "key: value"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("key")
            parser.read_scalar.should eq("value")
          end
        end
      end
    end

    it "parses a simple sequence" do
      yaml = "- one\n- two\n- three"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_sequence do
            parser.read_scalar.should eq("one")
            parser.read_scalar.should eq("two")
            parser.read_scalar.should eq("three")
          end
        end
      end
    end

    it "parses nested mapping" do
      yaml = "outer:\n  inner: value"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("outer")
            parser.read_mapping do
              parser.read_scalar.should eq("inner")
              parser.read_scalar.should eq("value")
            end
          end
        end
      end
    end

    it "parses flow sequence" do
      yaml = "[1, 2, 3]"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_sequence do
            parser.read_scalar.should eq("1")
            parser.read_scalar.should eq("2")
            parser.read_scalar.should eq("3")
          end
        end
      end
    end

    it "parses flow mapping" do
      yaml = "{a: 1, b: 2}"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("a")
            parser.read_scalar.should eq("1")
            parser.read_scalar.should eq("b")
            parser.read_scalar.should eq("2")
          end
        end
      end
    end

    it "parses quoted strings" do
      yaml = %("hello world")
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello world")
        end
      end
    end

    it "parses single-quoted strings" do
      yaml = "'hello world'"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello world")
        end
      end
    end

    it "parses escape sequences in double-quoted strings" do
      yaml = %("hello\\nworld")
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello\nworld")
        end
      end
    end

    it "parses single-quoted escape (doubled quote)" do
      yaml = "'it''s'"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("it's")
        end
      end
    end

    it "parses anchors and aliases" do
      yaml = "- &anchor value\n- *anchor"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_sequence do
            parser.kind.should eq(YAML::EventKind::SCALAR)
            parser.anchor.should eq("anchor")
            parser.value.should eq("value")
            parser.read_next
            parser.kind.should eq(YAML::EventKind::ALIAS)
            parser.anchor.should eq("anchor")
            parser.read_next
          end
        end
      end
    end

    it "parses explicit document markers" do
      yaml = "---\nhello\n..."
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello")
        end
      end
    end

    it "parses empty document" do
      yaml = "---\n..."
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("")
        end
      end
    end

    it "handles skip" do
      yaml = "key:\n  nested:\n    deep: value\nother: simple"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("key")
            parser.skip # skip the nested mapping
            parser.read_scalar.should eq("other")
            parser.read_scalar.should eq("simple")
          end
        end
      end
    end

    it "parses mapping with sequence values" do
      yaml = "fruits:\n- apple\n- banana"
      parser = YAML::PullParser.new(yaml)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("fruits")
            parser.read_sequence do
              parser.read_scalar.should eq("apple")
              parser.read_scalar.should eq("banana")
            end
          end
        end
      end
    end
  end

  describe YAML::Builder do
    it "builds a simple scalar" do
      result = YAML::Builder.build do |builder|
        builder.scalar("hello")
      end
      result.should contain("hello")
    end

    it "builds a mapping" do
      result = YAML::Builder.build do |builder|
        builder.mapping do
          builder.scalar("key")
          builder.scalar("value")
        end
      end
      result.should contain("key")
      result.should contain("value")
    end

    it "builds a sequence" do
      result = YAML::Builder.build do |builder|
        builder.sequence do
          builder.scalar("one")
          builder.scalar("two")
        end
      end
      result.should contain("one")
      result.should contain("two")
    end

    it "builds a flow sequence" do
      result = YAML::Builder.build do |builder|
        builder.sequence(style: YAML::SequenceStyle::FLOW) do
          builder.scalar("a")
          builder.scalar("b")
        end
      end
      result.should contain("[")
      result.should contain("]")
    end

    it "builds a flow mapping" do
      result = YAML::Builder.build do |builder|
        builder.mapping(style: YAML::MappingStyle::FLOW) do
          builder.scalar("x")
          builder.scalar("1")
        end
      end
      result.should contain("{")
      result.should contain("}")
    end
  end

  describe YAML::Nodes::Parser do
    it "parses a scalar into a node" do
      parser = YAML::Nodes::Parser.new("hello")
      doc = parser.parse
      doc.nodes.size.should eq(1)
      node = doc.nodes[0]
      node.should be_a(YAML::Nodes::Scalar)
      (node.as(YAML::Nodes::Scalar)).value.should eq("hello")
    end

    it "parses a mapping into nodes" do
      parser = YAML::Nodes::Parser.new("key: value")
      doc = parser.parse
      doc.nodes.size.should eq(1)
      mapping = doc.nodes[0].as(YAML::Nodes::Mapping)
      mapping.nodes.size.should eq(2)
      (mapping.nodes[0].as(YAML::Nodes::Scalar)).value.should eq("key")
      (mapping.nodes[1].as(YAML::Nodes::Scalar)).value.should eq("value")
    end

    it "parses a sequence into nodes" do
      parser = YAML::Nodes::Parser.new("- a\n- b")
      doc = parser.parse
      doc.nodes.size.should eq(1)
      seq = doc.nodes[0].as(YAML::Nodes::Sequence)
      seq.nodes.size.should eq(2)
      (seq.nodes[0].as(YAML::Nodes::Scalar)).value.should eq("a")
      (seq.nodes[1].as(YAML::Nodes::Scalar)).value.should eq("b")
    end
  end
end
