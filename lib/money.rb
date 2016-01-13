class Fixnum
  def money
    "$%.2f".format(self)
  end
end
