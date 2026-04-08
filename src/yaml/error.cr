module Yaml
  class Error < Exception
  end

  class ParseException < Error
    getter line_number : Int32
    getter column_number : Int32
    getter context_info : String?

    def initialize(message : String, @line_number : Int32, @column_number : Int32, @context_info : String? = nil)
      full_message = String.build do |io|
        if ctx = @context_info
          io << ctx << ", "
        end
        io << message << " at line " << @line_number << " column " << @column_number
      end
      super(full_message)
    end
  end
end
