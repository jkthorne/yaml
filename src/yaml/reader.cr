module Yaml
  class Reader
    BOM_UTF8    = Bytes[0xEF, 0xBB, 0xBF]
    BOM_UTF16LE = Bytes[0xFF, 0xFE]
    BOM_UTF16BE = Bytes[0xFE, 0xFF]

    BUFFER_SIZE = 4096

    getter mark : Mark
    getter encoding : Encoding

    @buffer : String
    @pos : Int32
    @eof : Bool

    # For IO-based input
    @io : IO?
    @raw_buffer : Bytes
    @raw_pos : Int32
    @raw_len : Int32

    def initialize(string : String)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @buffer = string
      @pos = 0
      @eof = true # entire input is already in @buffer
      @io = nil
      @raw_buffer = Bytes.empty
      @raw_pos = 0
      @raw_len = 0
      detect_bom
    end

    def initialize(io : IO)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @buffer = ""
      @pos = 0
      @eof = false
      @io = io
      @raw_buffer = Bytes.new(BUFFER_SIZE)
      @raw_pos = 0
      @raw_len = 0
      fill_buffer
      detect_bom
    end

    def peek(offset : Int32 = 0) : Char
      target = @pos + offset
      ensure_available(target)
      if target < @buffer.size
        @buffer.char_at(target)
      else
        '\0'
      end
    end

    def peek_byte(offset : Int32 = 0) : UInt8
      target = @pos + offset
      ensure_available(target)
      if target < @buffer.bytesize
        @buffer.to_unsafe[target]
      else
        0_u8
      end
    end

    def prefix(length : Int32) : String
      ensure_available(@pos + length - 1)
      if @pos + length <= @buffer.size
        @buffer[@pos, length]
      else
        remaining = @buffer.size - @pos
        remaining > 0 ? @buffer[@pos, remaining] : ""
      end
    end

    def prefix_bytes(length : Int32) : Bytes
      ensure_available(@pos + length - 1)
      available = Math.min(length, @buffer.bytesize - @pos)
      if available > 0
        @buffer.to_slice[@pos, available]
      else
        Bytes.empty
      end
    end

    def advance(n : Int32 = 1) : Nil
      n.times do
        break if eof?
        ch = current_char
        @pos += ch.bytesize
        @mark.index += ch.bytesize
        if ch == '\n'
          @mark.line += 1
          @mark.column = 0
        else
          @mark.column += 1
        end
      end
    end

    def eof? : Bool
      ensure_available(@pos)
      @pos >= @buffer.size
    end

    private def current_char : Char
      if @pos < @buffer.size
        @buffer.char_at(@pos)
      else
        '\0'
      end
    end

    private def detect_bom : Nil
      return if @buffer.bytesize < 2

      bytes = @buffer.to_slice
      if @buffer.bytesize >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        @encoding = Encoding::UTF8
        @pos = 3
        @mark.index = 3
      elsif bytes[0] == 0xFE && bytes[1] == 0xFF
        @encoding = Encoding::UTF16BE
        @pos = 2
        @mark.index = 2
      elsif bytes[0] == 0xFF && bytes[1] == 0xFE
        @encoding = Encoding::UTF16LE
        @pos = 2
        @mark.index = 2
      end
    end

    private def ensure_available(target : Int32) : Nil
      return if @eof
      while target >= @buffer.size
        break unless read_more
      end
    end

    private def fill_buffer : Nil
      io = @io
      return unless io

      bytes_read = io.read(@raw_buffer)
      if bytes_read == 0
        @eof = true
        return
      end
      @buffer = String.new(@raw_buffer[0, bytes_read])
    end

    private def read_more : Bool
      io = @io
      return false unless io

      # Compact: keep unread portion
      if @pos > 0
        remaining = @buffer.bytesize - @pos
        if remaining > 0
          @buffer = @buffer.byte_slice(@pos)
        else
          @buffer = ""
        end
        @pos = 0
      end

      bytes_read = io.read(@raw_buffer)
      if bytes_read == 0
        @eof = true
        return false
      end

      @buffer = @buffer + String.new(@raw_buffer[0, bytes_read])
      true
    end
  end
end
