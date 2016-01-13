class Fixnum
  def money
    "$%.2f" % (self/100.0)
  end
end
