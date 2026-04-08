module YAML
  private struct SimpleKey
    property possible : Bool
    property required : Bool
    property token_number : Int32
    property mark : Mark

    def initialize(
      @possible : Bool = false,
      @required : Bool = false,
      @token_number : Int32 = 0,
      @mark : Mark = Mark.new
    )
    end
  end

  class Scanner
    MAX_SIMPLE_KEY_LENGTH = 1024
    BUFFER_SIZE = 4096

    # Reader fields (inlined)
    getter mark : Mark
    getter encoding : Encoding
    getter original_encoding : Encoding
    @buffer : String
    @pos : Int32
    @eof : Bool
    @io : IO?
    @raw_buffer : Bytes
    @raw_pos : Int32
    @raw_len : Int32

    # Scanner fields
    @tokens : Deque(Token)
    @tokens_parsed : Int32
    @token_available : Bool
    @stream_start_produced : Bool
    @stream_end_produced : Bool
    @indent : Int32
    @indents : Array(Int32)
    @simple_key_allowed : Bool
    @simple_keys : Array(SimpleKey)
    @flow_level : Int32
    @context_stack : Array({String, Mark})

    def initialize(string : String)
      @mark = Mark.new
      @encoding = Encoding::UTF8
      @original_encoding = Encoding::UTF8
      @buffer = string
      @pos = 0
      @eof = true
      @io = nil
      @raw_buffer = Bytes.empty
      @raw_pos = 0
      @raw_len = 0
      @tokens = Deque(Token).new
      @tokens_parsed = 0
      @token_available = false
      @stream_start_produced = false
      @stream_end_produced = false
      @indent = -1
      @indents = Array(Int32).new(8)
      @simple_key_allowed = false
      @simple_keys = [SimpleKey.new]
      @flow_level = 0
      @context_stack = Array({String, Mark}).new(4)
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
      @tokens = Deque(Token).new
      @tokens_parsed = 0
      @token_available = false
      @stream_start_produced = false
      @stream_end_produced = false
      @indent = -1
      @indents = Array(Int32).new(8)
      @simple_key_allowed = false
      @simple_keys = [SimpleKey.new]
      @flow_level = 0
      @context_stack = Array({String, Mark}).new(4)
      fill_buffer
      detect_bom
      transcode_if_needed
    end

    def scan : Token
      ensure_token_available
      token = @tokens.shift
      @tokens_parsed += 1
      @token_available = false
      token
    end

    def peek_token : Token?
      ensure_token_available
      @tokens.first?
    end

    # --- Private implementation ---

    private def ensure_token_available : Nil
      return if @token_available

      fetch_more_tokens
      @token_available = true
    end

    private def fetch_more_tokens : Nil
      loop do
        need_more = @tokens.empty?

        unless need_more
          stale_simple_keys
          # Check if any potential simple key may need more tokens
          @simple_keys.each do |key|
            if key.possible && key.token_number == @tokens_parsed
              need_more = true
              break
            end
          end
        end

        break unless need_more

        fetch_next_token
      end
    end

    private def fetch_next_token : Nil
      unless @stream_start_produced
        fetch_stream_start
        return
      end

      scan_to_next_token
      stale_simple_keys
      unroll_indent(@mark.column)

      return fetch_stream_end if eof?

      b = peek_byte
      nb = peek_byte(1)

      case b
      when '%'.ord
        return fetch_directive if @mark.column == 0
      when '['.ord then return fetch_flow_collection_start(TokenKind::FLOW_SEQUENCE_START)
      when '{'.ord then return fetch_flow_collection_start(TokenKind::FLOW_MAPPING_START)
      when ']'.ord then return fetch_flow_collection_end(TokenKind::FLOW_SEQUENCE_END)
      when '}'.ord then return fetch_flow_collection_end(TokenKind::FLOW_MAPPING_END)
      when ','.ord then return fetch_flow_entry
      when '*'.ord then return fetch_alias
      when '&'.ord then return fetch_anchor
      when '!'.ord then return fetch_tag
      when '\''.ord then return fetch_flow_scalar(single: true)
      when '"'.ord then return fetch_flow_scalar(single: false)
      when '-'.ord
        if check_document_indicator('-')
          return fetch_document_indicator(TokenKind::DOCUMENT_START)
        elsif is_blank_or_break_at?(1)
          return fetch_block_entry
        end
      when '.'.ord
        if check_document_indicator('.')
          return fetch_document_indicator(TokenKind::DOCUMENT_END)
        end
      when '?'.ord
        if @flow_level > 0 || is_blank_or_break_at?(1)
          return fetch_key
        end
      when ':'.ord
        if @flow_level > 0 || is_blank_or_break_at?(1)
          return fetch_value
        end
      when '|'.ord
        return fetch_block_scalar(literal: true) if @flow_level == 0
      when '>'.ord
        return fetch_block_scalar(literal: false) if @flow_level == 0
      end

      # Fall through: try plain scalar or error
      ch = b < 0x80 ? b.unsafe_chr : peek
      next_ch = nb < 0x80 ? nb.unsafe_chr : peek(1)
      if is_plain_scalar_start?(ch, next_ch)
        fetch_plain_scalar
      else
        scanner_error("found character that cannot start any token", @mark)
      end
    end

    # --- Stream start/end ---

    private def fetch_stream_start : Nil
      @stream_start_produced = true
      @simple_key_allowed = true
      mark = @mark
      token = Token.new(
        kind: TokenKind::STREAM_START,
        start_mark: mark,
        end_mark: mark,
        encoding: @encoding
      )
      @tokens.push(token)
    end

    private def fetch_stream_end : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      @stream_end_produced = true
      mark = @mark
      @tokens.push(Token.new(
        kind: TokenKind::STREAM_END,
        start_mark: mark,
        end_mark: mark
      ))
    end

    # --- Directives ---

    private def fetch_directive : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      scan_directive
    end

    private def scan_directive : Nil
      start_mark = @mark
      push_context("directive", start_mark)
      advance # skip '%'

      name = scan_directive_name(start_mark)

      case name
      when "YAML"
        major, minor = scan_version_directive_value(start_mark)
        scan_directive_trailing(start_mark)
        @tokens.push(Token.new(
          kind: TokenKind::VERSION_DIRECTIVE,
          start_mark: start_mark,
          end_mark: @mark,
          major: major,
          minor: minor
        ))
      when "TAG"
        handle, prefix = scan_tag_directive_value(start_mark)
        scan_directive_trailing(start_mark)
        @tokens.push(Token.new(
          kind: TokenKind::TAG_DIRECTIVE,
          start_mark: start_mark,
          end_mark: @mark,
          value: handle,
          suffix: prefix
        ))
      else
        # Unknown directive — skip to end of line
        while !eof? && !is_break?(peek)
          advance
        end
        scan_directive_trailing(start_mark)
      end
      pop_context
    end

    private def scan_directive_name(start_mark : Mark) : String
      # Fast path: directive names are ASCII alphanumeric + '-' + '_'
      name_start = @pos
      length = 0
      loop do
        b = peek_byte(length)
        break unless (b >= 'a'.ord && b <= 'z'.ord) || (b >= 'A'.ord && b <= 'Z'.ord) ||
                     (b >= '0'.ord && b <= '9'.ord) || b == '-'.ord || b == '_'.ord
        length += 1
      end
      advance(length) if length > 0
      value = length > 0 ? @buffer.byte_slice(name_start, @pos - name_start) : ""
      if value.empty?
        scanner_error("while scanning a directive, did not find expected directive name", start_mark)
      end
      unless eof? || is_blank_or_break?(peek)
        scanner_error("while scanning a directive, found unexpected non-alphabetical character", start_mark)
      end
      value
    end

    private def scan_version_directive_value(start_mark : Mark) : {Int32, Int32}
      skip_blanks
      major = scan_version_directive_number(start_mark)
      unless peek == '.'
        scanner_error("while scanning a %YAML directive, did not find expected digit or '.'", start_mark)
      end
      advance # skip '.'
      minor = scan_version_directive_number(start_mark)
      {major, minor}
    end

    private def scan_version_directive_number(start_mark : Mark) : Int32
      value = 0
      count = 0
      while peek.ascii_number?
        value = value * 10 + (peek.ord - '0'.ord)
        advance
        count += 1
      end
      if count == 0
        scanner_error("while scanning a %YAML directive, did not find expected version number", start_mark)
      end
      value
    end

    private def scan_tag_directive_value(start_mark : Mark) : {String, String}
      skip_blanks
      handle = scan_tag_handle(directive: true, start_mark: start_mark)
      skip_blanks
      prefix = scan_tag_uri(directive: true, start_mark: start_mark)
      {handle, prefix}
    end

    private def scan_directive_trailing(start_mark : Mark) : Nil
      skip_blanks
      if peek == '#'
        while !eof? && !is_break?(peek)
          advance
        end
      end
      unless eof? || is_break?(peek)
        scanner_error("while scanning a directive, did not find expected comment or line break", start_mark)
      end
      skip_line
    end

    # --- Document indicators ---

    private def check_document_indicator(ch : Char) : Bool
      return false unless @mark.column == 0
      peek == ch && peek(1) == ch && peek(2) == ch &&
        (eof? || is_blank_or_break_at?(3))
    end

    private def fetch_document_indicator(kind : TokenKind) : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      start_mark = @mark
      advance(3)
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Flow collection start/end ---

    private def fetch_flow_collection_start(kind : TokenKind) : Nil
      save_simple_key
      increase_flow_level
      @simple_key_allowed = true
      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    private def fetch_flow_collection_end(kind : TokenKind) : Nil
      remove_simple_key
      decrease_flow_level
      @simple_key_allowed = false
      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Flow entry ---

    private def fetch_flow_entry : Nil
      remove_simple_key
      @simple_key_allowed = true
      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: TokenKind::FLOW_ENTRY,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Block entry ---

    private def fetch_block_entry : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error("block sequence entries are not allowed in this context", @mark)
        end
        roll_indent(@mark.column, TokenKind::BLOCK_SEQUENCE_START, @mark)
      end
      @simple_key_allowed = true
      remove_simple_key
      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: TokenKind::BLOCK_ENTRY,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Key ---

    private def fetch_key : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error("mapping keys are not allowed in this context", @mark)
        end
        roll_indent(@mark.column, TokenKind::BLOCK_MAPPING_START, @mark)
      end
      @simple_key_allowed = true
      remove_simple_key
      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: TokenKind::KEY,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Value ---

    private def fetch_value : Nil
      simple_key = @simple_keys.last

      if simple_key.possible
        # Insert KEY token before the simple key
        key_token = Token.new(
          kind: TokenKind::KEY,
          start_mark: simple_key.mark,
          end_mark: simple_key.mark
        )
        insert_index = simple_key.token_number - @tokens_parsed
        @tokens.insert(insert_index, key_token)

        # Roll indent for the simple key if in block context
        if @flow_level == 0
          roll_indent(simple_key.mark.column, TokenKind::BLOCK_MAPPING_START, simple_key.mark, insert_index)
        end

        # Simple key is no longer possible
        @simple_keys[-1] = SimpleKey.new(possible: false)
        @simple_key_allowed = false
      else
        # No simple key — we must be in block context for an explicit value
        if @flow_level == 0
          unless @simple_key_allowed
            scanner_error("mapping values are not allowed in this context", @mark)
          end
          roll_indent(@mark.column, TokenKind::BLOCK_MAPPING_START, @mark)
        end
        @simple_key_allowed = @flow_level == 0
      end

      start_mark = @mark
      advance
      @tokens.push(Token.new(
        kind: TokenKind::VALUE,
        start_mark: start_mark,
        end_mark: @mark
      ))
    end

    # --- Alias and Anchor ---

    private def fetch_alias : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_anchor_or_alias(TokenKind::ALIAS)
    end

    private def fetch_anchor : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_anchor_or_alias(TokenKind::ANCHOR)
    end

    private def scan_anchor_or_alias(kind : TokenKind) : Nil
      start_mark = @mark
      push_context(kind == TokenKind::ALIAS ? "alias" : "anchor", start_mark)
      advance # skip '*' or '&'

      # Fast path: anchor/alias chars are ASCII alphanumeric + '-' + '_'
      name_start = @pos
      length = 0
      loop do
        b = peek_byte(length)
        break unless (b >= 'a'.ord && b <= 'z'.ord) || (b >= 'A'.ord && b <= 'Z'.ord) ||
                     (b >= '0'.ord && b <= '9'.ord) || b == '-'.ord || b == '_'.ord
        length += 1
      end
      if length > 0
        advance(length)
        value = @buffer.byte_slice(name_start, @pos - name_start)
      else
        value = ""
      end

      if value.empty?
        context = kind == TokenKind::ALIAS ? "alias" : "anchor"
        scanner_error("while scanning an #{context}, did not find expected alphabetic or numeric character", start_mark)
      end

      unless eof? || is_blank_or_break?(peek) ||
             peek.in?(',', '[', ']', '{', '}', '?', ':', '%', '@', '`')
        context = kind == TokenKind::ALIAS ? "alias" : "anchor"
        scanner_error("while scanning an #{context}, found unexpected character", start_mark)
      end

      pop_context
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @mark,
        value: value
      ))
    end

    # --- Tag ---

    private def fetch_tag : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_tag
    end

    private def scan_tag : Nil
      start_mark = @mark
      push_context("tag", start_mark)
      advance # skip first '!'

      handle : String
      suffix : String
      ch = peek

      if ch == '<'
        # Verbatim tag: !<uri>
        advance # skip '<'
        handle = ""
        suffix = scan_tag_uri(directive: false, start_mark: start_mark)
        unless peek == '>'
          scanner_error("while scanning a tag, did not find the expected '>'", start_mark)
        end
        advance # skip '>'
      elsif ch == '!'
        # Secondary tag handle: !!suffix
        advance # skip second '!'
        handle = "!!"
        suffix = scan_tag_uri(directive: false, start_mark: start_mark, allow_empty: true)
      elsif is_blank_or_break?(ch) || eof?
        # Primary tag: just !
        handle = "!"
        suffix = ""
      elsif is_alpha?(ch)
        # Could be !handle!suffix or !suffix
        first_part = String.build do |io|
          while is_alpha?(peek)
            io << peek
            advance
          end
        end
        if peek == '!'
          # Named tag handle: !handle!suffix
          advance # skip trailing '!'
          handle = String.build(first_part.bytesize + 2) { |io| io << '!' << first_part << '!' }
          suffix = scan_tag_uri(directive: false, start_mark: start_mark)
        else
          # Primary tag shorthand: !suffix (first_part is part of the suffix)
          handle = "!"
          suffix = first_part + scan_tag_uri(directive: false, start_mark: start_mark, allow_empty: true)
        end
      else
        # Primary tag shorthand starting with non-alpha URI char
        handle = "!"
        suffix = scan_tag_uri(directive: false, start_mark: start_mark)
      end

      unless eof? || is_blank_or_break?(peek) || (@flow_level > 0 && peek == ',')
        scanner_error("while scanning a tag, did not find expected whitespace or line break", start_mark)
      end

      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::TAG,
        start_mark: start_mark,
        end_mark: @mark,
        value: handle,
        suffix: suffix
      ))
    end

    private def scan_tag_handle(directive : Bool, start_mark : Mark) : String
      ch = peek
      unless ch == '!'
        context = directive ? "while scanning a %TAG directive" : "while scanning a tag"
        scanner_error("#{context}, did not find expected '!'", start_mark)
      end

      value = String.build do |io|
        io << '!'
        advance

        if is_alpha?(peek)
          while is_alpha?(peek)
            io << peek
            advance
          end
          unless peek == '!'
            if directive
              scanner_error("while scanning a %TAG directive, did not find expected '!'", start_mark)
            end
            # For non-directive tags, return what we have
          else
            io << '!'
            advance
          end
        end
      end
      value
    end

    private def scan_tag_uri(directive : Bool, start_mark : Mark, allow_empty : Bool = false) : String
      value = String.build do |io|
        loop do
          while is_uri_char?(peek)
            if peek == '%'
              io << scan_uri_escapes(start_mark)
            else
              io << peek
              advance
            end
          end
          break
        end
      end
      if value.empty? && !allow_empty
        context = directive ? "while scanning a %TAG directive" : "while scanning a tag"
        scanner_error("#{context}, did not find expected tag URI", start_mark)
      end
      value
    end

    private def scan_uri_escapes(start_mark : Mark) : String
      bytes = [] of UInt8
      loop do
        break unless peek == '%'
        advance # skip '%'
        high = peek
        advance
        low = peek
        advance
        unless high.hex? && low.hex?
          scanner_error("while scanning a tag, found invalid URI escape", start_mark)
        end
        bytes << ((high.to_i(16) << 4) | low.to_i(16)).to_u8
      end
      String.new(Bytes.new(bytes.to_unsafe, bytes.size))
    end

    # --- Block scalar ---

    private def fetch_block_scalar(literal : Bool) : Nil
      remove_simple_key
      @simple_key_allowed = true
      scan_block_scalar(literal)
    end

    private def scan_block_scalar(literal : Bool) : Nil
      start_mark = @mark
      push_context(literal ? "literal block scalar" : "folded block scalar", start_mark)
      advance # skip '|' or '>'

      # Scan the header: chomping and indent indicator
      chomping = 0  # 0=clip, 1=strip, -1=keep
      increment = 0 # explicit indent
      trailing_blank = false
      leading_break = ""

      # Chomping indicator
      ch = peek
      if ch == '+' || ch == '-'
        chomping = ch == '+' ? -1 : 1
        advance
        ch = peek
        if ch.ascii_number?
          increment = ch.ord - '0'.ord
          if increment == 0
            scanner_error("while scanning a block scalar, found an indentation indicator equal to 0", start_mark)
          end
          advance
        end
      elsif ch.ascii_number?
        increment = ch.ord - '0'.ord
        if increment == 0
          scanner_error("while scanning a block scalar, found an indentation indicator equal to 0", start_mark)
        end
        advance
        ch = peek
        if ch == '+' || ch == '-'
          chomping = ch == '+' ? -1 : 1
          advance
        end
      end

      # Eat trailing blanks and comment
      skip_blanks
      if peek == '#'
        while !eof? && !is_break?(peek)
          advance
        end
      end

      unless eof? || is_break?(peek)
        scanner_error("while scanning a block scalar, did not find expected comment or line break", start_mark)
      end

      skip_line

      end_mark = @mark
      indent = if increment > 0
                 @indent >= 0 ? @indent + increment : increment
               else
                 0
               end

      # Scan the block scalar content
      value = String.build do |io|
        breaks = String::Builder.new
        break_count = 0
        leading_blank = false
        max_indent = 0

        # Determine indentation if not explicitly given
        if indent == 0
          # Auto-detect: skip blank lines, find first non-blank line's indent
          loop do
            while !eof? && @mark.column < 1024 && peek == ' '
              advance
            end
            if @mark.column > max_indent
              max_indent = @mark.column
            end
            if is_break?(peek) && !eof?
              breaks << scan_line_break
              break_count += 1
            else
              break
            end
          end
          indent = max_indent
          indent = @indent + 1 if indent < @indent + 1
          indent = 1 if indent < 1
        end

        # Consume the actual content
        first = true
        loop do
          # Read content at current indentation
          if @mark.column == indent && !eof?
            trailing_blank = is_blank?(peek)

            if !literal && !first && !leading_blank && !trailing_blank &&
               break_count <= 1 && io.bytesize > 0
              # Fold: single break between non-blank lines becomes space
              io << ' '
            else
              io << breaks.to_s
            end
            breaks = String::Builder.new
            break_count = 0
            leading_blank = is_blank?(peek)

            while !eof? && !is_break?(peek)
              io << peek
              advance
            end
            first = false
            end_mark = @mark
            # Capture the line break (will be processed in next iteration)
            if !eof? && is_break?(peek)
              breaks << scan_line_break
              break_count += 1
            end
          else
            break
          end

          # Eat blank lines (breaks)
          loop do
            # Eat indentation up to the block's indent level
            while !eof? && @mark.column < indent && peek == ' '
              advance
            end

            if is_break?(peek) && !eof?
              breaks << scan_line_break
              break_count += 1
            else
              break
            end
          end
        end

        # Apply chomping
        case chomping
        when 0 # clip
          io << '\n'
        when -1 # keep
          io << '\n'
          io << breaks.to_s
        when 1 # strip
          # nothing
        end
      end

      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::SCALAR,
        start_mark: start_mark,
        end_mark: end_mark,
        value: value,
        style: literal ? ScalarStyle::LITERAL : ScalarStyle::FOLDED
      ))
    end

    # --- Flow scalar ---

    private def fetch_flow_scalar(single : Bool) : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_flow_scalar(single)
    end

    private def scan_flow_scalar(single : Bool) : Nil
      start_mark = @mark
      push_context(single ? "single-quoted scalar" : "double-quoted scalar", start_mark)
      advance # skip quote

      value = String.build do |io|
        loop do
          # Check for end of scalar or EOF
          if eof?
            scanner_error("while scanning a quoted scalar, found unexpected end of stream", start_mark)
          end

          if single
            # Single-quoted scalar
            if peek == '\''
              if peek(1) == '\''
                io << '\''
                advance(2)
              else
                break
              end
            elsif is_break?(peek)
              # Line break — fold to space or preserve multiple breaks
              break_count = scan_flow_scalar_breaks(io, start_mark)
              if break_count <= 1
                io << ' '
              end
            else
              io << peek
              advance
            end
          else
            # Double-quoted scalar
            if peek == '"'
              break
            elsif peek == '\\'
              advance
              ch = peek
              advance
              case ch
              when '0'  then io << '\0'
              when 'a'  then io << '\a'
              when 'b'  then io << '\b'
              when 't', '\t' then io << '\t'
              when 'n'  then io << '\n'
              when 'v'  then io << '\v'
              when 'f'  then io << '\f'
              when 'r'  then io << '\r'
              when 'e'  then io << '\e'
              when ' '  then io << ' '
              when '"'  then io << '"'
              when '/'  then io << '/'
              when '\\' then io << '\\'
              when 'N'  then io << '\u0085' # next line
              when '_'  then io << '\u00A0' # non-breaking space
              when 'L'  then io << '\u2028' # line separator
              when 'P'  then io << '\u2029' # paragraph separator
              when 'x'
                io << scan_hex_escape(2, start_mark)
              when 'u'
                io << scan_hex_escape(4, start_mark)
              when 'U'
                io << scan_hex_escape(8, start_mark)
              else
                if is_break?(ch)
                  # Escaped line break — skip first break, preserve extras
                  scan_flow_scalar_breaks(io, start_mark)
                else
                  scanner_error("while scanning a double-quoted scalar, found unknown escape character '#{ch}'", start_mark)
                end
              end
            elsif is_break?(peek)
              break_count = scan_flow_scalar_breaks(io, start_mark)
              if break_count <= 1
                io << ' '
              end
            else
              io << peek
              advance
            end
          end
        end
      end

      advance # skip closing quote
      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::SCALAR,
        start_mark: start_mark,
        end_mark: @mark,
        value: value,
        style: single ? ScalarStyle::SINGLE_QUOTED : ScalarStyle::DOUBLE_QUOTED
      ))
    end

    private def scan_hex_escape(length : Int32, start_mark : Mark) : Char
      code = 0
      length.times do
        ch = peek
        unless ch.hex?
          scanner_error("while scanning a double-quoted scalar, did not find expected hex digit", start_mark)
        end
        code = code * 16 + ch.to_i(16)
        advance
      end
      code.chr
    end

    # Skip whitespace and line breaks in flow scalars. If 2+ breaks found,
    # writes the trailing breaks (all but first) to io. Returns break count.
    private def scan_flow_scalar_breaks(io : IO, start_mark : Mark) : Int32
      count = 0
      loop do
        while is_blank?(peek)
          advance
        end
        if is_break?(peek)
          scan_line_break
          count += 1
        else
          break
        end
      end
      # Write trailing breaks beyond the first (which becomes fold/space)
      if count >= 2
        (count - 1).times { io << '\n' }
      end
      count
    end

    # --- Plain scalar ---

    private def try_fast_plain_scalar : String?
      # Fast path: scan a single-line plain scalar entirely via byte ops.
      # Only works for string input (no IO compaction issues) and single-line content.
      return nil if @io

      length = 0
      last_content = 0 # byte offset of last non-space char + 1

      loop do
        byte_pos = @pos + length
        break if byte_pos >= @buffer.bytesize
        b = @buffer.to_unsafe[byte_pos]
        # End on break or EOF
        break if b == '\n'.ord || b == '\r'.ord
        # Tab ends a plain scalar value
        break if b == '\t'.ord
        # Flow indicators in flow context
        if @flow_level > 0
          break if b == ','.ord || b == '['.ord || b == ']'.ord || b == '{'.ord || b == '}'.ord
        end
        # Comment preceded by blank
        if b == '#'.ord && length > 0
          pb = @buffer.to_unsafe[@pos + length - 1]
          break if pb == ' '.ord || pb == '\t'.ord
        end
        # Key separator: ':' followed by blank/break/eof or flow indicator
        if b == ':'.ord
          next_pos = @pos + length + 1
          nb = next_pos < @buffer.bytesize ? @buffer.to_unsafe[next_pos] : 0_u8
          break if nb == 0 || nb == ' '.ord || nb == '\t'.ord || nb == '\n'.ord || nb == '\r'.ord
          if @flow_level > 0
            break if nb == ','.ord || nb == '['.ord || nb == ']'.ord || nb == '{'.ord || nb == '}'.ord
          end
        end
        # Non-ASCII byte — bail entirely to slow path
        return nil if b >= 0x80
        length += 1
        last_content = length unless b == ' '.ord
      end

      # Trim trailing spaces
      length = last_content
      return nil if length == 0

      # Only use fast path if what follows is NOT a line break (could be multi-line)
      check_pos = @pos + last_content
      while check_pos < @buffer.bytesize && @buffer.to_unsafe[check_pos] == ' '.ord
        check_pos += 1
      end
      if check_pos < @buffer.bytesize
        after = @buffer.to_unsafe[check_pos]
        return nil if after == '\n'.ord || after == '\r'.ord
      end

      # Single-line scalar — extract directly from buffer
      @simple_key_allowed = false
      value = @buffer.byte_slice(@pos, length)
      advance(length)
      value
    end

    private def fetch_plain_scalar : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_plain_scalar
    end

    private def scan_plain_scalar : Nil
      start_mark = @mark
      push_context("plain scalar", start_mark)

      # Fast path: single-line plain scalar for string input
      fast = try_fast_plain_scalar
      if fast
        pop_context
        @tokens.push(Token.new(
          kind: TokenKind::SCALAR,
          start_mark: start_mark,
          end_mark: @mark,
          value: fast,
          style: ScalarStyle::PLAIN
        ))
        return
      end

      end_mark = start_mark
      indent = @indent + 1

      value = String.build do |io|
        pending_space = 0_u8 # 0=none, 1=space, 2=newline, 3=trailing breaks
        trailing_break_count = 0
        first = true

        loop do
          # Check for end conditions
          break if peek == '#' && is_blank_at?(-1)
          break if eof?

          # Check for document indicators at column 0
          if @mark.column == 0
            if (peek == '-' && peek(1) == '-' && peek(2) == '-' && is_blank_or_break_at?(3)) ||
               (peek == '.' && peek(1) == '.' && peek(2) == '.' && is_blank_or_break_at?(3))
              break
            end
          end

          length = 0
          scan_byte_pos = @pos
          loop do
            ensure_available(scan_byte_pos)
            break if scan_byte_pos >= @buffer.bytesize
            ch = decode_char_at(scan_byte_pos)
            break if is_blank_or_break?(ch) || ch == '\0'
            # In flow context, check for flow indicators
            if @flow_level > 0 && ch.in?(',', '[', ']', '{', '}')
              break
            end
            # Check for ': ' or ':' followed by flow indicator
            if ch == ':'
              next_byte_pos = scan_byte_pos + ch.bytesize
              ensure_available(next_byte_pos)
              next_ch = decode_char_at(next_byte_pos)
              if is_blank_or_break?(next_ch) || next_ch == '\0' ||
                 (@flow_level > 0 && next_ch.in?(',', '[', ']', '{', '}'))
                break
              end
            end
            scan_byte_pos += ch.bytesize
            length += 1
          end

          break if length == 0

          @simple_key_allowed = false

          if !first
            case pending_space
            when 1_u8 then io << ' '
            when 2_u8 then io << '\n'
            when 3_u8
              trailing_break_count.times { io << '\n' }
            end
          end
          pending_space = 0_u8
          trailing_break_count = 0
          first = false

          length.times do
            io << peek
            advance
          end

          end_mark = @mark

          # Consume whitespace/breaks after the content
          break if eof?
          break unless is_blank_or_break?(peek)

          # Collect whitespace
          break_count = 0

          while is_blank?(peek)
            advance
          end

          if is_break?(peek)
            scan_line_break
            break_count += 1
            @simple_key_allowed = true

            # Skip blank lines
            while is_break?(peek)
              scan_line_break
              break_count += 1
            end

            # Eat leading spaces on the next line to determine indentation
            while peek == ' '
              advance
            end

            # Check indentation — if next content is at or below the base indent, stop
            if @flow_level == 0 && @mark.column < indent
              break
            end

            if break_count == 1
              pending_space = 1_u8 # fold: single break becomes space
            else
              # Multiple breaks: emit all trailing breaks (all but first, which is consumed as fold)
              trailing_break_count = break_count - 1
              pending_space = 3_u8
            end
          else
            pending_space = 1_u8 # inline whitespace becomes space
          end
        end
      end

      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::SCALAR,
        start_mark: start_mark,
        end_mark: end_mark,
        value: value,
        style: ScalarStyle::PLAIN
      ))
    end

    # --- Indent management ---

    private def roll_indent(column : Int32, kind : TokenKind, mark : Mark, insert_at : Int32 = -1) : Nil
      return if @flow_level > 0
      return if @indent >= column

      @indents.push(@indent)
      @indent = column

      token = Token.new(
        kind: kind,
        start_mark: mark,
        end_mark: mark
      )

      if insert_at >= 0
        @tokens.insert(insert_at, token)
      else
        @tokens.push(token)
      end
    end

    private def unroll_indent(column : Int32) : Nil
      return if @flow_level > 0

      while @indent > column
        mark = @mark
        @indent = @indents.pop
        @tokens.push(Token.new(
          kind: TokenKind::BLOCK_END,
          start_mark: mark,
          end_mark: mark
        ))
      end
    end

    # --- Flow level ---

    private def increase_flow_level : Nil
      @flow_level += 1
      @simple_keys.push(SimpleKey.new)
    end

    private def decrease_flow_level : Nil
      @flow_level -= 1 if @flow_level > 0
      @simple_keys.pop if @simple_keys.size > 1
    end

    # --- Simple key management ---

    private def save_simple_key : Nil
      required = @flow_level > 0 ? false : (@indent == @mark.column)

      if @simple_key_allowed
        key = SimpleKey.new(
          possible: true,
          required: required,
          token_number: @tokens_parsed + @tokens.size,
          mark: @mark
        )
        remove_simple_key
        @simple_keys[-1] = key
      end
    end

    private def remove_simple_key : Nil
      key = @simple_keys.last
      if key.possible && key.required
        scanner_error("while scanning a simple key, could not find expected ':'", key.mark)
      end
      @simple_keys[-1] = SimpleKey.new(possible: false)
    end

    private def stale_simple_keys : Nil
      @simple_keys.each_with_index do |key, i|
        if key.possible
          # A simple key is stale if it's on a different line (block context only)
          if @flow_level == 0 && key.mark.line < @mark.line
            if key.required
              scanner_error("while scanning a simple key, could not find expected ':'", key.mark)
            end
            @simple_keys[i] = SimpleKey.new(possible: false)
          end
        end
      end
    end

    # --- Whitespace and line scanning ---

    private def scan_to_next_token : Nil
      loop do
        # Skip whitespace (tabs allowed in certain contexts)
        b = peek_byte
        while b == ' '.ord || ((@flow_level > 0 || !@simple_key_allowed) && b == '\t'.ord)
          advance
          b = peek_byte
        end

        # Skip comment
        if b == '#'.ord
          while !eof?
            b = peek_byte
            break if b == '\n'.ord || b == '\r'.ord || (b >= 0x80 && is_break?(peek))
            advance
          end
        end

        # Skip line break
        if is_break_byte?(peek_byte)
          skip_line
          @simple_key_allowed = true if @flow_level == 0
        else
          break
        end
      end
    end

    @[AlwaysInline]
    private def scan_line_break : Char
      ch = peek
      if ch == '\r' && peek(1) == '\n'
        advance(2)
        '\n'
      elsif ch == '\r' || ch == '\n'
        advance
        '\n'
      elsif ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
        advance
        '\n'
      else
        '\0'
      end
    end

    private def skip_line : Nil
      ch = peek
      if ch == '\r' && peek(1) == '\n'
        advance(2)
      elsif is_break?(ch)
        advance
      end
    end

    private def skip_blanks : Nil
      while peek == ' ' || peek == '\t'
        advance
      end
    end

    # --- Character classification ---

    @[AlwaysInline]
    private def is_blank?(ch : Char) : Bool
      ch == ' ' || ch == '\t'
    end

    @[AlwaysInline]
    private def is_blank_byte?(b : UInt8) : Bool
      b == ' '.ord || b == '\t'.ord
    end

    @[AlwaysInline]
    private def is_break?(ch : Char) : Bool
      ch == '\n' || ch == '\r' || ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
    end

    @[AlwaysInline]
    private def is_break_byte?(b : UInt8) : Bool
      b == '\n'.ord || b == '\r'.ord
    end

    @[AlwaysInline]
    private def is_blank_or_break?(ch : Char) : Bool
      is_blank?(ch) || is_break?(ch)
    end

    private def is_blank_at?(offset : Int32) : Bool
      if offset < 0
        # For checking character before current position, we can't easily go back
        # This is only used for '#' check where we assume whitespace before
        true
      else
        is_blank?(peek(offset))
      end
    end

    private def is_blank_or_break_at?(offset : Int32) : Bool
      ch = peek(offset)
      is_blank_or_break?(ch) || ch == '\0'
    end

    private def is_alpha?(ch : Char) : Bool
      ch.ascii_alphanumeric? || ch == '-' || ch == '_'
    end

    private def is_anchor_char?(ch : Char) : Bool
      ch.ascii_alphanumeric? || ch == '-' || ch == '_'
    end

    private def is_uri_char?(ch : Char) : Bool
      ch.ascii_alphanumeric? || ch.in?('-', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',',
        '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']', '%', '#')
    end

    private def is_plain_scalar_start?(ch : Char, next_ch : Char) : Bool
      return false if is_blank_or_break?(ch) || ch == '\0'
      return false if ch.in?('-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`')
      true
    end

    # --- Error ---

    private def push_context(description : String, mark : Mark) : Nil
      @context_stack.push({description, mark})
    end

    private def pop_context : Nil
      @context_stack.pop?
    end

    private def scanner_error(message : String, mark : Mark) : NoReturn
      context_info = if ctx = @context_stack.last?
                       desc, ctx_mark = ctx
                       "while scanning a #{desc} started at line #{ctx_mark.line + 1} column #{ctx_mark.column + 1}"
                     else
                       nil
                     end
      source_snippet = get_source_line(mark.line)
      raise ParseException.new(message, mark.line + 1, mark.column + 1,
        context_info: context_info, source_snippet: source_snippet)
    end

    # --- Reader methods (inlined) ---

    def peek(offset : Int32 = 0) : Char
      byte_pos = @pos
      # Walk forward offset characters from current byte position
      offset.times do
        ensure_available(byte_pos)
        return '\0' if byte_pos >= @buffer.bytesize
        byte_pos += char_bytesize_at(byte_pos)
      end
      ensure_available(byte_pos)
      return '\0' if byte_pos >= @buffer.bytesize
      decode_char_at(byte_pos)
    end

    @[AlwaysInline]
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
      # length is in characters
      String.build(length) do |io|
        byte_pos = @pos
        length.times do
          ensure_available(byte_pos)
          break if byte_pos >= @buffer.bytesize
          ch = decode_char_at(byte_pos)
          io << ch
          byte_pos += ch.bytesize
        end
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
        ch = decode_char_at(@pos)
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

    @[AlwaysInline]
    def eof? : Bool
      ensure_available(@pos)
      @pos >= @buffer.bytesize
    end

    @[AlwaysInline]
    private def decode_char_at(byte_pos : Int32) : Char
      return '\0' if byte_pos >= @buffer.bytesize
      first = @buffer.to_unsafe[byte_pos]
      if first < 0x80
        first.unsafe_chr
      else
        reader = Char::Reader.new(@buffer)
        reader.pos = byte_pos
        reader.current_char
      end
    end

    @[AlwaysInline]
    private def char_bytesize_at(byte_pos : Int32) : Int32
      return 1 if byte_pos >= @buffer.bytesize
      first = @buffer.to_unsafe[byte_pos]
      if first < 0x80
        1
      elsif first < 0xE0
        2
      elsif first < 0xF0
        3
      else
        4
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
      transcoded = transcode_utf16_bytes(raw, big_endian)

      @buffer = transcoded
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
                          0xFFFD_u32
                        end
                      else
                        code_unit.to_u32
                      end

          io << codepoint.chr
        end
      end
    end

    @[AlwaysInline]
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

      bytes_read = io.read(@raw_buffer)
      if bytes_read == 0
        @eof = true
        return false
      end

      # Compact unread portion + new data into a single allocation
      remaining = @buffer.bytesize - @pos
      @buffer = String.build(remaining + bytes_read) do |sb|
        if remaining > 0
          sb.write(@buffer.to_slice[@pos, remaining])
        end
        sb.write(@raw_buffer[0, bytes_read])
      end
      @pos = 0
      true
    end
  end
end
