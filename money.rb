class Fixnum
  def money
    "$#{self/100.0}"
  end
end
