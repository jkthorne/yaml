require "./spec_helper"

describe YAML::Scanner do
  describe "String input" do
    it "peeks characters" do
      scanner = YAML::Scanner.new("abc")
      scanner.peek(0).should eq('a')
      scanner.peek(1).should eq('b')
      scanner.peek(2).should eq('c')
      scanner.peek(3).should eq('\0')
    end

    it "advances and peeks" do
      scanner = YAML::Scanner.new("hello")
      scanner.peek.should eq('h')
      scanner.advance
      scanner.peek.should eq('e')
      scanner.advance(2)
      scanner.peek.should eq('l')
      scanner.advance(2)
      scanner.eof?.should be_true
    end

    it "tracks line and column" do
      scanner = YAML::Scanner.new("ab\ncd")
      scanner.mark.line.should eq(0)
      scanner.mark.column.should eq(0)
      scanner.advance(2) # past 'a', 'b'
      scanner.mark.column.should eq(2)
      scanner.advance # past '\n'
      scanner.mark.line.should eq(1)
      scanner.mark.column.should eq(0)
      scanner.advance # past 'c'
      scanner.mark.column.should eq(1)
    end

    it "handles multi-byte UTF-8 characters" do
      scanner = YAML::Scanner.new("héllo")
      scanner.peek(0).should eq('h')
      scanner.peek(1).should eq('é')
      scanner.peek(2).should eq('l')
      scanner.advance
      scanner.peek.should eq('é')
      scanner.advance
      scanner.peek.should eq('l')
    end

    it "handles 3-byte UTF-8 characters" do
      scanner = YAML::Scanner.new("日本語")
      scanner.peek(0).should eq('日')
      scanner.peek(1).should eq('本')
      scanner.peek(2).should eq('語')
      scanner.advance
      scanner.peek.should eq('本')
    end

    it "handles 4-byte UTF-8 characters (emoji)" do
      scanner = YAML::Scanner.new("\u{1F600}ok")
      scanner.peek(0).should eq('\u{1F600}')
      scanner.peek(1).should eq('o')
      scanner.advance
      scanner.peek.should eq('o')
    end

    it "returns prefix" do
      scanner = YAML::Scanner.new("hello world")
      scanner.prefix(5).should eq("hello")
      scanner.advance(6)
      scanner.prefix(5).should eq("world")
    end

    it "returns eof correctly" do
      scanner = YAML::Scanner.new("")
      scanner.eof?.should be_true
    end

    it "gets source line" do
      scanner = YAML::Scanner.new("line one\nline two\nline three")
      scanner.get_source_line(0).should eq("line one")
      scanner.get_source_line(1).should eq("line two")
      scanner.get_source_line(2).should eq("line three")
      scanner.get_source_line(3).should be_nil
    end
  end

  describe "IO input" do
    it "peeks and advances from IO" do
      io = IO::Memory.new("hello world")
      scanner = YAML::Scanner.new(io)
      scanner.peek(0).should eq('h')
      scanner.peek(1).should eq('e')
      scanner.advance(6)
      scanner.peek.should eq('w')
    end

    it "handles large input (>buffer size)" do
      # Create input larger than initial buffer
      large = "a" * 70000
      io = IO::Memory.new(large)
      scanner = YAML::Scanner.new(io)
      scanner.peek(0).should eq('a')
      # Advance past the initial buffer size
      50000.times { scanner.advance }
      scanner.peek.should eq('a')
      scanner.eof?.should be_false
    end

    it "detects eof from IO" do
      io = IO::Memory.new("ab")
      scanner = YAML::Scanner.new(io)
      scanner.advance(2)
      scanner.eof?.should be_true
    end
  end
end
