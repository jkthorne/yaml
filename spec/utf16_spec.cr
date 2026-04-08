require "./spec_helper"

# Helper to encode a string as UTF-16 with BOM
private def encode_utf16le(yaml : String) : Bytes
  bom = Bytes[0xFF, 0xFE]
  utf16_bytes = IO::Memory.new
  yaml.each_char do |ch|
    cp = ch.ord
    if cp > 0xFFFF
      # Surrogate pair
      cp -= 0x10000
      high = ((cp >> 10) + 0xD800).to_u16
      low = ((cp & 0x3FF) + 0xDC00).to_u16
      utf16_bytes.write_byte((high & 0xFF).to_u8)
      utf16_bytes.write_byte((high >> 8).to_u8)
      utf16_bytes.write_byte((low & 0xFF).to_u8)
      utf16_bytes.write_byte((low >> 8).to_u8)
    else
      utf16_bytes.write_byte((cp & 0xFF).to_u8)
      utf16_bytes.write_byte((cp >> 8).to_u8)
    end
  end
  result = Bytes.new(bom.size + utf16_bytes.pos.to_i32)
  bom.copy_to(result)
  utf16_bytes.to_slice.copy_to(result + bom.size)
  result
end

private def encode_utf16be(yaml : String) : Bytes
  bom = Bytes[0xFE, 0xFF]
  utf16_bytes = IO::Memory.new
  yaml.each_char do |ch|
    cp = ch.ord
    if cp > 0xFFFF
      cp -= 0x10000
      high = ((cp >> 10) + 0xD800).to_u16
      low = ((cp & 0x3FF) + 0xDC00).to_u16
      utf16_bytes.write_byte((high >> 8).to_u8)
      utf16_bytes.write_byte((high & 0xFF).to_u8)
      utf16_bytes.write_byte((low >> 8).to_u8)
      utf16_bytes.write_byte((low & 0xFF).to_u8)
    else
      utf16_bytes.write_byte((cp >> 8).to_u8)
      utf16_bytes.write_byte((cp & 0xFF).to_u8)
    end
  end
  result = Bytes.new(bom.size + utf16_bytes.pos.to_i32)
  bom.copy_to(result)
  utf16_bytes.to_slice.copy_to(result + bom.size)
  result
end

describe "UTF-16 encoding support" do
  describe "UTF-16LE" do
    it "parses a simple scalar from IO" do
      bytes = encode_utf16le("hello")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello")
        end
      end
    end

    it "parses a mapping from IO" do
      bytes = encode_utf16le("key: value")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("key")
            parser.read_scalar.should eq("value")
          end
        end
      end
    end

    it "parses a sequence from IO" do
      bytes = encode_utf16le("- one\n- two\n- three")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
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

    it "parses from String (raw bytes)" do
      bytes = encode_utf16le("hello")
      str = String.new(bytes)
      parser = Yaml::PullParser.new(str)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello")
        end
      end
    end
  end

  describe "UTF-16BE" do
    it "parses a simple scalar from IO" do
      bytes = encode_utf16be("hello")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello")
        end
      end
    end

    it "parses a mapping from IO" do
      bytes = encode_utf16be("key: value")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("key")
            parser.read_scalar.should eq("value")
          end
        end
      end
    end
  end

  describe "surrogate pairs" do
    it "handles emoji in UTF-16LE" do
      # U+1F600 (grinning face) requires surrogate pair
      bytes = encode_utf16le("emoji: \u{1F600}")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("emoji")
            parser.read_scalar.should eq("\u{1F600}")
          end
        end
      end
    end

    it "handles emoji in UTF-16BE" do
      bytes = encode_utf16be("emoji: \u{1F600}")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_mapping do
            parser.read_scalar.should eq("emoji")
            parser.read_scalar.should eq("\u{1F600}")
          end
        end
      end
    end
  end

  describe "document markers" do
    it "parses explicit document with UTF-16LE" do
      bytes = encode_utf16le("---\nhello\n...")
      io = IO::Memory.new(bytes)
      parser = Yaml::PullParser.new(io)
      parser.read_stream do
        parser.read_document do
          parser.read_scalar.should eq("hello")
        end
      end
    end
  end

  describe "original encoding detection" do
    it "detects UTF-16LE encoding" do
      bytes = encode_utf16le("hello")
      scanner = Yaml::Scanner.new(IO::Memory.new(bytes))
      scanner.original_encoding.should eq(Yaml::Encoding::UTF16LE)
    end

    it "detects UTF-16BE encoding" do
      bytes = encode_utf16be("hello")
      scanner = Yaml::Scanner.new(IO::Memory.new(bytes))
      scanner.original_encoding.should eq(Yaml::Encoding::UTF16BE)
    end

    it "detects UTF-8 for plain input" do
      scanner = Yaml::Scanner.new("hello")
      scanner.original_encoding.should eq(Yaml::Encoding::UTF8)
    end
  end
end
