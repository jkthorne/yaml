module YAML
  module Nodes
    class Builder
      getter document : Document

      @current : Array(Node)
      @stack : Array(Array(Node))
      @mapping_key_stack : Array(Node?)
      @in_mapping_key : Array(Bool)

      def initialize
        @document = Document.new
        @current = @document.nodes
        @stack = [] of Array(Node)
        @mapping_key_stack = [] of Node?
        @in_mapping_key = [] of Bool
      end

      def scalar(value : String, anchor : String? = nil, tag : String? = nil, style : ScalarStyle = ScalarStyle::ANY) : Scalar
        node = Scalar.new(value: value, style: style)
        node.anchor = anchor
        node.tag = tag
        add_node(node)
        node
      end

      def sequence(anchor : String? = nil, tag : String? = nil, style : SequenceStyle = SequenceStyle::ANY, & : ->) : Sequence
        node = Sequence.new(style: style)
        node.anchor = anchor
        node.tag = tag
        add_node(node)

        @stack.push(@current)
        @current = node.nodes
        yield
        @current = @stack.pop

        node
      end

      def mapping(anchor : String? = nil, tag : String? = nil, style : MappingStyle = MappingStyle::ANY, & : ->) : Mapping
        node = Mapping.new(style: style)
        node.anchor = anchor
        node.tag = tag
        add_node(node)

        @stack.push(@current)
        @current = node.nodes
        yield
        @current = @stack.pop

        node
      end

      def alias_node(anchor : String) : Alias
        node = Alias.new(anchor)
        add_node(node)
        node
      end

      private def add_node(node : Node) : Nil
        @current << node
      end
    end
  end
end
