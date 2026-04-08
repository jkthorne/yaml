module Yaml
  module Nodes
    abstract class Node
      property tag : String?
      property anchor : String?
      property start_line : Int32
      property start_column : Int32
      property end_line : Int32
      property end_column : Int32

      def initialize
        @tag = nil
        @anchor = nil
        @start_line = 0
        @start_column = 0
        @end_line = 0
        @end_column = 0
      end

      abstract def to_yaml(builder : Yaml::Builder) : Nil
    end

    class Document
      property nodes : Array(Node)
      property start_implicit : Bool
      property end_implicit : Bool

      def initialize
        @nodes = [] of Node
        @start_implicit = true
        @end_implicit = true
      end
    end

    class Scalar < Node
      property value : String
      property style : ScalarStyle

      def initialize(@value : String = "", @style : ScalarStyle = ScalarStyle::ANY)
        super()
      end

      def to_yaml(builder : Yaml::Builder) : Nil
        builder.scalar(value, anchor: anchor, tag: tag, style: style)
      end
    end

    class Sequence < Node
      property nodes : Array(Node)
      property style : SequenceStyle

      def initialize(@style : SequenceStyle = SequenceStyle::ANY)
        super()
        @nodes = [] of Node
      end

      def <<(node : Node) : self
        @nodes << node
        self
      end

      def to_yaml(builder : Yaml::Builder) : Nil
        builder.sequence(anchor: anchor, tag: tag, style: style) do
          nodes.each &.to_yaml(builder)
        end
      end
    end

    class Mapping < Node
      # Stored as alternating key-value pairs: [key1, val1, key2, val2, ...]
      property nodes : Array(Node)
      property style : MappingStyle

      def initialize(@style : MappingStyle = MappingStyle::ANY)
        super()
        @nodes = [] of Node
      end

      def []=(key : Node, value : Node) : Nil
        @nodes << key
        @nodes << value
      end

      def to_yaml(builder : Yaml::Builder) : Nil
        builder.mapping(anchor: anchor, tag: tag, style: style) do
          nodes.each &.to_yaml(builder)
        end
      end
    end

    class Alias < Node
      property alias_anchor : String

      def initialize(@alias_anchor : String)
        super()
      end

      def to_yaml(builder : Yaml::Builder) : Nil
        builder.alias(alias_anchor)
      end
    end
  end
end
