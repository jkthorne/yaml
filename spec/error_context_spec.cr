require "./spec_helper"

describe "YAML error context" do
  describe "scanner context" do
    it "includes context for unterminated double-quoted scalar" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new(%("unterminated))
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("double-quoted scalar")
    end

    it "includes context for unterminated single-quoted scalar" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("'unterminated")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("single-quoted scalar")
    end

    it "includes context for bad block scalar header" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("|0\n  text")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("block scalar")
    end

    it "includes context for invalid anchor character" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("&")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("anchor")
    end

    it "includes context for invalid alias character" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("*")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("alias")
    end
  end

  describe "parser context" do
    it "includes context for bad block mapping" do
      # A block mapping key followed by an invalid token (block sequence entry at wrong indent)
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("a:\n  b: 1\n c: 2")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("block mapping")
    end

    it "includes context for flow sequence missing comma" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("[1, [2] 3]")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("flow sequence")
    end

    it "includes context for flow mapping missing comma" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("{a: 1 b: 2}")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.context_info.should_not be_nil
      ex.context_info.not_nil!.should contain("flow mapping")
    end
  end

  describe "source snippet" do
    it "includes source line and caret in scanner error" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new(%("unterminated))
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.source_snippet.should_not be_nil
      ex.message.not_nil!.should contain("^")
    end
  end

  describe "ParseException fields" do
    it "has correct line and column numbers" do
      ex = expect_raises(YAML::ParseException) do
        parser = YAML::PullParser.new("key: value\n  bad: indent")
        while parser.read_next != YAML::EventKind::STREAM_END
        end
      end
      ex.line_number.should be > 0
      ex.column_number.should be > 0
    end
  end
end
