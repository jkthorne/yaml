module Yaml
  class Reader
    BOM_UTF8    = Bytes[0xEF, 0xBB, 0xBF]
    BOM_UTF16LE = Bytes[0xFF, 0xFE]
    BOM_UTF16BE = Bytes[0xFE, 0xFF]

    BUFFER_SIZE = 4096

    getter mark : Mark
    getter encoding : Encoding
    getter original_encoding : Encoding

    @buffer : String
    @pos : Int32
    @eof : Bool

    # For IO-based input
    @io : IO?
    @raw_buffer : Bytes
    @raw_pos : Int32
    @raw_len : Int32
    @leftover_byte : UInt8?

    def initialize(string : String)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @original_encoding = Encoding::UTF8
      @buffer = string
      @pos = 0
      @eof = true # entire input is already in @buffer
      @io = nil
      @raw_buffer = Bytes.empty
      @raw_pos = 0
      @raw_len = 0
      @leftover_byte = nil
      detect_bom
      transcode_if_needed
    end

    def initialize(io : IO)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @original_encoding = Encoding::UTF8
      @buffer = ""
      @pos = 0
      @eof = false
      @io = io
      @raw_buffer = Bytes.new(BUFFER_SIZE)
      @raw_pos = 0
      @raw_len = 0
      @leftover_byte = nil
      fill_buffer
      detect_bom
      transcode_if_needed
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

    def get_source_line(line : Int32) : String?
      current_line = 0
      i = 0
      while i < @buffer.bytesize
        if current_line == line
          end_i = i
          while end_i < @buffer.bytesize
            byte = @buffer.to_unsafe[end_i]
            break if byte === '\n'.ord || byte === '\r'.ord
            end_i += 1
          end
          len = end_i - i
          return nil if len == 0
          result = @buffer.byte_slice(i, Math.min(len, 120))
          return len > 120 ? result + "..." : result
        end
        byte = @buffer.to_unsafe[i]
        if byte === '\n'.ord
          current_line += 1
          i += 1
        elsif byte === '\r'.ord
          current_line += 1
          i += 1
          i += 1 if i < @buffer.bytesize && @buffer.to_unsafe[i] === '\n'.ord
        else
          i += 1
        end
      end
      nil
    end

    private def detect_bom : Nil
      return if @buffer.bytesize < 2

      bytes = @buffer.to_slice
      if @buffer.bytesize >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        @encoding = Encoding::UTF8
        @original_encoding = Encoding::UTF8
        @pos = 3
        @mark.index = 3
      elsif bytes[0] == 0xFE && bytes[1] == 0xFF
        @encoding = Encoding::UTF16BE
        @original_encoding = Encoding::UTF16BE
        @pos = 2
        @mark.index = 2
      elsif bytes[0] == 0xFF && bytes[1] == 0xFE
        @encoding = Encoding::UTF16LE
        @original_encoding = Encoding::UTF16LE
        @pos = 2
        @mark.index = 2
      end
    end

    private def transcode_if_needed : Nil
      return if @encoding == Encoding::UTF8

      big_endian = @encoding == Encoding::UTF16BE
      raw = @buffer.to_slice[@pos, @buffer.bytesize - @pos]
      @buffer = transcode_utf16_bytes(raw, big_endian)
      @pos = 0
      @mark.index = 0
      @encoding = Encoding::UTF8
    end

    private def transcode_utf16_bytes(bytes : Bytes, big_endian : Bool) : String
      String.build do |io|
        i = 0
        while i + 1 < bytes.size
          code_unit = if big_endian
                        (bytes[i].to_u16 << 8) | bytes[i + 1].to_u16
                      else
                        bytes[i].to_u16 | (bytes[i + 1].to_u16 << 8)
                      end
          i += 2

          codepoint = if code_unit >= 0xD800_u16 && code_unit <= 0xDBFF_u16
                        if i + 1 < bytes.size
                          low = if big_endian
                                  (bytes[i].to_u16 << 8) | bytes[i + 1].to_u16
                                else
                                  bytes[i].to_u16 | (bytes[i + 1].to_u16 << 8)
                                end
                          if low >= 0xDC00_u16 && low <= 0xDFFF_u16
                            i += 2
                            ((code_unit.to_u32 - 0xD800) << 10) + (low.to_u32 - 0xDC00) + 0x10000
                          else
                            0xFFFD_u32
                          end
                        else
                          @leftover_byte = bytes[i] if i < bytes.size
                          0xFFFD_u32
                        end
                      else
                        code_unit.to_u32
                      end

          io << codepoint.chr
        end

        if i < bytes.size
          @leftover_byte = bytes[i]
        end
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

    private def read_chunk_from_io : String?
      io = @io
      return nil unless io

      bytes_read = io.read(@raw_buffer)
      if bytes_read == 0
        @eof = true
        return nil
      end

      raw = @raw_buffer[0, bytes_read]

      if @original_encoding == Encoding::UTF8
        String.new(raw)
      else
        chunk = if leftover = @leftover_byte
                  @leftover_byte = nil
                  combined = Bytes.new(raw.size + 1)
                  combined[0] = leftover
                  raw.copy_to(combined.to_unsafe + 1, raw.size)
                  combined
                else
                  raw
                end
        transcode_utf16_bytes(chunk, @original_encoding == Encoding::UTF16BE)
      end
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

      chunk = read_chunk_from_io
      return false unless chunk

      @buffer = @buffer + chunk
      true
    end
  end
end
