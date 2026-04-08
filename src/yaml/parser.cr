module Yaml
  class EventParser
    MAX_NESTING = 1000

    private enum State
      STREAM_START
      IMPLICIT_DOCUMENT_START
      DOCUMENT_START
      DOCUMENT_CONTENT
      DOCUMENT_END
      BLOCK_NODE
      BLOCK_NODE_OR_INDENTLESS_SEQUENCE
      FLOW_NODE
      BLOCK_SEQUENCE_FIRST_ENTRY
      BLOCK_SEQUENCE_ENTRY
      INDENTLESS_SEQUENCE_ENTRY
      BLOCK_MAPPING_FIRST_KEY
      BLOCK_MAPPING_KEY
      BLOCK_MAPPING_VALUE
      FLOW_SEQUENCE_FIRST_ENTRY
      FLOW_SEQUENCE_ENTRY
      FLOW_SEQUENCE_ENTRY_MAPPING_KEY
      FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      FLOW_SEQUENCE_ENTRY_MAPPING_END
      FLOW_MAPPING_FIRST_KEY
      FLOW_MAPPING_KEY
      FLOW_MAPPING_VALUE
      FLOW_MAPPING_EMPTY_VALUE
      END
    end

    DEFAULT_TAG_DIRECTIVES = [
      {"!", "!"},
      {"!!", "tag:yaml.org,2002:"},
    ]

    @scanner : Scanner
    @state : State
    @states : Array(State)
    @marks : Array(Mark)
    @tag_directives : Array({String, String})
    @context_stack : Array({String, Mark})

    def initialize(input : String | IO)
      @scanner = Scanner.new(input)
      @state = State::STREAM_START
      @states = [] of State
      @marks = [] of Mark
      @tag_directives = [] of {String, String}
      @context_stack = [] of {String, Mark}
    end

    def parse : Event
      return Event.new(kind: EventKind::STREAM_END) if @state == State::END

      event = state_machine
      event
    end

    def close : Nil
      @state = State::END
    end

    private def state_machine : Event
      case @state
      when .stream_start?
        parse_stream_start
      when .implicit_document_start?
        parse_document_start(implicit: true)
      when .document_start?
        parse_document_start(implicit: false)
      when .document_content?
        parse_document_content
      when .document_end?
        parse_document_end
      when .block_node?
        parse_node(block: true, indentless_sequence: false)
      when .block_node_or_indentless_sequence?
        parse_node(block: true, indentless_sequence: true)
      when .flow_node?
        parse_node(block: false, indentless_sequence: false)
      when .block_sequence_first_entry?
        parse_block_sequence_entry(first: true)
      when .block_sequence_entry?
        parse_block_sequence_entry(first: false)
      when .indentless_sequence_entry?
        parse_indentless_sequence_entry
      when .block_mapping_first_key?
        parse_block_mapping_key(first: true)
      when .block_mapping_key?
        parse_block_mapping_key(first: false)
      when .block_mapping_value?
        parse_block_mapping_value
      when .flow_sequence_first_entry?
        parse_flow_sequence_entry(first: true)
      when .flow_sequence_entry?
        parse_flow_sequence_entry(first: false)
      when .flow_sequence_entry_mapping_key?
        parse_flow_sequence_entry_mapping_key
      when .flow_sequence_entry_mapping_value?
        parse_flow_sequence_entry_mapping_value
      when .flow_sequence_entry_mapping_end?
        parse_flow_sequence_entry_mapping_end
      when .flow_mapping_first_key?
        parse_flow_mapping_key(first: true)
      when .flow_mapping_key?
        parse_flow_mapping_key(first: false)
      when .flow_mapping_value?
        parse_flow_mapping_value
      when .flow_mapping_empty_value?
        parse_flow_mapping_empty_value
      else
        parser_error("invalid parser state", Mark.new)
      end
    end

    # --- Stream ---

    private def parse_stream_start : Event
      token = peek_token
      unless token.kind.stream_start?
        parser_error("expected STREAM-START", token.start_mark)
      end
      @state = State::IMPLICIT_DOCUMENT_START
      skip_token
      Event.new(
        kind: EventKind::STREAM_START,
        start_mark: token.start_mark,
        end_mark: token.end_mark,
        encoding: token.encoding
      )
    end

    # --- Document ---

    private def parse_document_start(implicit : Bool) : Event
      token = peek_token

      # Check for stream end
      if token.kind.stream_end?
        @state = State::END
        skip_token
        return Event.new(
          kind: EventKind::STREAM_END,
          start_mark: token.start_mark,
          end_mark: token.end_mark
        )
      end

      if implicit
        # Check for implicit document start (any content that isn't a directive or doc indicator)
        unless token.kind.version_directive? || token.kind.tag_directive? || token.kind.document_start? || token.kind.stream_end?
          @tag_directives = DEFAULT_TAG_DIRECTIVES.dup
          @states.push(State::DOCUMENT_END)
          @state = State::BLOCK_NODE
          return Event.new(
            kind: EventKind::DOCUMENT_START,
            start_mark: token.start_mark,
            end_mark: token.end_mark,
            implicit: true
          )
        end
      end

      # Explicit document or directives
      start_mark = token.start_mark
      version_directive : {Int32, Int32}? = nil
      tag_directives_list = [] of {String, String}

      # Process directives
      while token.kind.version_directive? || token.kind.tag_directive?
        if token.kind.version_directive?
          version_directive = {token.major, token.minor}
        else
          tag_directives_list << {token.value, token.suffix || ""}
        end
        skip_token
        token = peek_token
      end

      @tag_directives = DEFAULT_TAG_DIRECTIVES.dup
      tag_directives_list.each { |td| @tag_directives << td }

      unless token.kind.document_start?
        if implicit
          @states.push(State::DOCUMENT_END)
          @state = State::BLOCK_NODE
          return Event.new(
            kind: EventKind::DOCUMENT_START,
            start_mark: token.start_mark,
            end_mark: token.end_mark,
            implicit: true
          )
        end
        parser_error("did not find expected <document start>", token.start_mark)
      end

      @states.push(State::DOCUMENT_END)
      @state = State::DOCUMENT_CONTENT
      skip_token

      Event.new(
        kind: EventKind::DOCUMENT_START,
        start_mark: start_mark,
        end_mark: token.end_mark,
        implicit: false,
        version_directive: version_directive,
        tag_directives: tag_directives_list.empty? ? nil : tag_directives_list
      )
    end

    private def parse_document_content : Event
      token = peek_token
      if token.kind.version_directive? || token.kind.tag_directive? ||
         token.kind.document_start? || token.kind.document_end? || token.kind.stream_end?
        # Empty document content
        @state = @states.pop
        process_empty_scalar(token.start_mark)
      else
        parse_node(block: true, indentless_sequence: false)
      end
    end

    private def parse_document_end : Event
      start_mark = Mark.new
      end_mark = Mark.new
      implicit = true

      token = peek_token
      start_mark = token.start_mark
      end_mark = token.start_mark

      if token.kind.document_end?
        end_mark = token.end_mark
        implicit = false
        skip_token
      end

      @tag_directives.clear
      @state = State::DOCUMENT_START

      Event.new(
        kind: EventKind::DOCUMENT_END,
        start_mark: start_mark,
        end_mark: end_mark,
        implicit: implicit
      )
    end

    # --- Node ---

    private def parse_node(block : Bool, indentless_sequence : Bool) : Event
      token = peek_token

      if token.kind.alias?
        @state = @states.pop
        skip_token
        return Event.new(
          kind: EventKind::ALIAS,
          start_mark: token.start_mark,
          end_mark: token.end_mark,
          anchor: token.value
        )
      end

      start_mark = token.start_mark
      end_mark : Mark = token.start_mark
      anchor : String? = nil
      tag : String? = nil

      # Parse anchor and/or tag
      if token.kind.anchor?
        anchor = token.value
        end_mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.tag?
          tag = resolve_tag(token)
          end_mark = token.end_mark
          skip_token
          token = peek_token
        end
      elsif token.kind.tag?
        tag = resolve_tag(token)
        end_mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.anchor?
          anchor = token.value
          end_mark = token.end_mark
          skip_token
          token = peek_token
        end
      end

      if indentless_sequence && token.kind.block_entry?
        @state = State::INDENTLESS_SEQUENCE_ENTRY
        return Event.new(
          kind: EventKind::SEQUENCE_START,
          start_mark: start_mark,
          end_mark: end_mark,
          anchor: anchor,
          tag: tag,
          implicit: tag.nil?,
          sequence_style: SequenceStyle::BLOCK
        )
      end

      if token.kind.scalar?
        plain_implicit = tag.nil? && token.style.plain?
        quoted_implicit = tag.nil? && !token.style.plain?
        if tag == "!"
          plain_implicit = false
          quoted_implicit = false
        end
        @state = @states.pop
        skip_token
        return Event.new(
          kind: EventKind::SCALAR,
          start_mark: start_mark,
          end_mark: token.end_mark,
          anchor: anchor,
          tag: tag,
          value: token.value,
          implicit: plain_implicit,
          quoted_implicit: quoted_implicit,
          style: token.style
        )
      end

      if token.kind.flow_sequence_start?
        @state = State::FLOW_SEQUENCE_FIRST_ENTRY
        return Event.new(
          kind: EventKind::SEQUENCE_START,
          start_mark: start_mark,
          end_mark: token.end_mark,
          anchor: anchor,
          tag: tag,
          implicit: tag.nil?,
          sequence_style: SequenceStyle::FLOW
        )
      end

      if token.kind.flow_mapping_start?
        @state = State::FLOW_MAPPING_FIRST_KEY
        return Event.new(
          kind: EventKind::MAPPING_START,
          start_mark: start_mark,
          end_mark: token.end_mark,
          anchor: anchor,
          tag: tag,
          implicit: tag.nil?,
          mapping_style: MappingStyle::FLOW
        )
      end

      if block && token.kind.block_sequence_start?
        @state = State::BLOCK_SEQUENCE_FIRST_ENTRY
        return Event.new(
          kind: EventKind::SEQUENCE_START,
          start_mark: start_mark,
          end_mark: token.end_mark,
          anchor: anchor,
          tag: tag,
          implicit: tag.nil?,
          sequence_style: SequenceStyle::BLOCK
        )
      end

      if block && token.kind.block_mapping_start?
        @state = State::BLOCK_MAPPING_FIRST_KEY
        return Event.new(
          kind: EventKind::MAPPING_START,
          start_mark: start_mark,
          end_mark: token.end_mark,
          anchor: anchor,
          tag: tag,
          implicit: tag.nil?,
          mapping_style: MappingStyle::BLOCK
        )
      end

      if anchor || tag
        @state = @states.pop
        return Event.new(
          kind: EventKind::SCALAR,
          start_mark: start_mark,
          end_mark: end_mark,
          anchor: anchor,
          tag: tag,
          value: "",
          implicit: tag.nil?,
          quoted_implicit: false,
          style: ScalarStyle::PLAIN
        )
      end

      parser_error("did not find expected node content", token.start_mark)
    end

    # --- Block sequence ---

    private def parse_block_sequence_entry(first : Bool) : Event
      if first
        token = peek_token
        push_context("block sequence", token.start_mark)
        @marks.push(token.start_mark)
        skip_token
      end

      token = peek_token

      if token.kind.block_entry?
        mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.block_entry? || token.kind.block_end?
          @state = State::BLOCK_SEQUENCE_ENTRY
          return process_empty_scalar(mark)
        else
          @states.push(State::BLOCK_SEQUENCE_ENTRY)
          return parse_node(block: true, indentless_sequence: false)
        end
      end

      if token.kind.block_end?
        @state = @states.pop
        @marks.pop
        pop_context
        skip_token
        return Event.new(
          kind: EventKind::SEQUENCE_END,
          start_mark: token.start_mark,
          end_mark: token.end_mark
        )
      end

      parser_error("while parsing a block collection, did not find expected '-' indicator", token.start_mark)
    end

    # --- Indentless sequence ---

    private def parse_indentless_sequence_entry : Event
      token = peek_token

      if token.kind.block_entry?
        mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.block_entry? || token.kind.key? || token.kind.value? || token.kind.block_end?
          @state = State::INDENTLESS_SEQUENCE_ENTRY
          return process_empty_scalar(mark)
        else
          @states.push(State::INDENTLESS_SEQUENCE_ENTRY)
          return parse_node(block: true, indentless_sequence: false)
        end
      end

      @state = @states.pop
      Event.new(
        kind: EventKind::SEQUENCE_END,
        start_mark: token.start_mark,
        end_mark: token.start_mark
      )
    end

    # --- Block mapping ---

    private def parse_block_mapping_key(first : Bool) : Event
      if first
        token = peek_token
        push_context("block mapping", token.start_mark)
        @marks.push(token.start_mark)
        skip_token
      end

      token = peek_token

      if token.kind.key?
        mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.key? || token.kind.value? || token.kind.block_end?
          @state = State::BLOCK_MAPPING_VALUE
          return process_empty_scalar(mark)
        else
          @states.push(State::BLOCK_MAPPING_VALUE)
          return parse_node(block: true, indentless_sequence: true)
        end
      end

      if token.kind.value?
        @state = State::BLOCK_MAPPING_VALUE
        return process_empty_scalar(token.start_mark)
      end

      if token.kind.block_end?
        @state = @states.pop
        @marks.pop
        pop_context
        skip_token
        return Event.new(
          kind: EventKind::MAPPING_END,
          start_mark: token.start_mark,
          end_mark: token.end_mark
        )
      end

      parser_error("while parsing a block mapping, did not find expected key", token.start_mark)
    end

    private def parse_block_mapping_value : Event
      token = peek_token

      if token.kind.value?
        mark = token.end_mark
        skip_token
        token = peek_token
        if token.kind.key? || token.kind.value? || token.kind.block_end?
          @state = State::BLOCK_MAPPING_KEY
          return process_empty_scalar(mark)
        else
          @states.push(State::BLOCK_MAPPING_KEY)
          return parse_node(block: true, indentless_sequence: true)
        end
      end

      @state = State::BLOCK_MAPPING_KEY
      process_empty_scalar(token.start_mark)
    end

    # --- Flow sequence ---

    private def parse_flow_sequence_entry(first : Bool) : Event
      if first
        token = peek_token
        push_context("flow sequence", token.start_mark)
        @marks.push(token.start_mark)
        skip_token
      end

      token = peek_token

      unless token.kind.flow_sequence_end?
        unless first
          if token.kind.flow_entry?
            skip_token
            token = peek_token
          else
            parser_error("while parsing a flow sequence, did not find expected ',' or ']'", token.start_mark)
          end
        end

        if token.kind.key?
          @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_KEY
          skip_token
          return Event.new(
            kind: EventKind::MAPPING_START,
            start_mark: token.start_mark,
            end_mark: token.end_mark,
            implicit: true,
            mapping_style: MappingStyle::FLOW
          )
        end

        unless token.kind.flow_sequence_end?
          @states.push(State::FLOW_SEQUENCE_ENTRY)
          return parse_node(block: false, indentless_sequence: false)
        end
      end

      @state = @states.pop
      @marks.pop
      pop_context
      skip_token
      Event.new(
        kind: EventKind::SEQUENCE_END,
        start_mark: token.start_mark,
        end_mark: token.end_mark
      )
    end

    private def parse_flow_sequence_entry_mapping_key : Event
      token = peek_token

      unless token.kind.value? || token.kind.flow_entry? || token.kind.flow_sequence_end?
        @states.push(State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE)
        return parse_node(block: false, indentless_sequence: false)
      end

      mark = token.end_mark
      skip_token if token.kind.value?
      @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_VALUE
      process_empty_scalar(mark)
    end

    private def parse_flow_sequence_entry_mapping_value : Event
      token = peek_token

      if token.kind.value?
        skip_token
        token = peek_token
        unless token.kind.flow_entry? || token.kind.flow_sequence_end?
          @states.push(State::FLOW_SEQUENCE_ENTRY_MAPPING_END)
          return parse_node(block: false, indentless_sequence: false)
        end
      end

      @state = State::FLOW_SEQUENCE_ENTRY_MAPPING_END
      process_empty_scalar(token.start_mark)
    end

    private def parse_flow_sequence_entry_mapping_end : Event
      @state = State::FLOW_SEQUENCE_ENTRY
      token = peek_token
      Event.new(
        kind: EventKind::MAPPING_END,
        start_mark: token.start_mark,
        end_mark: token.start_mark
      )
    end

    # --- Flow mapping ---

    private def parse_flow_mapping_key(first : Bool) : Event
      if first
        token = peek_token
        push_context("flow mapping", token.start_mark)
        @marks.push(token.start_mark)
        skip_token
      end

      token = peek_token

      unless token.kind.flow_mapping_end?
        unless first
          if token.kind.flow_entry?
            skip_token
            token = peek_token
          else
            parser_error("while parsing a flow mapping, did not find expected ',' or '}'", token.start_mark)
          end
        end

        if token.kind.key?
          skip_token
          token = peek_token
          unless token.kind.value? || token.kind.flow_entry? || token.kind.flow_mapping_end?
            @states.push(State::FLOW_MAPPING_VALUE)
            return parse_node(block: false, indentless_sequence: false)
          end
          @state = State::FLOW_MAPPING_VALUE
          return process_empty_scalar(token.start_mark)
        end

        unless token.kind.flow_mapping_end?
          @states.push(State::FLOW_MAPPING_EMPTY_VALUE)
          return parse_node(block: false, indentless_sequence: false)
        end
      end

      @state = @states.pop
      @marks.pop
      pop_context
      skip_token
      Event.new(
        kind: EventKind::MAPPING_END,
        start_mark: token.start_mark,
        end_mark: token.end_mark
      )
    end

    private def parse_flow_mapping_value : Event
      token = peek_token

      if token.kind.value?
        skip_token
        token = peek_token
        unless token.kind.flow_entry? || token.kind.flow_mapping_end?
          @states.push(State::FLOW_MAPPING_KEY)
          return parse_node(block: false, indentless_sequence: false)
        end
      end

      @state = State::FLOW_MAPPING_KEY
      process_empty_scalar(token.start_mark)
    end

    private def parse_flow_mapping_empty_value : Event
      @state = State::FLOW_MAPPING_KEY
      process_empty_scalar(peek_token.start_mark)
    end

    # --- Helpers ---

    private def peek_token : Token
      token = @scanner.peek_token
      unless token
        parser_error("unexpected end of token stream", Mark.new)
      end
      token
    end

    private def skip_token : Nil
      @scanner.scan
    end

    private def process_empty_scalar(mark : Mark) : Event
      Event.new(
        kind: EventKind::SCALAR,
        start_mark: mark,
        end_mark: mark,
        value: "",
        implicit: true,
        quoted_implicit: false,
        style: ScalarStyle::PLAIN
      )
    end

    private def resolve_tag(token : Token) : String
      handle = token.value
      suffix = token.suffix || ""

      if handle.empty? && suffix.empty?
        "!"
      elsif handle.empty?
        suffix
      else
        # Look up handle in tag directives
        @tag_directives.each do |directive_handle, prefix|
          if directive_handle == handle
            return prefix + suffix
          end
        end
        # If handle not found, just return handle + suffix
        handle + suffix
      end
    end

    private def push_context(description : String, mark : Mark) : Nil
      @context_stack.push({description, mark})
    end

    private def pop_context : Nil
      @context_stack.pop?
    end

    private def parser_error(message : String, mark : Mark) : NoReturn
      context_info = if ctx = @context_stack.last?
                       desc, ctx_mark = ctx
                       "while parsing a #{desc} started at line #{ctx_mark.line + 1} column #{ctx_mark.column + 1}"
                     else
                       nil
                     end
      raise ParseException.new(message, mark.line + 1, mark.column + 1, context_info: context_info)
    end
  end
end
