require 'coroutines'
require 'test/unit'

class TestSink < Test::Unit::TestCase
	def test_connect
		assert_equal("abcdef", "abc".in_connect("d".."f"))
		assert_equal([1,2,3,4], [1].in_connect([2,3,4]))
	end

	def test_input_methods
		assert_equal("1234", "".input_map(&:to_s).in_connect(1..4))
		assert_equal([1,3,5,7], [].input_select(&:odd?).in_connect(1..7))
		assert_equal("wrd shrtnr", "".input_reject{|c| "aeiou".include? c}.in_connect("word shortener".each_char))
		assert_equal([55], [].input_reduce(&:+).in_connect(1..10))
	end

	def test_input_chaining
		s = ""
		s.input_map(&:to_s) << 1 << 2 << 3 << 4
		assert_equal("1234", s)

		a = []
		a.input_select(&:odd?) << 1 << 2 << 3 << 4 << 5 << 6 << 7
		assert_equal([1,3,5,7], a)

		s = ""
		s.input_reject{|c| "aeiou".include? c} << "w" << "o" << "r" << "d"
		assert_equal("wrd", s)

		a = [].input_reduce(&:+)
		a << 1 << 2 << 3 << 4 << 5 << 6 << 7
		assert_equal([28], a.close)
	end

	def test_input_wrapper
		assert_equal("#<\"astring\"#input_map>", "astring".input_map.inspect)
		assert_equal("#<\"astring\"#input_select>", "astring".input_select.inspect)
		assert_equal("#<\"astring\"#input_reject>", "astring".input_reject.inspect)
		assert_equal("#<\"astring\"#input_reduce>", "astring".input_reduce.inspect)
	end

	def test_multicast
		a, b, c = [], "", []
		("a".."e").out_connect(Multicast.new(a, b, c))
		assert_equal(["a", "b", "c", "d", "e"], a)
		assert_equal("abcde", b)
		assert_equal(["a", "b", "c", "d", "e"], c)
	end

	def test_instances
		assert_equal({1=>"one", 2=>"two", 3=>"three"}, {} << [1,"one"] << [2,"two"] << [3,"three"])
		a = [1,2]
		a.method(:unshift) << 3 << 4
		assert_equal([4,3,1,2], a)
	end
end
