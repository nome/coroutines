require 'coroutines'
require 'test/unit'

class TestCoroutines < Test::Unit::TestCase
	def test_sink
		assert_equal("abcdef", "abc" <= ("d".."f"))
		assert_equal([1,2,3,4], [1] <= [2,3,4])
	end

	def test_source
		assert_equal("abcdef", ("d".."f") >= "abc")
		assert_equal([1,2,3,4], [2,3,4] >= [1])
	end

	def test_consumer
		c = Consumer.new { |y| [ y.await, y.await ] }
		c << :first << :second
		assert_equal([:first, :second], c.close)
	end

	def counter(start)
		result = start
		loop { result += await }
		"Final value: #{result}"
	end
	def test_consumer_method
		c = consum_for :counter, 10
		c << 10 << 1000 << 10000
		assert_equal("Final value: 11020", c.close)
	end

	def test_transformer
		def rs
			Transformer.new do |y|
				result = 0
				loop { result += y.await; y.yield result }
			end
		end
		assert_equal([1, 3, 6], (1..3) >= rs >= [])
		assert_equal([1, 3, 6], [] <= rs <= (1..3))

		def double
			Transformer.new do |y|
				loop do
					x = y.await
					y << x << x
				end
			end
		end
		assert_equal([1,1,2,2], [] <= (double <= [1,2]))
		assert_equal([1,1,2,2], [1,2] >= (double >= []))
		assert_equal([1,2,4,6,9,12], (1..3) >= (double >= rs) >= [])
		assert_equal([1,1,3,3,6,6], (1..3) >= (rs >= double) >= [])
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
	end

	def test_transformer_proc_filter
		assert_equal("2468", (1..9) >= proc{|x| x.to_s if x.even? } >= "")
		assert_equal("2468", (1..9) >= proc{|x| x if x.even? } >= proc{|x| x.to_s} >= "")
		assert_equal("56789", (5..15) >= proc{|x| x.to_s } >= proc{|s| s if s.length == 1 } >= "")
	end

	def test_multiple_args
		assert_equal([[1,2],[3,4]], [[1,2],[3,4]] >= proc{|a,b| [a,b]} >= [])
	end
end
