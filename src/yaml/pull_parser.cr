module Yaml
  class PullParser
    getter kind : EventKind
    getter start_line : Int32
    getter start_column : Int32
    getter end_line : Int32
    getter end_column : Int32

    @parser : EventParser
    @event : Event
    @closed : Bool

    def initialize(content : String)
      @parser = EventParser.new(content)
      @event = Event.new(kind: EventKind::NONE)
      @kind = EventKind::NONE
      @start_line = 0
      @start_column = 0
      @end_line = 0
      @end_column = 0
      @closed = false
      read_next
    end

    def initialize(io : IO)
      @parser = EventParser.new(io)
      @event = Event.new(kind: EventKind::NONE)
      @kind = EventKind::NONE
      @start_line = 0
      @start_column = 0
      @end_line = 0
      @end_column = 0
      @closed = false
      read_next
    end

    def value : String
      @event.value || ""
    end

    def tag : String?
      @event.tag
    end

    def anchor : String?
      @event.anchor
    end

    def scalar_style : ScalarStyle
      @event.style
    end

    def sequence_style : SequenceStyle
      @event.sequence_style
    end

    def mapping_style : MappingStyle
      @event.mapping_style
    end

    def location : {Int32, Int32}
      {@start_line, @start_column}
    end

    def read_next : EventKind
      @event = @parser.parse
      @kind = @event.kind
      @start_line = @event.start_mark.line
      @start_column = @event.start_mark.column
      @end_line = @event.end_mark.line
      @end_column = @event.end_mark.column
      @kind
    end

    def read_stream(& : -> Nil) : Nil
      expect_kind(EventKind::STREAM_START)
      read_next
      yield
      expect_kind(EventKind::STREAM_END)
      read_next
    end

    def read_document(& : -> Nil) : Nil
      expect_kind(EventKind::DOCUMENT_START)
      read_next
      yield
      expect_kind(EventKind::DOCUMENT_END)
      read_next
    end

    def read_sequence(& : -> Nil) : Nil
      expect_kind(EventKind::SEQUENCE_START)
      read_next
      until @kind == EventKind::SEQUENCE_END
        yield
      end
      read_next
    end

    def read_mapping(& : -> Nil) : Nil
      expect_kind(EventKind::MAPPING_START)
      read_next
      until @kind == EventKind::MAPPING_END
        yield
      end
      read_next
    end

    def read_scalar : String
      expect_kind(EventKind::SCALAR)
      v = value
      read_next
      v
    end

    def read_alias : String
      expect_kind(EventKind::ALIAS)
      a = anchor || ""
      read_next
      a
    end

    def read_stream_start : Nil
      expect_kind(EventKind::STREAM_START)
      read_next
    end

    def read_stream_end : Nil
      expect_kind(EventKind::STREAM_END)
      read_next
    end

    def read_document_start : Nil
      expect_kind(EventKind::DOCUMENT_START)
      read_next
    end

    def read_document_end : Nil
      expect_kind(EventKind::DOCUMENT_END)
      read_next
    end

    def read_sequence_start : Nil
      expect_kind(EventKind::SEQUENCE_START)
      read_next
    end

    def read_sequence_end : Nil
      expect_kind(EventKind::SEQUENCE_END)
      read_next
    end

    def read_mapping_start : Nil
      expect_kind(EventKind::MAPPING_START)
      read_next
    end

    def read_mapping_end : Nil
      expect_kind(EventKind::MAPPING_END)
      read_next
    end

    def read(expected : EventKind) : EventKind
      expect_kind(expected)
      read_next
    end

    def skip : Nil
      case @kind
      when .scalar?, .alias?
        read_next
      when .sequence_start?
        read_next
        while @kind != EventKind::SEQUENCE_END
          skip
        end
        read_next
      when .mapping_start?
        read_next
        until @kind == EventKind::MAPPING_END
          skip # key
          skip # value
        end
        read_next
      else
        read_next
      end
    end

    def expect_kind(expected : EventKind) : Nil
      unless @kind == expected
        raise ParseException.new(
          "expected #{expected} but got #{@kind}",
          @start_line + 1,
          @start_column + 1
        )
      end
    end

    def raise(msg : String) : NoReturn
      ::raise ParseException.new(msg, @start_line + 1, @start_column + 1)
    end

    def close : Nil
      return if @closed
      @closed = true
      @parser.close
    end
  end
end
