module YAML
  class Emitter
    private enum EmitterState
      STREAM_START
      FIRST_DOCUMENT_START
      DOCUMENT_START
      DOCUMENT_CONTENT
      DOCUMENT_END
      FLOW_SEQUENCE_FIRST_ITEM
      FLOW_SEQUENCE_ITEM
      FLOW_MAPPING_FIRST_KEY
      FLOW_MAPPING_KEY
      FLOW_MAPPING_SIMPLE_VALUE
      FLOW_MAPPING_VALUE
      BLOCK_SEQUENCE_FIRST_ITEM
      BLOCK_SEQUENCE_ITEM
      BLOCK_MAPPING_FIRST_KEY
      BLOCK_MAPPING_KEY
      BLOCK_MAPPING_SIMPLE_VALUE
      BLOCK_MAPPING_VALUE
      END
    end

    private struct ScalarAnalysis
      property value : String
      property multiline : Bool
      property flow_plain_allowed : Bool
      property block_plain_allowed : Bool
      property single_quoted_allowed : Bool
      property block_allowed : Bool

      def initialize(
        @value : String,
        @multiline : Bool = false,
        @flow_plain_allowed : Bool = true,
        @block_plain_allowed : Bool = true,
        @single_quoted_allowed : Bool = true,
        @block_allowed : Bool = true
      )
      end
    end

    @io : IO
    @state : EmitterState
    @states : Array(EmitterState)
    @events : Deque(Event)
    @indents : Array(Int32)
    @indent : Int32
    @flow_level : Int32
    @best_indent : Int32
    @best_width : Int32
    @canonical : Bool
    @unicode : Bool
    @line_break : String
    @column : Int32
    @whitespace : Bool
    @indention : Bool
    @open_ended : Bool
    @scalar_data : ScalarAnalysis?

    def initialize(@io : IO)
      @state = EmitterState::STREAM_START
      @states = [] of EmitterState
      @events = Deque(Event).new
      @indents = [] of Int32
      @indent = 0
      @flow_level = 0
      @best_indent = 2
      @best_width = 80
      @canonical = false
      @unicode = true
      @line_break = "\n"
      @column = 0
      @whitespace = true
      @indention = true
      @open_ended = false
      @scalar_data = nil
    end

    property best_indent : Int32
    property best_width : Int32
    property canonical : Bool
    property unicode : Bool

    def emit(event : Event) : Nil
      @events.push(event)
      while !need_more_events?
        ev = @events.shift
        emit_event(ev)
      end
    end

    def flush : Nil
      @io.flush if @io.responds_to?(:flush)
    end

    private def need_more_events? : Bool
      return true if @events.empty?

      event = @events.first
      case event.kind
      when .document_start?
        need_events(1)
      when .sequence_start?
        need_events(2)
      when .mapping_start?
        need_events(3)
      else
        false
      end
    end

    private def need_events(count : Int32) : Bool
      level = 0
      @events.each_with_index do |event, i|
        next if i == 0
        case event.kind
        when .sequence_start?, .mapping_start?, .document_start?
          level += 1
        when .sequence_end?, .mapping_end?, .document_end?, .stream_end?
          level -= 1
        end
        return false if level == 0
      end
      @events.size < (count + 1)
    end

    private def emit_event(event : Event) : Nil
      case @state
      when .stream_start?
        emit_stream_start(event)
      when .first_document_start?
        emit_document_start(event, first: true)
      when .document_start?
        emit_document_start(event, first: false)
      when .document_content?
        emit_document_content(event)
      when .document_end?
        emit_document_end(event)
      when .flow_sequence_first_item?
        emit_flow_sequence_item(event, first: true)
      when .flow_sequence_item?
        emit_flow_sequence_item(event, first: false)
      when .flow_mapping_first_key?
        emit_flow_mapping_key(event, first: true)
      when .flow_mapping_key?
        emit_flow_mapping_key(event, first: false)
      when .flow_mapping_simple_value?
        emit_flow_mapping_value(event, simple: true)
      when .flow_mapping_value?
        emit_flow_mapping_value(event, simple: false)
      when .block_sequence_first_item?
        emit_block_sequence_item(event, first: true)
      when .block_sequence_item?
        emit_block_sequence_item(event, first: false)
      when .block_mapping_first_key?
        emit_block_mapping_key(event, first: true)
      when .block_mapping_key?
        emit_block_mapping_key(event, first: false)
      when .block_mapping_simple_value?
        emit_block_mapping_value(event, simple: true)
      when .block_mapping_value?
        emit_block_mapping_value(event, simple: false)
      when .end?
        # ignore
      end
    end

    # --- Stream ---

    private def emit_stream_start(event : Event) : Nil
      @state = EmitterState::FIRST_DOCUMENT_START
    end

    # --- Document ---

    private def emit_document_start(event : Event, first : Bool) : Nil
      if event.kind.document_start?
        implicit = event.implicit

        unless implicit
          if @open_ended
            write_indicator("...", need_whitespace: true)
            write_indent
          end
          write_indicator("---", need_whitespace: true)
          if @canonical
            write_indent
          else
            @whitespace = true
          end
        end

        @state = EmitterState::DOCUMENT_CONTENT
      elsif event.kind.stream_end?
        if @open_ended
          write_indicator("...", need_whitespace: true)
          write_indent
        end
        @state = EmitterState::END
        flush
      else
        emitter_error("expected DOCUMENT-START or STREAM-END")
      end
    end

    private def emit_document_content(event : Event) : Nil
      @states.push(EmitterState::DOCUMENT_END)
      emit_node(event)
    end

    private def emit_document_end(event : Event) : Nil
      if event.kind.document_end?
        write_indent
        unless event.implicit
          write_indicator("...", need_whitespace: true)
          write_indent
        end
        @state = EmitterState::DOCUMENT_START
      else
        emitter_error("expected DOCUMENT-END")
      end
    end

    # --- Node ---

    private def emit_node(event : Event) : Nil
      case event.kind
      when .alias?
        emit_alias(event)
      when .scalar?
        emit_scalar(event)
      when .sequence_start?
        emit_sequence_start(event)
      when .mapping_start?
        emit_mapping_start(event)
      else
        emitter_error("expected ALIAS, SCALAR, SEQUENCE-START, or MAPPING-START, got #{event.kind}")
      end
    end

    private def emit_alias(event : Event) : Nil
      process_anchor("*", event.anchor)
      @state = @states.pop
    end

    private def emit_scalar(event : Event) : Nil
      process_anchor("&", event.anchor)
      process_tag(event)
      process_scalar(event)
      @state = @states.pop
    end

    private def emit_sequence_start(event : Event) : Nil
      process_anchor("&", event.anchor)
      process_tag(event)

      if @flow_level > 0 || @canonical || event.sequence_style.flow? || check_empty_sequence?
        @state = EmitterState::FLOW_SEQUENCE_FIRST_ITEM
      else
        @state = EmitterState::BLOCK_SEQUENCE_FIRST_ITEM
      end
    end

    private def emit_mapping_start(event : Event) : Nil
      process_anchor("&", event.anchor)
      process_tag(event)

      if @flow_level > 0 || @canonical || event.mapping_style.flow? || check_empty_mapping?
        @state = EmitterState::FLOW_MAPPING_FIRST_KEY
      else
        @state = EmitterState::BLOCK_MAPPING_FIRST_KEY
      end
    end

    # --- Flow sequence ---

    private def emit_flow_sequence_item(event : Event, first : Bool) : Nil
      if first
        write_indicator("[", need_whitespace: true)
        increase_indent(flow: true)
        @flow_level += 1
      end

      if event.kind.sequence_end?
        @flow_level -= 1
        decrease_indent
        unless first
          # No trailing comma
        end
        write_indicator("]", need_whitespace: false)
        @state = @states.pop
        return
      end

      unless first
        write_indicator(",", need_whitespace: false)
      end

      if @canonical || @column > @best_width
        write_indent
      else
        write_raw(" ") unless first
      end

      @states.push(EmitterState::FLOW_SEQUENCE_ITEM)
      emit_node(event)
    end

    # --- Flow mapping ---

    private def emit_flow_mapping_key(event : Event, first : Bool) : Nil
      if first
        write_indicator("{", need_whitespace: true)
        increase_indent(flow: true)
        @flow_level += 1
      end

      if event.kind.mapping_end?
        @flow_level -= 1
        decrease_indent
        write_indicator("}", need_whitespace: false)
        @state = @states.pop
        return
      end

      unless first
        write_indicator(",", need_whitespace: false)
      end

      if @canonical || @column > @best_width
        write_indent
      else
        write_raw(" ") unless first
      end

      if check_simple_key?(event)
        @states.push(EmitterState::FLOW_MAPPING_SIMPLE_VALUE)
        emit_node(event)
      else
        write_indicator("?", need_whitespace: true)
        @states.push(EmitterState::FLOW_MAPPING_VALUE)
        emit_node(event)
      end
    end

    private def emit_flow_mapping_value(event : Event, simple : Bool) : Nil
      if simple
        write_indicator(":", need_whitespace: false)
        write_raw(" ")
      else
        if @canonical || @column > @best_width
          write_indent
        end
        write_indicator(":", need_whitespace: true)
        write_raw(" ")
      end
      @states.push(EmitterState::FLOW_MAPPING_KEY)
      emit_node(event)
    end

    # --- Block sequence ---

    private def emit_block_sequence_item(event : Event, first : Bool) : Nil
      if first
        increase_indent(flow: false)
      end

      if event.kind.sequence_end?
        decrease_indent
        @state = @states.pop
        return
      end

      write_indent
      write_indicator("-", need_whitespace: true)
      write_raw(" ")
      @states.push(EmitterState::BLOCK_SEQUENCE_ITEM)
      emit_node(event)
    end

    # --- Block mapping ---

    private def emit_block_mapping_key(event : Event, first : Bool) : Nil
      if first
        increase_indent(flow: false)
      end

      if event.kind.mapping_end?
        decrease_indent
        @state = @states.pop
        return
      end

      write_indent

      if check_simple_key?(event)
        @states.push(EmitterState::BLOCK_MAPPING_SIMPLE_VALUE)
        emit_node(event)
      else
        write_indicator("?", need_whitespace: true)
        write_raw(" ")
        @states.push(EmitterState::BLOCK_MAPPING_VALUE)
        emit_node(event)
      end
    end

    private def emit_block_mapping_value(event : Event, simple : Bool) : Nil
      if simple
        write_indicator(":", need_whitespace: false)
        write_raw(" ")
      else
        write_indent
        write_indicator(":", need_whitespace: true)
        write_raw(" ")
      end
      @states.push(EmitterState::BLOCK_MAPPING_KEY)
      emit_node(event)
    end

    # --- Process helpers ---

    private def process_anchor(indicator : String, anchor : String?) : Nil
      return unless anchor
      write_indicator(indicator, need_whitespace: true)
      write_raw(anchor)
      @whitespace = false
    end

    private def process_tag(event : Event) : Nil
      tag = event.tag
      return unless tag

      write_indicator(tag, need_whitespace: true)
      @whitespace = false
      write_raw(" ")
    end

    private def process_scalar(event : Event) : Nil
      value = event.value || ""
      style = select_scalar_style(event, value)

      case style
      when .plain?
        write_plain_scalar(value)
      when .single_quoted?
        write_single_quoted_scalar(value)
      when .double_quoted?
        write_double_quoted_scalar(value)
      when .literal?
        write_literal_scalar(value)
      when .folded?
        write_folded_scalar(value)
      else
        write_plain_scalar(value)
      end
    end

    private def select_scalar_style(event : Event, value : String) : ScalarStyle
      style = event.style

      # In flow context, only flow styles are allowed
      if @flow_level > 0
        case style
        when .literal?, .folded?
          style = ScalarStyle::DOUBLE_QUOTED
        end
      end

      # If no preference or PLAIN requested, decide automatically
      if style.any? || style.plain?
        if value.empty?
          # Empty scalar: prefer double-quoted in flow, plain in block
          return @flow_level > 0 ? ScalarStyle::DOUBLE_QUOTED : ScalarStyle::PLAIN
        end

        analysis = analyze_scalar(value)

        if style.plain? || style.any?
          if @flow_level > 0 && analysis.flow_plain_allowed
            return ScalarStyle::PLAIN
          elsif @flow_level == 0 && analysis.block_plain_allowed
            return ScalarStyle::PLAIN
          end
        end

        return ScalarStyle::DOUBLE_QUOTED if style.any?
      end

      # Validate the requested style is possible
      case style
      when .single_quoted?
        analysis = analyze_scalar(value)
        return analysis.single_quoted_allowed ? ScalarStyle::SINGLE_QUOTED : ScalarStyle::DOUBLE_QUOTED
      when .literal?, .folded?
        return @flow_level > 0 ? ScalarStyle::DOUBLE_QUOTED : style
      end

      style == ScalarStyle::ANY ? ScalarStyle::DOUBLE_QUOTED : style
    end

    private def analyze_scalar(value : String) : ScalarAnalysis
      return ScalarAnalysis.new(value, flow_plain_allowed: false, block_plain_allowed: false) if value.empty?

      multiline = false
      flow_plain_allowed = true
      block_plain_allowed = true
      single_quoted_allowed = true
      block_allowed = true

      # Check first character restrictions for plain scalars
      first = value[0]
      if first.in?('#', ',', '[', ']', '{', '}', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`')
        flow_plain_allowed = false
        block_plain_allowed = false
      end

      if first == '-' || first == ':' || first == '?'
        flow_plain_allowed = false
        if value.size > 1
          second = value[1]
          if second == ' ' || second == '\t' || second == '\n' || second == '\r'
            block_plain_allowed = false
          end
        else
          block_plain_allowed = false
        end
      end

      # Check for whitespace at start/end
      if first == ' ' || first == '\t'
        flow_plain_allowed = false
        block_plain_allowed = false
      end

      last = value[-1]
      if last == ' ' || last == '\t'
        flow_plain_allowed = false
        block_plain_allowed = false
      end

      # Scan characters
      previous_space = false
      previous_break = false

      value.each_char_with_index do |ch, i|
        if ch == '\n' || ch == '\r'
          multiline = true
        end

        # Check for flow indicators
        if ch.in?(',', '[', ']', '{', '}')
          flow_plain_allowed = false
        end

        # Check for ': ' pattern
        if ch == ':' && i + 1 < value.size
          next_ch = value[i + 1]
          if next_ch == ' ' || next_ch == '\t' || next_ch == '\n' || next_ch == '\r'
            flow_plain_allowed = false
            block_plain_allowed = false
          end
        end

        # Check for ' #' pattern
        if ch == '#' && i > 0
          prev = value[i - 1]
          if prev == ' ' || prev == '\t'
            flow_plain_allowed = false
            block_plain_allowed = false
          end
        end
      end

      # Trailing colon
      if last == ':'
        flow_plain_allowed = false
        block_plain_allowed = false
      end

      ScalarAnalysis.new(
        value: value,
        multiline: multiline,
        flow_plain_allowed: flow_plain_allowed,
        block_plain_allowed: block_plain_allowed,
        single_quoted_allowed: single_quoted_allowed,
        block_allowed: block_allowed
      )
    end

    # --- Scalar writers ---

    private def write_plain_scalar(value : String) : Nil
      @open_ended = false

      if value.empty?
        return
      end

      spaces = false
      breaks = false
      first = true

      value.each_char_with_index do |ch, i|
        if ch == ' '
          if !spaces && @column > @best_width && i > 0 && i + 1 < value.size && value[i + 1] != ' '
            write_indent
          else
            write_raw(ch)
          end
          spaces = true
          breaks = false
        elsif ch == '\n'
          if !breaks && first == false
            write_raw(@line_break)
          end
          write_raw(@line_break)
          @indention = true
          spaces = false
          breaks = true
        else
          if breaks
            write_indent
          end
          write_raw(ch)
          @open_ended = false
          spaces = false
          breaks = false
        end
        first = false
      end
    end

    private def write_single_quoted_scalar(value : String) : Nil
      write_indicator("'", need_whitespace: false)

      spaces = false
      breaks = false

      value.each_char_with_index do |ch, i|
        if ch == '\''
          write_raw("''")
          spaces = false
          breaks = false
        elsif ch == ' '
          if !spaces && @column > @best_width && i > 0 && i + 1 < value.size && value[i + 1] != ' '
            write_indent
          else
            write_raw(ch)
          end
          spaces = true
          breaks = false
        elsif ch == '\n'
          if !breaks
            write_raw(@line_break)
          end
          write_raw(@line_break)
          @indention = true
          spaces = false
          breaks = true
        else
          if breaks
            write_indent
          end
          write_raw(ch)
          spaces = false
          breaks = false
        end
      end

      write_indicator("'", need_whitespace: false)
    end

    private def write_double_quoted_scalar(value : String) : Nil
      write_indicator("\"", need_whitespace: false)

      value.each_char do |ch|
        case ch
        when '\0'     then write_raw("\\0")
        when '\u0007' then write_raw("\\a")
        when '\b'     then write_raw("\\b")
        when '\t'     then write_raw("\\t")
        when '\n'     then write_raw("\\n")
        when '\u000B' then write_raw("\\v")
        when '\f'     then write_raw("\\f")
        when '\r'     then write_raw("\\r")
        when '\e'     then write_raw("\\e")
        when '"'      then write_raw("\\\"")
        when '\\'     then write_raw("\\\\")
        when '\u0085' then write_raw("\\N")
        when '\u00A0' then write_raw("\\_")
        when '\u2028' then write_raw("\\L")
        when '\u2029' then write_raw("\\P")
        else
          if ch.ord < 0x20 && ch != '\t'
            write_raw("\\x")
            write_raw(ch.ord.to_s(16).rjust(2, '0'))
          elsif !@unicode && ch.ord > 0x7E
            if ch.ord <= 0xFFFF
              write_raw("\\u")
              write_raw(ch.ord.to_s(16).rjust(4, '0'))
            else
              write_raw("\\U")
              write_raw(ch.ord.to_s(16).rjust(8, '0'))
            end
          else
            write_raw(ch)
          end
        end
      end

      write_indicator("\"", need_whitespace: false)
    end

    private def write_literal_scalar(value : String) : Nil
      # Determine chomping
      chomping = if value.ends_with?('\n')
                   if value.ends_with?("\n\n") || value.size == 1
                     "+"
                   else
                     ""
                   end
                 else
                   "-"
                 end

      write_indicator("|#{chomping}", need_whitespace: true)
      write_indent

      previous_break = false
      value.each_char do |ch|
        if ch == '\n'
          write_raw(@line_break)
          @indention = true
          previous_break = true
        else
          if previous_break
            write_indent
          end
          write_raw(ch)
          @indention = false
          previous_break = false
        end
      end
    end

    private def write_folded_scalar(value : String) : Nil
      chomping = if value.ends_with?('\n')
                   if value.ends_with?("\n\n") || value.size == 1
                     "+"
                   else
                     ""
                   end
                 else
                   "-"
                 end

      write_indicator(">#{chomping}", need_whitespace: true)
      write_indent

      previous_break = false
      previous_space = false

      value.each_char_with_index do |ch, i|
        if ch == '\n'
          if !previous_break && !previous_space && i > 0
            # Check if next line starts with non-space
            if i + 1 < value.size && value[i + 1] != ' ' && value[i + 1] != '\n'
              write_raw(@line_break)
            end
          end
          write_raw(@line_break)
          @indention = true
          previous_break = true
          previous_space = false
        elsif ch == ' '
          if previous_break
            write_indent
          end
          write_raw(ch)
          previous_break = false
          previous_space = true
        else
          if previous_break
            write_indent
          end
          write_raw(ch)
          previous_break = false
          previous_space = false
        end
      end
    end

    # --- Check helpers ---

    private def check_empty_sequence? : Bool
      return false if @events.empty?
      @events.first.kind.sequence_end?
    end

    private def check_empty_mapping? : Bool
      return false if @events.empty?
      @events.first.kind.mapping_end?
    end

    private def check_simple_key?(event : Event) : Bool
      return false unless event.kind.scalar?
      value = event.value || ""
      value.size < 128
    end

    # --- Output helpers ---

    private def write_indicator(indicator : String, need_whitespace : Bool) : Nil
      if need_whitespace && !@whitespace
        write_raw(" ")
      end
      write_raw(indicator)
      @whitespace = indicator.ends_with?(' ')
      @indention = false
    end

    private def write_indent : Nil
      indent = @indent > 0 ? @indent : 0

      unless @indention || @column == 0
        write_raw(@line_break)
        @column = 0
      end

      if @column < indent
        n = indent - @column
        write_raw(" " * n)
      end

      @whitespace = true
      @indention = true
    end

    private def write_raw(ch : Char) : Nil
      @io << ch
      if ch == '\n'
        @column = 0
      else
        @column += 1
      end
    end

    private def write_raw(str : String) : Nil
      @io << str
      if str.includes?('\n')
        last_newline = str.rindex('\n')
        if last_newline
          @column = str.size - last_newline - 1
        end
      else
        @column += str.size
      end
    end

    private def increase_indent(flow : Bool) : Nil
      @indents.push(@indent)
      if flow
        @indent += @best_indent
      else
        @indent += @best_indent
      end
    end

    private def decrease_indent : Nil
      @indent = @indents.pop if @indents.size > 0
    end

    private def emitter_error(message : String) : NoReturn
      raise Error.new(message)
    end
  end
end
