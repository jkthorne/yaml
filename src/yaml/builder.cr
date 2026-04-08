module YAML
  class Builder
    property max_nesting : Int32

    @emitter : Emitter
    @nesting : Int32
    @closed : Bool

    def initialize(io : IO)
      @emitter = Emitter.new(io)
      @max_nesting = 99
      @nesting = 0
      @closed = false
    end

    def self.build(io : IO, & : Builder ->) : Nil
      builder = new(io)
      builder.stream do
        builder.document do
          yield builder
        end
      end
    end

    def self.build(& : Builder ->) : String
      String.build do |io|
        build(io) do |builder|
          yield builder
        end
      end
    end

    def stream(& : ->) : Nil
      start_stream
      yield
      end_stream
    end

    def start_stream : Nil
      @emitter.emit(Event.new(
        kind: EventKind::STREAM_START,
        encoding: Encoding::UTF8
      ))
    end

    def end_stream : Nil
      @emitter.emit(Event.new(kind: EventKind::STREAM_END))
      @emitter.flush
    end

    def document(*, implicit_start : Bool = false, & : ->) : Nil
      start_document(implicit_start: implicit_start)
      yield
      end_document
    end

    def start_document(*, implicit_start : Bool = false) : Nil
      @emitter.emit(Event.new(
        kind: EventKind::DOCUMENT_START,
        implicit: implicit_start
      ))
    end

    def end_document(*, implicit_end : Bool = true) : Nil
      @emitter.emit(Event.new(
        kind: EventKind::DOCUMENT_END,
        implicit: implicit_end
      ))
    end

    def scalar(value, anchor : String? = nil, tag : String? = nil, style : ScalarStyle = ScalarStyle::ANY) : Nil
      @emitter.emit(Event.new(
        kind: EventKind::SCALAR,
        anchor: anchor,
        tag: tag,
        value: value.to_s,
        implicit: tag.nil?,
        quoted_implicit: tag.nil?,
        style: style
      ))
    end

    def sequence(anchor : String? = nil, tag : String? = nil, style : SequenceStyle = SequenceStyle::ANY, & : ->) : Nil
      start_sequence(anchor: anchor, tag: tag, style: style)
      yield
      end_sequence
    end

    def start_sequence(anchor : String? = nil, tag : String? = nil, style : SequenceStyle = SequenceStyle::ANY) : Nil
      check_nesting!
      @nesting += 1
      @emitter.emit(Event.new(
        kind: EventKind::SEQUENCE_START,
        anchor: anchor,
        tag: tag,
        implicit: tag.nil?,
        sequence_style: style
      ))
    end

    def end_sequence : Nil
      @nesting -= 1
      @emitter.emit(Event.new(kind: EventKind::SEQUENCE_END))
    end

    def mapping(anchor : String? = nil, tag : String? = nil, style : MappingStyle = MappingStyle::ANY, & : ->) : Nil
      start_mapping(anchor: anchor, tag: tag, style: style)
      yield
      end_mapping
    end

    def start_mapping(anchor : String? = nil, tag : String? = nil, style : MappingStyle = MappingStyle::ANY) : Nil
      check_nesting!
      @nesting += 1
      @emitter.emit(Event.new(
        kind: EventKind::MAPPING_START,
        anchor: anchor,
        tag: tag,
        implicit: tag.nil?,
        mapping_style: style
      ))
    end

    def end_mapping : Nil
      @nesting -= 1
      @emitter.emit(Event.new(kind: EventKind::MAPPING_END))
    end

    def alias(anchor : String) : Nil
      @emitter.emit(Event.new(
        kind: EventKind::ALIAS,
        anchor: anchor
      ))
    end

    def merge(anchor : String) : Nil
      scalar("<<", style: ScalarStyle::PLAIN)
      self.alias(anchor)
    end

    def flush : Nil
      @emitter.flush
    end

    def close : Nil
      return if @closed
      @closed = true
      flush
    end

    private def check_nesting! : Nil
      if @nesting >= @max_nesting
        raise Error.new("nesting of #{@nesting} is too deep (max: #{@max_nesting})")
      end
    end
  end
end
