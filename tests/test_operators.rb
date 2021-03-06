require 'coroutines'
require 'coroutines/operators'
require 'test/unit'

class TestOperators < Test::Unit::TestCase
	def test_sink
		assert_equal("abcdef", "abc" <= ("d".."f"))
		assert_equal([1,2,3,4], [1] <= [2,3,4])
	end

	def test_source
		assert_equal("abcdef", ("d".."f") >= "abc")
		assert_equal([1,2,3,4], [2,3,4] >= [1])
	end

	def test_transformer
		rs = Transformer.new do |y|
			result = 0
			loop { result += y.await; y.yield result }
		end
		assert_equal([1, 3, 6], (1..3) >= rs >= [])

		rs = Transformer.new do |y|
			result = 0
			loop { result += y.await; y.yield result }
		end
		assert_equal([1, 3, 6], [] <= rs <= (1..3))
	end

	def test_transformer_chaining
		t1 = Transformer.new{|y| y.yield (y.await + "a")}
		t2 = Transformer.new{|y| y.yield (y.await + "b")}
		t = t1 >= t2
		result = %w{x y z} >= t >= []
		assert_equal(["xab"], result)
	end

	def test_associativity
		s = (1..3)
		def t1
			Transformer.new{|y| loop { y.yield y.await.to_s } }
		end
		def t2
			Transformer.new{|y| loop { y.yield (y.await + ",") } }
		end

		assert_equal("1,2,3,", s >= t1 >= t2 >= "")
		assert_equal("1,2,3,", s >= t1 >= (t2 >= ""))
		assert_equal("1,2,3,", s >= (t1 >= t2 >= ""))
		assert_equal("1,2,3,", s >= (t1 >= t2) >= "")
		assert_equal("1,2,3,", s >= ((t1 >= t2) >= ""))

		assert_equal("1,2,3,", "" <= t2 <= t1 <= s)
		assert_equal("1,2,3,", "" <= t2 <= (t1 <= s))
		assert_equal("1,2,3,", "" <= (t2 <= t1 <= s))
		assert_equal("1,2,3,", "" <= (t2 <= t1) <= s)
		assert_equal("1,2,3,", "" <= ((t2 <= t1) <= s))
	end

	def running_sum(start)
		result = start
		loop { result += await; yield result }
	end
	def test_transformer_method
		assert_equal([4, 6, 9], (1..3) >= trans_for(:running_sum, 3) >= [])
		assert_equal([4, 6, 9], (1..3) >= (trans_for(:running_sum, 3) >= []))
	end

	def test_stop_iteration
		consume_three = Consumer.new do |y|
			[y.await, y.await, y.await]
		end
		assert_equal([1,2,3], (1..Float::INFINITY) >= consume_three)

		limit_three = Transformer.new do |y|
			3.times { y.yield y.await }
		end
		assert_equal([1,2,3], (1..Float::INFINITY) >= limit_three >= [])
	end

	def test_transformer_procs
		s = (1..3)
		t1_proc = proc{|x| x.to_s }
		t2_proc = proc{|x| x + "," }
		def t1
			Transformer.new{|y| loop { y.yield y.await.to_s } }
		end
		def t2
			Transformer.new{|y| loop { y.yield (y.await + ",") } }
		end

		assert_equal("1,2,3,", s >= t1_proc >= t2_proc >= "")
		assert_equal("1,2,3,", s >= t1_proc >= (t2_proc >= ""))
		assert_equal("1,2,3,", s >= (t1_proc >= t2_proc >= ""))
		assert_equal("1,2,3,", s >= (t1_proc >= t2_proc) >= "")
		assert_equal("1,2,3,", s >= ((t1_proc >= t2_proc) >= ""))

		assert_equal("1,2,3,", "" <= t2_proc <= t1_proc <= s)
		assert_equal("1,2,3,", "" <= t2_proc <= (t1_proc <= s))
		assert_equal("1,2,3,", "" <= (t2_proc <= t1_proc <= s))
		assert_equal("1,2,3,", "" <= (t2_proc <= t1_proc) <= s)
		assert_equal("1,2,3,", "" <= ((t2_proc <= t1_proc) <= s))

		assert_equal("1,2,3,", s >= t1_proc >= t2 >= "")
		assert_equal("1,2,3,", s >= t1_proc >= (t2 >= ""))
		assert_equal("1,2,3,", s >= (t1_proc >= t2 >= ""))
		assert_equal("1,2,3,", s >= (t1_proc >= t2) >= "")
		assert_equal("1,2,3,", s >= ((t1_proc >= t2) >= ""))

		assert_equal("1,2,3,", "" <= t2 <= t1_proc <= s)
		assert_equal("1,2,3,", "" <= t2 <= (t1_proc <= s))
		assert_equal("1,2,3,", "" <= (t2 <= t1_proc <= s))
		assert_equal("1,2,3,", "" <= (t2 <= t1_proc) <= s)
		assert_equal("1,2,3,", "" <= ((t2 <= t1_proc) <= s))

		assert_equal("1,2,3,", s >= t1 >= t2_proc >= "")
		assert_equal("1,2,3,", s >= t1 >= (t2_proc >= ""))
		assert_equal("1,2,3,", s >= (t1 >= t2_proc >= ""))
		assert_equal("1,2,3,", s >= (t1 >= t2_proc) >= "")
		assert_equal("1,2,3,", s >= ((t1 >= t2_proc) >= ""))

		assert_equal("1,2,3,", "" <= t2_proc <= t1 <= s)
		assert_equal("1,2,3,", "" <= t2_proc <= (t1 <= s))
		assert_equal("1,2,3,", "" <= (t2_proc <= t1 <= s))
		assert_equal("1,2,3,", "" <= (t2_proc <= t1) <= s)
		assert_equal("1,2,3,", "" <= ((t2_proc <= t1) <= s))

		assert_raise(ArgumentError) { t1_proc <= false }
		assert_raise(ArgumentError) { t1_proc >= false }
	end

	def test_transformer_proc_filter
		assert_equal("2468", (1..9) >= proc{|x| x.to_s if x.even? } >= "")
		assert_equal("2468", (1..9) >= proc{|x| x if x.even? } >= proc{|x| x.to_s} >= "")
		assert_equal("56789", (5..15) >= proc{|x| x.to_s } >= proc{|s| s if s.length == 1 } >= "")
	end

	def test_multiple_args
		assert_equal([[1,2],[3,4]], [[1,2],[3,4]] >= proc{|a,b| [a,b]} >= [])
	end

	def test_symbol_trans
		c = [] <= :to_s
		c << 1 << 4 << 9
		assert_equal(["1","4","9"], c.close)
		c = [] <= :to_s

		t = :upcase <= :to_s
		assert_equal("ABC", "" <= t <= [:a,:b,:c])

		e = :upcase <= ["abc", "def"]
		assert_equal(["ABC", "DEF"], [] <= e)

		t = :to_s >= :upcase
		assert_equal("ABC", [:a,:b,:c] >= t >= "")

		c = :to_s >= []
		c << :a << :b << :c
		assert_equal(["a","b","c"], c.close)
	end
end
