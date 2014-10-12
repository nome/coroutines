require 'coroutines'
require 'test/unit'

class TestEnumerable < Test::Unit::TestCase
	def test_connect
		assert_equal("abcdef", ("d".."f").out_connect("abc"))
		assert_equal([1,2,3,4], [2,3,4].out_connect([1]))
	end
end
