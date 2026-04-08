module YAML
  struct Mark
    property index : Int32
    property line : Int32
    property column : Int32

    def initialize(@index : Int32 = 0, @line : Int32 = 0, @column : Int32 = 0)
    end

    def to_s(io : IO) : Nil
      io << "line " << @line + 1 << " column " << @column + 1
    end
  end
end
