module YAML
  class Event
    property kind : EventKind
    property start_mark : Mark
    property end_mark : Mark
    property anchor : String?
    property tag : String?
    property value : String?
    property implicit : Bool
    property quoted_implicit : Bool
    property style : ScalarStyle
    property sequence_style : SequenceStyle
    property mapping_style : MappingStyle
    property encoding : Encoding?
    property version_directive : {Int32, Int32}?
    property tag_directives : Array({String, String})?

    def initialize(
      @kind : EventKind,
      @start_mark : Mark = Mark.new,
      @end_mark : Mark = Mark.new,
      @anchor : String? = nil,
      @tag : String? = nil,
      @value : String? = nil,
      @implicit : Bool = false,
      @quoted_implicit : Bool = false,
      @style : ScalarStyle = ScalarStyle::ANY,
      @sequence_style : SequenceStyle = SequenceStyle::ANY,
      @mapping_style : MappingStyle = MappingStyle::ANY,
      @encoding : Encoding? = nil,
      @version_directive : {Int32, Int32}? = nil,
      @tag_directives : Array({String, String})? = nil
    )
    end
  end
end
