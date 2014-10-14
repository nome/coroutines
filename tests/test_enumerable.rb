require 'coroutines'
require 'test/unit'

class TestEnumerable < Test::Unit::TestCase
	def test_connect
		assert_equal("abcdef", ("d".."f").out_connect("abc"))
		assert_equal([1,2,3,4], [2,3,4].out_connect([1]))
	end

	def test_filter_map
		assert_equal("13579", (1..10).filter_map{|i| i.to_s if i.odd? }.out_connect(""))
		assert_equal("13579", (1..10).lazy.filter_map{|i| i.to_s if i.odd? }.out_connect(""))
	end
end
