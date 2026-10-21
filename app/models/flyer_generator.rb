# Builds the printable PDF for a set of flyer categories.
#
# Integration point for the flyer creation work: replace the body of .call
# with the real implementation. It should return the PDF as a binary string,
# or nil if no flyer could be produced.
class FlyerGenerator
  def self.call(categories:)
    nil
  end
end
