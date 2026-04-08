require "./spec_helper"

describe Yaml::Reader do
  describe "String input" do
    it "peeks characters" do
      reader = Yaml::Reader.new("abc")
      reader.peek(0).should eq('a')
      reader.peek(1).should eq('b')
      reader.peek(2).should eq('c')
      reader.peek(3).should eq('\0')
    end

    it "advances and peeks" do
      reader = Yaml::Reader.new("hello")
      reader.peek.should eq('h')
      reader.advance
      reader.peek.should eq('e')
      reader.advance(2)
      reader.peek.should eq('l')
      reader.advance(2)
      reader.eof?.should be_true
    end

    it "tracks line and column" do
      reader = Yaml::Reader.new("ab\ncd")
      reader.mark.line.should eq(0)
      reader.mark.column.should eq(0)
      reader.advance(2) # past 'a', 'b'
      reader.mark.column.should eq(2)
      reader.advance # past '\n'
      reader.mark.line.should eq(1)
      reader.mark.column.should eq(0)
      reader.advance # past 'c'
      reader.mark.column.should eq(1)
    end

    it "handles multi-byte UTF-8 characters" do
      reader = Yaml::Reader.new("héllo")
      reader.peek(0).should eq('h')
      reader.peek(1).should eq('é')
      reader.peek(2).should eq('l')
      reader.advance
      reader.peek.should eq('é')
      reader.advance
      reader.peek.should eq('l')
    end

    it "handles 3-byte UTF-8 characters" do
      reader = Yaml::Reader.new("日本語")
      reader.peek(0).should eq('日')
      reader.peek(1).should eq('本')
      reader.peek(2).should eq('語')
      reader.advance
      reader.peek.should eq('本')
    end

    it "handles 4-byte UTF-8 characters (emoji)" do
      reader = Yaml::Reader.new("\u{1F600}ok")
      reader.peek(0).should eq('\u{1F600}')
      reader.peek(1).should eq('o')
      reader.advance
      reader.peek.should eq('o')
    end

    it "returns prefix" do
      reader = Yaml::Reader.new("hello world")
      reader.prefix(5).should eq("hello")
      reader.advance(6)
      reader.prefix(5).should eq("world")
    end

    it "returns eof correctly" do
      reader = Yaml::Reader.new("")
      reader.eof?.should be_true
    end

    it "gets source line" do
      reader = Yaml::Reader.new("line one\nline two\nline three")
      reader.get_source_line(0).should eq("line one")
      reader.get_source_line(1).should eq("line two")
      reader.get_source_line(2).should eq("line three")
      reader.get_source_line(3).should be_nil
    end
  end

  describe "IO input" do
    it "peeks and advances from IO" do
      io = IO::Memory.new("hello world")
      reader = Yaml::Reader.new(io)
      reader.peek(0).should eq('h')
      reader.peek(1).should eq('e')
      reader.advance(6)
      reader.peek.should eq('w')
    end

    it "handles large input (>buffer size)" do
      # Create input larger than initial buffer
      large = "a" * 70000
      io = IO::Memory.new(large)
      reader = Yaml::Reader.new(io)
      reader.peek(0).should eq('a')
      # Advance past the initial buffer size
      50000.times { reader.advance }
      reader.peek.should eq('a')
      reader.eof?.should be_false
    end

    it "detects eof from IO" do
      io = IO::Memory.new("ab")
      reader = Yaml::Reader.new(io)
      reader.advance(2)
      reader.eof?.should be_true
    end
  end
end
