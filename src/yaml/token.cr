module YAML
  enum TokenKind
    STREAM_START
    STREAM_END
    VERSION_DIRECTIVE
    TAG_DIRECTIVE
    DOCUMENT_START
    DOCUMENT_END
    BLOCK_SEQUENCE_START
    BLOCK_MAPPING_START
    BLOCK_END
    FLOW_SEQUENCE_START
    FLOW_SEQUENCE_END
    FLOW_MAPPING_START
    FLOW_MAPPING_END
    BLOCK_ENTRY
    FLOW_ENTRY
    KEY
    VALUE
    ALIAS
    ANCHOR
    TAG
    SCALAR
  end

  struct Token
    property kind : TokenKind
    property start_mark : Mark
    property end_mark : Mark
    property value : String
    property suffix : String?
    property encoding : Encoding?
    property style : ScalarStyle
    property major : Int32
    property minor : Int32

    def initialize(
      @kind : TokenKind,
      @start_mark : Mark = Mark.new,
      @end_mark : Mark = Mark.new,
      @value : String = "",
      @suffix : String? = nil,
      @encoding : Encoding? = nil,
      @style : ScalarStyle = ScalarStyle::ANY,
      @major : Int32 = 0,
      @minor : Int32 = 0
    )
    end
  end
end
