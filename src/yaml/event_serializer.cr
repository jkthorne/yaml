module YAML
  module EventSerializer
    def self.serialize(events : Array(Event)) : String
      String.build do |io|
        events.each do |event|
          io << serialize_event(event) << '\n'
        end
      end
    end

    def self.serialize_event(event : Event) : String
      case event.kind
      when EventKind::STREAM_START
        "+STR"
      when EventKind::STREAM_END
        "-STR"
      when EventKind::DOCUMENT_START
        s = String.build do |io|
          io << "+DOC"
          io << " ---" unless event.implicit
        end
        s
      when EventKind::DOCUMENT_END
        s = String.build do |io|
          io << "-DOC"
          io << " ..." unless event.implicit
        end
        s
      when EventKind::SEQUENCE_START
        String.build do |io|
          io << "+SEQ"
          if event.sequence_style.flow?
            io << " []"
          end
          append_anchor(io, event.anchor)
          append_tag(io, event.tag)
        end
      when EventKind::SEQUENCE_END
        "-SEQ"
      when EventKind::MAPPING_START
        String.build do |io|
          io << "+MAP"
          if event.mapping_style.flow?
            io << " {}"
          end
          append_anchor(io, event.anchor)
          append_tag(io, event.tag)
        end
      when EventKind::MAPPING_END
        "-MAP"
      when EventKind::SCALAR
        String.build do |io|
          io << "=VAL"
          append_anchor(io, event.anchor)
          append_tag(io, event.tag)
          io << ' '
          io << style_char(event.style)
          io << escape_value(event.value || "")
        end
      when EventKind::ALIAS
        "=ALI *#{event.anchor}"
      else
        ""
      end
    end

    private def self.append_anchor(io : IO, anchor : String?) : Nil
      if a = anchor
        io << " &" << a
      end
    end

    private def self.append_tag(io : IO, tag : String?) : Nil
      if t = tag
        io << " <" << t << ">"
      end
    end

    private def self.style_char(style : ScalarStyle) : Char
      case style
      when ScalarStyle::PLAIN         then ':'
      when ScalarStyle::SINGLE_QUOTED then '\''
      when ScalarStyle::DOUBLE_QUOTED then '"'
      when ScalarStyle::LITERAL       then '|'
      when ScalarStyle::FOLDED        then '>'
      else                                 ':'
      end
    end

    private def self.escape_value(value : String) : String
      String.build(value.bytesize) do |io|
        value.each_char do |ch|
          case ch
          when '\\'  then io << "\\\\"
          when '\n'  then io << "\\n"
          when '\r'  then io << "\\r"
          when '\t'  then io << "\\t"
          when '\0'  then io << "\\0"
          when '\b'  then io << "\\b"
          when '\a'  then io << "\\a"
          when '\e'  then io << "\\e"
          when '\u{0085}' then io << "\\N"
          when '\u{00A0}' then io << "\\_"
          when '\u{2028}' then io << "\\L"
          when '\u{2029}' then io << "\\P"
          else
            io << ch
          end
        end
      end
    end
  end
end
