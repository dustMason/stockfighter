class Array
  def median
    sorted = self.sort
    len = sorted.length
    if len == 0 then return nil end
    return (sorted[(len - 1) / 2] + sorted[len / 2]) / 2
  end
end
