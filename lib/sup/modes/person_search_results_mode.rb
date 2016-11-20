module Redwood

class PersonSearchResultsMode < ThreadIndexMode
  def initialize people
    @people = people
    super [], { :participants => @people }
  end
end

end
