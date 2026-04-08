module YAML
  module Nodes
    class Parser
      @pull_parser : PullParser
      @anchors : Hash(String, Node)

      def initialize(content : String)
        @pull_parser = PullParser.new(content)
        @anchors = {} of String => Node
      end

      def initialize(io : IO)
        @pull_parser = PullParser.new(io)
        @anchors = {} of String => Node
      end

      def parse_all : Array(Document)
        documents = [] of Document
        @pull_parser.read_stream do
          while @pull_parser.kind == EventKind::DOCUMENT_START
            documents << parse_document
          end
        end
        documents
      end

      def parse : Document
        documents = parse_all
        documents.first? || Document.new
      end

      private def parse_document : Document
        doc = Document.new
        @pull_parser.read_document do
          doc.nodes << parse_node
        end
        doc
      end

      private def parse_node : Node
        case @pull_parser.kind
        when .alias?
          parse_alias
        when .scalar?
          parse_scalar
        when .sequence_start?
          parse_sequence
        when .mapping_start?
          parse_mapping
        else
          raise ParseException.new(
            "unexpected event #{@pull_parser.kind}",
            @pull_parser.start_line + 1,
            @pull_parser.start_column + 1
          )
        end
      end

      private def parse_scalar : Scalar
        node = Scalar.new(
          value: @pull_parser.value,
          style: @pull_parser.scalar_style
        )
        node.tag = @pull_parser.tag
        node.anchor = @pull_parser.anchor
        node.start_line = @pull_parser.start_line
        node.start_column = @pull_parser.start_column
        node.end_line = @pull_parser.end_line
        node.end_column = @pull_parser.end_column

        if a = node.anchor
          @anchors[a] = node
        end

        @pull_parser.read_next
        node
      end

      private def parse_sequence : Sequence
        node = Sequence.new(style: @pull_parser.sequence_style)
        node.tag = @pull_parser.tag
        node.anchor = @pull_parser.anchor
        node.start_line = @pull_parser.start_line
        node.start_column = @pull_parser.start_column

        if a = node.anchor
          @anchors[a] = node
        end

        @pull_parser.read_sequence do
          node << parse_node
        end

        node.end_line = @pull_parser.end_line
        node.end_column = @pull_parser.end_column
        node
      end

      private def parse_mapping : Mapping
        node = Mapping.new(style: @pull_parser.mapping_style)
        node.tag = @pull_parser.tag
        node.anchor = @pull_parser.anchor
        node.start_line = @pull_parser.start_line
        node.start_column = @pull_parser.start_column

        if a = node.anchor
          @anchors[a] = node
        end

        @pull_parser.read_mapping do
          key = parse_node
          value = parse_node
          node[key] = value
        end

        node.end_line = @pull_parser.end_line
        node.end_column = @pull_parser.end_column
        node
      end

      private def parse_alias : Alias
        alias_anchor = @pull_parser.anchor || ""
        node = Alias.new(alias_anchor)
        node.start_line = @pull_parser.start_line
        node.start_column = @pull_parser.start_column
        node.end_line = @pull_parser.end_line
        node.end_column = @pull_parser.end_column
        @pull_parser.read_next
        node
      end
    end
  end
end
