module Yaml
  class Reader
    BOM_UTF8    = Bytes[0xEF, 0xBB, 0xBF]
    BOM_UTF16LE = Bytes[0xFF, 0xFE]
    BOM_UTF16BE = Bytes[0xFE, 0xFF]

    RAW_BUFFER_SIZE  = 4096
    BYTE_BUFFER_SIZE = 65536
    CHAR_CACHE_SIZE  = 2048

    getter mark : Mark
    getter encoding : Encoding
    getter original_encoding : Encoding

    # Byte buffer: holds UTF-8 data
    @byte_buf : Bytes
    @byte_start : Int32  # read cursor
    @byte_len : Int32    # valid bytes in buffer

    # Character cache: decoded from byte buffer
    @char_cache : Array(Char)
    @char_byte_sizes : Array(Int32)
    @chars_decoded : Int32

    # Byte position of next undecoded byte relative to @byte_start
    @decode_offset : Int32

    @eof : Bool

    # For IO-based input
    @io : IO?
    @raw_buffer : Bytes
    @leftover_byte : UInt8?

    # For source line extraction (keep full input for string sources)
    @full_input : String?

    def initialize(string : String)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @original_encoding = Encoding::UTF8
      @eof = true
      @io = nil
      @raw_buffer = Bytes.empty
      @leftover_byte = nil

      @byte_buf = string.to_slice.dup
      @byte_start = 0
      @byte_len = string.bytesize

      @char_cache = Array(Char).new(CHAR_CACHE_SIZE)
      @char_byte_sizes = Array(Int32).new(CHAR_CACHE_SIZE)
      @chars_decoded = 0
      @decode_offset = 0

      @full_input = string

      detect_bom
      transcode_if_needed
    end

    def initialize(io : IO)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @original_encoding = Encoding::UTF8
      @eof = false
      @io = io
      @raw_buffer = Bytes.new(RAW_BUFFER_SIZE)
      @leftover_byte = nil

      @byte_buf = Bytes.new(BYTE_BUFFER_SIZE)
      @byte_start = 0
      @byte_len = 0

      @char_cache = Array(Char).new(CHAR_CACHE_SIZE)
      @char_byte_sizes = Array(Int32).new(CHAR_CACHE_SIZE)
      @chars_decoded = 0
      @decode_offset = 0

      @full_input = nil

      fill_initial_buffer
      detect_bom
      transcode_if_needed
    end

    # --- Public API (identical signatures) ---

    def peek(offset : Int32 = 0) : Char
      ensure_chars(offset + 1)
      if offset < @chars_decoded
        @char_cache.unsafe_fetch(offset)
      else
        '\0'
      end
    end

    def peek_byte(offset : Int32 = 0) : UInt8
      byte_pos = @byte_start + offset
      ensure_bytes_available(byte_pos)
      if byte_pos < @byte_len
        @byte_buf[byte_pos]
      else
        0_u8
      end
    end

    def prefix(length : Int32) : String
      ensure_chars(length)
      actual = Math.min(length, @chars_decoded)
      String.build(actual * 4) do |io|
        actual.times do |i|
          io << @char_cache.unsafe_fetch(i)
        end
      end
    end

    def prefix_bytes(length : Int32) : Bytes
      available_bytes = @byte_len - @byte_start
      ensure_bytes_available(@byte_start + length)
      actual = Math.min(length, @byte_len - @byte_start)
      if actual > 0
        @byte_buf[@byte_start, actual]
      else
        Bytes.empty
      end
    end

    def advance(n : Int32 = 1) : Nil
      n.times do
        break if eof?
        ensure_chars(1)
        break if @chars_decoded == 0

        ch = @char_cache.unsafe_fetch(0)
        byte_size = @char_byte_sizes.unsafe_fetch(0)

        @byte_start += byte_size
        @mark.index += byte_size
        @decode_offset -= byte_size

        # Remove first element from cache
        @char_cache.shift
        @char_byte_sizes.shift
        @chars_decoded -= 1

        if ch == '\n'
          @mark.line += 1
          @mark.column = 0
        else
          @mark.column += 1
        end
      end
    end

    def eof? : Bool
      ensure_chars(1)
      @chars_decoded == 0 && @byte_start >= @byte_len && @eof
    end

    def get_source_line(line : Int32) : String?
      # Use full input if available (string source), otherwise scan byte buffer
      source = @full_input
      if source
        return scan_line_in_string(source, line)
      end

      # For IO input, scan what's in the byte buffer
      buf_str = String.new(@byte_buf[0, @byte_len])
      scan_line_in_string(buf_str, line)
    end

    # --- Private: BOM & encoding ---

    private def detect_bom : Nil
      return if @byte_len < 2

      if @byte_len >= 3 && @byte_buf[@byte_start] == 0xEF && @byte_buf[@byte_start + 1] == 0xBB && @byte_buf[@byte_start + 2] == 0xBF
        @encoding = Encoding::UTF8
        @original_encoding = Encoding::UTF8
        @byte_start = 3
        @mark.index = 3
      elsif @byte_buf[@byte_start] == 0xFE && @byte_buf[@byte_start + 1] == 0xFF
        @encoding = Encoding::UTF16BE
        @original_encoding = Encoding::UTF16BE
        @byte_start = 2
        @mark.index = 2
      elsif @byte_buf[@byte_start] == 0xFF && @byte_buf[@byte_start + 1] == 0xFE
        @encoding = Encoding::UTF16LE
        @original_encoding = Encoding::UTF16LE
        @byte_start = 2
        @mark.index = 2
      end
    end

    private def transcode_if_needed : Nil
      return if @encoding == Encoding::UTF8

      big_endian = @encoding == Encoding::UTF16BE
      raw_len = @byte_len - @byte_start
      raw = @byte_buf[@byte_start, raw_len]
      transcoded = transcode_utf16_bytes(raw, big_endian)
      transcoded_bytes = transcoded.to_slice

      # Replace byte buffer with transcoded UTF-8
      if transcoded_bytes.size > @byte_buf.size
        @byte_buf = Bytes.new(transcoded_bytes.size)
      end
      transcoded_bytes.copy_to(@byte_buf)
      @byte_start = 0
      @byte_len = transcoded_bytes.size
      @mark.index = 0
      @encoding = Encoding::UTF8

      # Update full_input for string sources
      if @full_input
        @full_input = transcoded
      end
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

    # --- Private: character decoding ---

    private def ensure_chars(count : Int32) : Nil
      while @chars_decoded < count
        break unless decode_next_char
      end
    end

    private def decode_next_char : Bool
      byte_pos = @byte_start + @decode_offset
      ensure_bytes_available(byte_pos)

      return false if byte_pos >= @byte_len

      # Decode one UTF-8 character
      first_byte = @byte_buf[byte_pos]
      char_len = utf8_char_length(first_byte)

      # Ensure we have all bytes for this character
      ensure_bytes_available(byte_pos + char_len - 1)
      return false if byte_pos + char_len > @byte_len

      ch = decode_utf8_char(byte_pos, char_len)

      @char_cache.push(ch)
      @char_byte_sizes.push(char_len)
      @chars_decoded += 1
      @decode_offset += char_len
      true
    end

    private def utf8_char_length(first_byte : UInt8) : Int32
      if first_byte < 0x80
        1
      elsif first_byte < 0xE0
        2
      elsif first_byte < 0xF0
        3
      else
        4
      end
    end

    private def decode_utf8_char(pos : Int32, len : Int32) : Char
      case len
      when 1
        @byte_buf[pos].chr
      when 2
        cp = ((@byte_buf[pos].to_u32 & 0x1F) << 6) |
             (@byte_buf[pos + 1].to_u32 & 0x3F)
        cp.chr
      when 3
        cp = ((@byte_buf[pos].to_u32 & 0x0F) << 12) |
             ((@byte_buf[pos + 1].to_u32 & 0x3F) << 6) |
             (@byte_buf[pos + 2].to_u32 & 0x3F)
        cp.chr
      else
        cp = ((@byte_buf[pos].to_u32 & 0x07) << 18) |
             ((@byte_buf[pos + 1].to_u32 & 0x3F) << 12) |
             ((@byte_buf[pos + 2].to_u32 & 0x3F) << 6) |
             (@byte_buf[pos + 3].to_u32 & 0x3F)
        cp.chr
      end
    end

    # --- Private: byte buffer management ---

    private def ensure_bytes_available(target : Int32) : Nil
      return if @eof
      while target >= @byte_len
        break unless refill_bytes
      end
    end

    private def fill_initial_buffer : Nil
      io = @io
      return unless io

      bytes_read = io.read(@byte_buf)
      if bytes_read == 0
        @eof = true
        return
      end
      @byte_len = bytes_read
    end

    private def refill_bytes : Bool
      io = @io
      return false unless io

      # Compact: move unread data to front
      if @byte_start > 0
        remaining = @byte_len - @byte_start
        if remaining > 0
          @byte_buf.to_unsafe.copy_from(@byte_buf.to_unsafe + @byte_start, remaining)
        end
        @byte_len = remaining
        @byte_start = 0
        @decode_offset = @chars_decoded > 0 ? @decode_offset : 0
      end

      # Grow buffer if needed
      if @byte_len >= @byte_buf.size
        new_buf = Bytes.new(@byte_buf.size * 2)
        new_buf.to_unsafe.copy_from(@byte_buf.to_unsafe, @byte_len)
        @byte_buf = new_buf
      end

      # Read raw bytes from IO
      space = @byte_buf.size - @byte_len
      bytes_read = io.read(Bytes.new(@raw_buffer.to_unsafe, Math.min(space, RAW_BUFFER_SIZE)))

      if bytes_read == 0
        @eof = true
        return false
      end

      if @original_encoding == Encoding::UTF8
        (@byte_buf.to_unsafe + @byte_len).copy_from(@raw_buffer.to_unsafe, bytes_read)
        @byte_len += bytes_read
      else
        # UTF-16: transcode chunk
        raw = @raw_buffer[0, bytes_read]
        chunk = if leftover = @leftover_byte
                  @leftover_byte = nil
                  combined = Bytes.new(raw.size + 1)
                  combined[0] = leftover
                  raw.copy_to(combined.to_unsafe + 1, raw.size)
                  combined
                else
                  raw
                end
        transcoded = transcode_utf16_bytes(chunk, @original_encoding == Encoding::UTF16BE)
        transcoded_bytes = transcoded.to_slice
        # Ensure space
        while @byte_len + transcoded_bytes.size > @byte_buf.size
          new_buf = Bytes.new(@byte_buf.size * 2)
          new_buf.to_unsafe.copy_from(@byte_buf.to_unsafe, @byte_len)
          @byte_buf = new_buf
        end
        (@byte_buf.to_unsafe + @byte_len).copy_from(transcoded_bytes.to_unsafe, transcoded_bytes.size)
        @byte_len += transcoded_bytes.size
      end

      true
    end

    # --- Private: source line scanning ---

    private def scan_line_in_string(str : String, line : Int32) : String?
      current_line = 0
      i = 0
      while i < str.bytesize
        if current_line == line
          end_i = i
          while end_i < str.bytesize
            byte = str.to_unsafe[end_i]
            break if byte === '\n'.ord || byte === '\r'.ord
            end_i += 1
          end
          len = end_i - i
          return nil if len == 0
          result = str.byte_slice(i, Math.min(len, 120))
          return len > 120 ? result + "..." : result
        end
        byte = str.to_unsafe[i]
        if byte === '\n'.ord
          current_line += 1
          i += 1
        elsif byte === '\r'.ord
          current_line += 1
          i += 1
          i += 1 if i < str.bytesize && str.to_unsafe[i] === '\n'.ord
        else
          i += 1
        end
      end
      nil
    end
  end
end
