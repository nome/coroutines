require 'coroutines'
require 'test/unit'

class TestSink < Test::Unit::TestCase
	def test_connect
		assert_equal("abcdef", "abc".in_connect("d".."f"))
		assert_equal([1,2,3,4], [1].in_connect([2,3,4]))
	end
end
