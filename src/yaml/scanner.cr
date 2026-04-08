module Yaml
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

    @reader : Reader
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

    def initialize(input : String | IO)
      @reader = Reader.new(input)
      @tokens = Deque(Token).new
      @tokens_parsed = 0
      @token_available = false
      @stream_start_produced = false
      @stream_end_produced = false
      @indent = -1
      @indents = [] of Int32
      @simple_key_allowed = false
      @simple_keys = [SimpleKey.new]
      @flow_level = 0
      @context_stack = [] of {String, Mark}
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
      unroll_indent(@reader.mark.column)

      return fetch_stream_end if @reader.eof?

      ch = @reader.peek
      next_ch = @reader.peek(1)

      case
      when ch == '%' && @reader.mark.column == 0
        fetch_directive
      when ch == '-' && check_document_indicator('-')
        fetch_document_indicator(TokenKind::DOCUMENT_START)
      when ch == '.' && check_document_indicator('.')
        fetch_document_indicator(TokenKind::DOCUMENT_END)
      when ch == '['
        fetch_flow_collection_start(TokenKind::FLOW_SEQUENCE_START)
      when ch == '{'
        fetch_flow_collection_start(TokenKind::FLOW_MAPPING_START)
      when ch == ']'
        fetch_flow_collection_end(TokenKind::FLOW_SEQUENCE_END)
      when ch == '}'
        fetch_flow_collection_end(TokenKind::FLOW_MAPPING_END)
      when ch == ','
        fetch_flow_entry
      when ch == '-' && is_blank_or_break_at?(1)
        fetch_block_entry
      when ch == '?' && (@flow_level > 0 || is_blank_or_break_at?(1))
        fetch_key
      when ch == ':' && (@flow_level > 0 || is_blank_or_break_at?(1))
        fetch_value
      when ch == '*'
        fetch_alias
      when ch == '&'
        fetch_anchor
      when ch == '!'
        fetch_tag
      when ch == '|' && @flow_level == 0
        fetch_block_scalar(literal: true)
      when ch == '>' && @flow_level == 0
        fetch_block_scalar(literal: false)
      when ch == '\''
        fetch_flow_scalar(single: true)
      when ch == '"'
        fetch_flow_scalar(single: false)
      when is_plain_scalar_start?(ch, next_ch)
        fetch_plain_scalar
      else
        scanner_error("found character that cannot start any token", @reader.mark)
      end
    end

    # --- Stream start/end ---

    private def fetch_stream_start : Nil
      @stream_start_produced = true
      @simple_key_allowed = true
      mark = @reader.mark
      token = Token.new(
        kind: TokenKind::STREAM_START,
        start_mark: mark,
        end_mark: mark,
        encoding: @reader.encoding
      )
      @tokens.push(token)
    end

    private def fetch_stream_end : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      @stream_end_produced = true
      mark = @reader.mark
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
      start_mark = @reader.mark
      push_context("directive", start_mark)
      @reader.advance # skip '%'

      name = scan_directive_name(start_mark)

      case name
      when "YAML"
        major, minor = scan_version_directive_value(start_mark)
        scan_directive_trailing(start_mark)
        @tokens.push(Token.new(
          kind: TokenKind::VERSION_DIRECTIVE,
          start_mark: start_mark,
          end_mark: @reader.mark,
          major: major,
          minor: minor
        ))
      when "TAG"
        handle, prefix = scan_tag_directive_value(start_mark)
        scan_directive_trailing(start_mark)
        @tokens.push(Token.new(
          kind: TokenKind::TAG_DIRECTIVE,
          start_mark: start_mark,
          end_mark: @reader.mark,
          value: handle,
          suffix: prefix
        ))
      else
        # Unknown directive — skip to end of line
        while !@reader.eof? && !is_break?(@reader.peek)
          @reader.advance
        end
        scan_directive_trailing(start_mark)
      end
      pop_context
    end

    private def scan_directive_name(start_mark : Mark) : String
      value = String.build do |io|
        while is_alpha?(@reader.peek)
          io << @reader.peek
          @reader.advance
        end
      end
      if value.empty?
        scanner_error("while scanning a directive, did not find expected directive name", start_mark)
      end
      unless @reader.eof? || is_blank_or_break?(@reader.peek)
        scanner_error("while scanning a directive, found unexpected non-alphabetical character", start_mark)
      end
      value
    end

    private def scan_version_directive_value(start_mark : Mark) : {Int32, Int32}
      skip_blanks
      major = scan_version_directive_number(start_mark)
      unless @reader.peek == '.'
        scanner_error("while scanning a %YAML directive, did not find expected digit or '.'", start_mark)
      end
      @reader.advance # skip '.'
      minor = scan_version_directive_number(start_mark)
      {major, minor}
    end

    private def scan_version_directive_number(start_mark : Mark) : Int32
      value = 0
      count = 0
      while @reader.peek.ascii_number?
        value = value * 10 + (@reader.peek.ord - '0'.ord)
        @reader.advance
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
      if @reader.peek == '#'
        while !@reader.eof? && !is_break?(@reader.peek)
          @reader.advance
        end
      end
      unless @reader.eof? || is_break?(@reader.peek)
        scanner_error("while scanning a directive, did not find expected comment or line break", start_mark)
      end
      skip_line
    end

    # --- Document indicators ---

    private def check_document_indicator(ch : Char) : Bool
      return false unless @reader.mark.column == 0
      @reader.peek == ch && @reader.peek(1) == ch && @reader.peek(2) == ch &&
        (@reader.eof? || is_blank_or_break_at?(3))
    end

    private def fetch_document_indicator(kind : TokenKind) : Nil
      unroll_indent(-1)
      remove_simple_key
      @simple_key_allowed = false
      start_mark = @reader.mark
      @reader.advance(3)
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @reader.mark
      ))
    end

    # --- Flow collection start/end ---

    private def fetch_flow_collection_start(kind : TokenKind) : Nil
      save_simple_key
      increase_flow_level
      @simple_key_allowed = true
      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @reader.mark
      ))
    end

    private def fetch_flow_collection_end(kind : TokenKind) : Nil
      remove_simple_key
      decrease_flow_level
      @simple_key_allowed = false
      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @reader.mark
      ))
    end

    # --- Flow entry ---

    private def fetch_flow_entry : Nil
      remove_simple_key
      @simple_key_allowed = true
      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: TokenKind::FLOW_ENTRY,
        start_mark: start_mark,
        end_mark: @reader.mark
      ))
    end

    # --- Block entry ---

    private def fetch_block_entry : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error("block sequence entries are not allowed in this context", @reader.mark)
        end
        roll_indent(@reader.mark.column, TokenKind::BLOCK_SEQUENCE_START, @reader.mark)
      end
      @simple_key_allowed = true
      remove_simple_key
      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: TokenKind::BLOCK_ENTRY,
        start_mark: start_mark,
        end_mark: @reader.mark
      ))
    end

    # --- Key ---

    private def fetch_key : Nil
      if @flow_level == 0
        unless @simple_key_allowed
          scanner_error("mapping keys are not allowed in this context", @reader.mark)
        end
        roll_indent(@reader.mark.column, TokenKind::BLOCK_MAPPING_START, @reader.mark)
      end
      @simple_key_allowed = true
      remove_simple_key
      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: TokenKind::KEY,
        start_mark: start_mark,
        end_mark: @reader.mark
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
            scanner_error("mapping values are not allowed in this context", @reader.mark)
          end
          roll_indent(@reader.mark.column, TokenKind::BLOCK_MAPPING_START, @reader.mark)
        end
        @simple_key_allowed = @flow_level == 0
      end

      start_mark = @reader.mark
      @reader.advance
      @tokens.push(Token.new(
        kind: TokenKind::VALUE,
        start_mark: start_mark,
        end_mark: @reader.mark
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
      start_mark = @reader.mark
      push_context(kind == TokenKind::ALIAS ? "alias" : "anchor", start_mark)
      @reader.advance # skip '*' or '&'

      value = String.build do |io|
        while is_anchor_char?(@reader.peek)
          io << @reader.peek
          @reader.advance
        end
      end

      if value.empty?
        context = kind == TokenKind::ALIAS ? "alias" : "anchor"
        scanner_error("while scanning an #{context}, did not find expected alphabetic or numeric character", start_mark)
      end

      unless @reader.eof? || is_blank_or_break?(@reader.peek) ||
             @reader.peek.in?(',', '[', ']', '{', '}', '?', ':', '%', '@', '`')
        context = kind == TokenKind::ALIAS ? "alias" : "anchor"
        scanner_error("while scanning an #{context}, found unexpected character", start_mark)
      end

      pop_context
      @tokens.push(Token.new(
        kind: kind,
        start_mark: start_mark,
        end_mark: @reader.mark,
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
      start_mark = @reader.mark
      push_context("tag", start_mark)
      @reader.advance # skip first '!'

      handle : String
      suffix : String
      ch = @reader.peek

      if ch == '<'
        # Verbatim tag: !<uri>
        @reader.advance # skip '<'
        handle = ""
        suffix = scan_tag_uri(directive: false, start_mark: start_mark)
        unless @reader.peek == '>'
          scanner_error("while scanning a tag, did not find the expected '>'", start_mark)
        end
        @reader.advance # skip '>'
      elsif ch == '!'
        # Secondary tag handle: !!suffix
        @reader.advance # skip second '!'
        handle = "!!"
        suffix = scan_tag_uri(directive: false, start_mark: start_mark, allow_empty: true)
      elsif is_blank_or_break?(ch) || @reader.eof?
        # Primary tag: just !
        handle = "!"
        suffix = ""
      elsif is_alpha?(ch)
        # Could be !handle!suffix or !suffix
        first_part = String.build do |io|
          while is_alpha?(@reader.peek)
            io << @reader.peek
            @reader.advance
          end
        end
        if @reader.peek == '!'
          # Named tag handle: !handle!suffix
          @reader.advance # skip trailing '!'
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

      unless @reader.eof? || is_blank_or_break?(@reader.peek) || (@flow_level > 0 && @reader.peek == ',')
        scanner_error("while scanning a tag, did not find expected whitespace or line break", start_mark)
      end

      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::TAG,
        start_mark: start_mark,
        end_mark: @reader.mark,
        value: handle,
        suffix: suffix
      ))
    end

    private def scan_tag_handle(directive : Bool, start_mark : Mark) : String
      ch = @reader.peek
      unless ch == '!'
        context = directive ? "while scanning a %TAG directive" : "while scanning a tag"
        scanner_error("#{context}, did not find expected '!'", start_mark)
      end

      value = String.build do |io|
        io << '!'
        @reader.advance

        if is_alpha?(@reader.peek)
          while is_alpha?(@reader.peek)
            io << @reader.peek
            @reader.advance
          end
          unless @reader.peek == '!'
            if directive
              scanner_error("while scanning a %TAG directive, did not find expected '!'", start_mark)
            end
            # For non-directive tags, return what we have
          else
            io << '!'
            @reader.advance
          end
        end
      end
      value
    end

    private def scan_tag_uri(directive : Bool, start_mark : Mark, allow_empty : Bool = false) : String
      value = String.build do |io|
        loop do
          while is_uri_char?(@reader.peek)
            if @reader.peek == '%'
              io << scan_uri_escapes(start_mark)
            else
              io << @reader.peek
              @reader.advance
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
        break unless @reader.peek == '%'
        @reader.advance # skip '%'
        high = @reader.peek
        @reader.advance
        low = @reader.peek
        @reader.advance
        unless high.hex? && low.hex?
          scanner_error("while scanning a tag, found invalid URI escape", start_mark)
        end
        bytes << "#{high}#{low}".to_u8(16)
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
      start_mark = @reader.mark
      push_context(literal ? "literal block scalar" : "folded block scalar", start_mark)
      @reader.advance # skip '|' or '>'

      # Scan the header: chomping and indent indicator
      chomping = 0  # 0=clip, 1=strip, -1=keep
      increment = 0 # explicit indent
      trailing_blank = false
      leading_break = ""

      # Chomping indicator
      ch = @reader.peek
      if ch == '+' || ch == '-'
        chomping = ch == '+' ? -1 : 1
        @reader.advance
        ch = @reader.peek
        if ch.ascii_number?
          increment = ch.ord - '0'.ord
          if increment == 0
            scanner_error("while scanning a block scalar, found an indentation indicator equal to 0", start_mark)
          end
          @reader.advance
        end
      elsif ch.ascii_number?
        increment = ch.ord - '0'.ord
        if increment == 0
          scanner_error("while scanning a block scalar, found an indentation indicator equal to 0", start_mark)
        end
        @reader.advance
        ch = @reader.peek
        if ch == '+' || ch == '-'
          chomping = ch == '+' ? -1 : 1
          @reader.advance
        end
      end

      # Eat trailing blanks and comment
      skip_blanks
      if @reader.peek == '#'
        while !@reader.eof? && !is_break?(@reader.peek)
          @reader.advance
        end
      end

      unless @reader.eof? || is_break?(@reader.peek)
        scanner_error("while scanning a block scalar, did not find expected comment or line break", start_mark)
      end

      skip_line

      end_mark = @reader.mark
      indent = if increment > 0
                 @indent >= 0 ? @indent + increment : increment
               else
                 0
               end

      # Scan the block scalar content
      value = String.build do |io|
        breaks = String::Builder.new
        leading_blank = false
        max_indent = 0

        # Determine indentation if not explicitly given
        if indent == 0
          # Auto-detect: skip blank lines, find first non-blank line's indent
          loop do
            while !@reader.eof? && @reader.mark.column < 1024 && @reader.peek == ' '
              @reader.advance
            end
            if @reader.mark.column > max_indent
              max_indent = @reader.mark.column
            end
            if is_break?(@reader.peek) && !@reader.eof?
              breaks << scan_line_break
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
          if @reader.mark.column == indent && !@reader.eof?
            trailing_blank = is_blank?(@reader.peek)

            if !literal && !first && !leading_blank && !trailing_blank &&
               breaks.to_s.count('\n') <= 1 && io.bytesize > 0
              # Fold: single break between non-blank lines becomes space
              io << ' '
            else
              io << breaks.to_s
            end
            breaks = String::Builder.new
            leading_blank = is_blank?(@reader.peek)

            while !@reader.eof? && !is_break?(@reader.peek)
              io << @reader.peek
              @reader.advance
            end
            first = false
            end_mark = @reader.mark
            # Capture the line break (will be processed in next iteration)
            if !@reader.eof? && is_break?(@reader.peek)
              breaks << scan_line_break
            end
          else
            break
          end

          # Eat blank lines (breaks)
          loop do
            # Eat indentation up to the block's indent level
            while !@reader.eof? && @reader.mark.column < indent && @reader.peek == ' '
              @reader.advance
            end

            if is_break?(@reader.peek) && !@reader.eof?
              breaks << scan_line_break
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
      start_mark = @reader.mark
      push_context(single ? "single-quoted scalar" : "double-quoted scalar", start_mark)
      @reader.advance # skip quote

      value = String.build do |io|
        loop do
          # Check for end of scalar or EOF
          if @reader.eof?
            scanner_error("while scanning a quoted scalar, found unexpected end of stream", start_mark)
          end

          if single
            # Single-quoted scalar
            if @reader.peek == '\''
              if @reader.peek(1) == '\''
                io << '\''
                @reader.advance(2)
              else
                break
              end
            elsif is_break?(@reader.peek)
              # Line break — fold to space
              whitespaces = scan_flow_scalar_breaks(start_mark)
              if whitespaces.empty?
                io << ' '
              else
                io << whitespaces
              end
            else
              io << @reader.peek
              @reader.advance
            end
          else
            # Double-quoted scalar
            if @reader.peek == '"'
              break
            elsif @reader.peek == '\\'
              @reader.advance
              ch = @reader.peek
              @reader.advance
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
                  # Escaped line break
                  whitespaces = scan_flow_scalar_breaks(start_mark)
                  if whitespaces.empty?
                    # Just skip the line break
                  else
                    io << whitespaces
                  end
                else
                  scanner_error("while scanning a double-quoted scalar, found unknown escape character '#{ch}'", start_mark)
                end
              end
            elsif is_break?(@reader.peek)
              whitespaces = scan_flow_scalar_breaks(start_mark)
              if whitespaces.empty?
                io << ' '
              else
                io << whitespaces
              end
            else
              io << @reader.peek
              @reader.advance
            end
          end
        end
      end

      @reader.advance # skip closing quote
      pop_context
      @tokens.push(Token.new(
        kind: TokenKind::SCALAR,
        start_mark: start_mark,
        end_mark: @reader.mark,
        value: value,
        style: single ? ScalarStyle::SINGLE_QUOTED : ScalarStyle::DOUBLE_QUOTED
      ))
    end

    private def scan_hex_escape(length : Int32, start_mark : Mark) : Char
      code = 0
      length.times do
        ch = @reader.peek
        unless ch.hex?
          scanner_error("while scanning a double-quoted scalar, did not find expected hex digit", start_mark)
        end
        code = code * 16 + ch.to_i(16)
        @reader.advance
      end
      code.chr
    end

    private def scan_flow_scalar_breaks(start_mark : Mark) : String
      # Skip whitespace and line breaks, collecting extra line breaks
      breaks = String.build do |io|
        # First, skip leading blanks
        loop do
          while is_blank?(@reader.peek)
            @reader.advance
          end
          if is_break?(@reader.peek)
            lb = scan_line_break
            io << lb
          else
            break
          end
        end
      end
      # If we got 0 or 1 line breaks, return empty (the caller adds a space for single break)
      # If we got 2+ line breaks, return all but the first (which becomes the space/fold)
      count = breaks.count('\n') + breaks.count('\r')
      if count <= 1
        ""
      else
        # Return the extra breaks beyond the first
        breaks[1..]? || ""
      end
    end

    # --- Plain scalar ---

    private def fetch_plain_scalar : Nil
      save_simple_key
      @simple_key_allowed = false
      scan_plain_scalar
    end

    private def scan_plain_scalar : Nil
      start_mark = @reader.mark
      push_context("plain scalar", start_mark)
      end_mark = start_mark
      indent = @indent + 1

      value = String.build do |io|
        spaces = String::Builder.new
        first = true

        loop do
          # Check for end conditions
          break if @reader.peek == '#' && is_blank_at?(-1)
          break if @reader.eof?

          # Check for document indicators at column 0
          if @reader.mark.column == 0
            if (@reader.peek == '-' && @reader.peek(1) == '-' && @reader.peek(2) == '-' && is_blank_or_break_at?(3)) ||
               (@reader.peek == '.' && @reader.peek(1) == '.' && @reader.peek(2) == '.' && is_blank_or_break_at?(3))
              break
            end
          end

          length = 0
          loop do
            ch = @reader.peek(length)
            break if is_blank_or_break?(ch) || ch == '\0'
            # In flow context, check for flow indicators
            if @flow_level > 0 && ch.in?(',', '[', ']', '{', '}')
              break
            end
            # Check for ': ' or ':' followed by flow indicator
            if ch == ':' && (is_blank_or_break_at?(length + 1) ||
               (@flow_level > 0 && @reader.peek(length + 1).in?(',', '[', ']', '{', '}')))
              break
            end
            length += 1
          end

          break if length == 0

          @simple_key_allowed = false

          if !first
            io << spaces.to_s
          end
          spaces = String::Builder.new
          first = false

          length.times do
            io << @reader.peek
            @reader.advance
          end

          end_mark = @reader.mark

          # Consume whitespace/breaks after the content
          break if @reader.eof?
          break unless is_blank_or_break?(@reader.peek)

          # Collect whitespace
          ws_count = 0
          break_count = 0
          trailing_breaks = String::Builder.new

          while is_blank?(@reader.peek)
            @reader.advance
          end

          if is_break?(@reader.peek)
            lb = scan_line_break
            break_count += 1
            @simple_key_allowed = true

            # Skip blank lines
            while is_break?(@reader.peek)
              trailing_breaks << scan_line_break
              break_count += 1
            end

            # Eat leading spaces on the next line to determine indentation
            while @reader.peek == ' '
              @reader.advance
            end

            # Check indentation — if next content is at or below the base indent, stop
            if @flow_level == 0 && @reader.mark.column < indent
              break
            end

            if break_count == 1 && trailing_breaks.bytesize == 0
              spaces << ' '
            else
              if trailing_breaks.bytesize > 0
                spaces << trailing_breaks.to_s
              else
                spaces << '\n'
              end
            end
          else
            spaces << ' '
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
        mark = @reader.mark
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
      required = @flow_level > 0 ? false : (@indent == @reader.mark.column)

      if @simple_key_allowed
        key = SimpleKey.new(
          possible: true,
          required: required,
          token_number: @tokens_parsed + @tokens.size,
          mark: @reader.mark
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
          if @flow_level == 0 && key.mark.line < @reader.mark.line
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
        while @reader.peek == ' ' || ((@flow_level > 0 || !@simple_key_allowed) && @reader.peek == '\t')
          @reader.advance
        end

        # Skip comment
        if @reader.peek == '#'
          while !@reader.eof? && !is_break?(@reader.peek)
            @reader.advance
          end
        end

        # Skip line break
        if is_break?(@reader.peek)
          skip_line
          @simple_key_allowed = true if @flow_level == 0
        else
          break
        end
      end
    end

    private def scan_line_break : String
      ch = @reader.peek
      if ch == '\r' && @reader.peek(1) == '\n'
        @reader.advance(2)
        "\n"
      elsif ch == '\r' || ch == '\n'
        @reader.advance
        "\n"
      elsif ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
        @reader.advance
        "\n"
      else
        ""
      end
    end

    private def skip_line : Nil
      ch = @reader.peek
      if ch == '\r' && @reader.peek(1) == '\n'
        @reader.advance(2)
      elsif is_break?(ch)
        @reader.advance
      end
    end

    private def skip_blanks : Nil
      while @reader.peek == ' ' || @reader.peek == '\t'
        @reader.advance
      end
    end

    # --- Character classification ---

    private def is_blank?(ch : Char) : Bool
      ch == ' ' || ch == '\t'
    end

    private def is_break?(ch : Char) : Bool
      ch == '\n' || ch == '\r' || ch == '\u0085' || ch == '\u2028' || ch == '\u2029'
    end

    private def is_blank_or_break?(ch : Char) : Bool
      is_blank?(ch) || is_break?(ch)
    end

    private def is_blank_at?(offset : Int32) : Bool
      if offset < 0
        # For checking character before current position, we can't easily go back
        # This is only used for '#' check where we assume whitespace before
        true
      else
        is_blank?(@reader.peek(offset))
      end
    end

    private def is_blank_or_break_at?(offset : Int32) : Bool
      ch = @reader.peek(offset)
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
      source_snippet = @reader.get_source_line(mark.line)
      raise ParseException.new(message, mark.line + 1, mark.column + 1,
        context_info: context_info, source_snippet: source_snippet)
    end
  end
end
