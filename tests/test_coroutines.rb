require 'coroutines'
require 'test/unit'

class TestCoroutines < Test::Unit::TestCase
	def test_consumer
		c = Consumer.new { |y| [ y.await, y.await ] }
		c << :first << :second
		assert_equal([:first, :second], c.close)
		assert_equal([:first, :second], c.result)
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
		assert_equal([1, 3, 6], (1..3).out_connect(rs).out_connect([]))
		assert_equal([1, 3, 6], [].in_connect(rs).in_connect(1..3))

		def double
			Transformer.new do |y|
				loop do
					x = y.await
					y << x << x
				end
			end
		end
		assert_equal([1,1,2,2], [].in_connect(double.in_connect [1,2]))
		assert_equal([1,1,2,2], [1,2].out_connect(double.out_connect []))
		assert_equal([1,2,4,6,9,12], (1..3).out_connect(double.out_connect rs).out_connect([]))
		assert_equal([1,1,3,3,6,6], (1..3).out_connect(rs.out_connect double).out_connect([]))
	end

	def test_transformer_chaining
		t1 = Transformer.new{|y| y.yield (y.await + "a")}
		t2 = Transformer.new{|y| y.yield (y.await + "b")}
		t = t1.out_connect(t2)
		result = %w{x y z}.out_connect(t).out_connect([])
		assert_equal(["xab"], result)

		t1 = Transformer.new{|y| y.yield (y.await + "a")}
		t2 = Transformer.new{|y| y.yield (y.await + "b")}
		t = t2.in_connect(t1)
		result = %w{x y z}.out_connect(t).out_connect([])
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

		assert_equal("1,2,3,", s.out_connect(t1).out_connect(t2).out_connect(""))
		assert_equal("1,2,3,", s.out_connect(t1).out_connect(t2.out_connect("")))
		assert_equal("1,2,3,", s.out_connect(t1.out_connect(t2).out_connect("")))
		assert_equal("1,2,3,", s.out_connect(t1.out_connect t2).out_connect(""))
		assert_equal("1,2,3,", s.out_connect(t1.out_connect(t2).out_connect("")))

		assert_equal("1,2,3,", "".in_connect(t2).in_connect(t1).in_connect(s))
		assert_equal("1,2,3,", "".in_connect(t2).in_connect((t1.in_connect s)))
		assert_equal("1,2,3,", "".in_connect(t2.in_connect(t1).in_connect(s)))
		assert_equal("1,2,3,", "".in_connect(t2.in_connect t1).in_connect(s))
		assert_equal("1,2,3,", "".in_connect(t2.in_connect(t1).in_connect(s)))
	end

	def running_sum(start)
		result = start
		loop { result += await; yield result }
	end
	def test_transformer_method
		assert_equal([4, 6, 9], (1..3).out_connect(trans_for(:running_sum, 3)).out_connect([]))
		assert_equal([4, 6, 9], (1..3).out_connect(trans_for(:running_sum, 3).out_connect([])))
	end

	def limit_three
		Transformer.new do |y|
			3.times { y.yield y.await }
		end
	end

	def test_stop_iteration
		consume_three = Consumer.new do |y|
			[y.await, y.await, y.await]
		end
		assert_equal([1,2,3], (1..Float::INFINITY).out_connect(consume_three))

		assert_equal([1,2,3], (1..Float::INFINITY).out_connect(limit_three).out_connect([]))
	end

	def test_transformer_lazy
		def t_s
			Transformer.new {|y| loop { y << y.await.to_s } }.lazy
		end
		assert_equal(3, limit_three.lazy.count.in_connect(1..Float::INFINITY))
		assert_equal("456", t_s.drop(3).in_connect(1..6).out_connect(""))
		assert_equal("1011", t_s.drop_while{|s| s.size < 2}.in_connect(1..11).out_connect(""))

		result = ""
		t_s.each{|x| result += x}.in_connect(2..6)
		assert_equal("23456", result)

		assert_equal("2:3:4:", t_s.filter_map{|s| s+":" if s.size < 2}.in_connect([2,12,3,44,56,4]).out_connect(""))
		assert_equal("2:3:4:", t_s.flat_map{|s| [s,":"] }.in_connect([2,3,4]).out_connect(""))
		assert_equal("2:3:4:", t_s.map{|s| s+":" }.in_connect([2,3,4]).out_connect(""))
		assert_equal("234", t_s.out_connect("").in_connect([2,3,4]))
		assert_equal("234", t_s.reduce(:+).in_connect(2..4))
		assert_equal("abc234", t_s.reduce("abc", :+).in_connect(2..4))
		assert_equal("234", t_s.reject{|s| s.size >= 2}.in_connect([2,12,3,44,56,4]).out_connect(""))
		assert_equal("234", t_s.select{|s| s.size < 2}.in_connect([2,12,3,44,56,4]).out_connect(""))
		assert_equal("12345", t_s.take(5).in_connect(1..Float::INFINITY).out_connect(""))
		assert_equal("123456789", t_s.take_while{|s| s.size < 2}.in_connect(1..Float::INFINITY).out_connect(""))
		assert_equal(["1","2","3","4","5"], t_s.sort.in_connect([5,2,4,3,1]))
		assert_equal(["c1", "a2", "b3"], t_s.sort_by{|s| s[1] }.in_connect(["a2", "b3", "c1"]))
		assert_equal(["1","2","3"], t_s.to_a.in_connect(1..3))
		assert_equal({a: 1, b: 2}, Transformer.new{|y| y << [:a,1] << [:b,2]}.lazy.to_h.in_connect([]))
	end
end
