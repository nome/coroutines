require 'coroutines/base'

#--
# Most of the Sink methods mirror Enumerable, except for <=
# for symmetry, also add a >= method to Enumerable
#++
module Enumerable
	# :call-seq:
	#   enum >= sink  -> obj
	#   enum >= trans -> new_enum
	#
	# In the first form, iterate over +enum+ and write each result to +sink+
	# using <<; then return the result of sink.close.
	#
	# In the second form, create a new Enumerator by connecting +enum+ to the
	# input of +trans+ (which must be convertible to a Transformer using the
	# to_trans method).
	def >=(other)
		if other.respond_to? :<<
			begin
				each { |x| other << x }
			rescue StopIteration
			end
			other.close
		elsif other.respond_to? :to_trans
			other <= self
		end
	end
end

# convenience alias for Sink::Multicast
# (this is not defined when requiring just coroutines/base)
Multicast = Sink::Multicast

class IO
	include Sink
end

class Array
	include Sink
end

class String
	include Sink
end

class Hash
	# :call-seq:
	#   hash << [key, value] -> hash
	#
	# Equivalent to hash[key] = value, but allows chaining:
	#
	#   {} << [1, "one"] << [2, "two"] << [3, "three"]  #=> {1=>"one", 2=>"two", 3=>"three"}
	def <<(args)
		self[args[0]] = args[1]
		self
	end
	include Sink
end

class Method
	# :call-seq:
	#   method << [arg1, arg2, ...] -> method
	#
	# Equivalent to method.call(arg1, arg2, ...), but allows chaining:
	#
	#   method(:puts) << 1 << 2 << 3  # print each number to stdout
	def <<(args)
		call(*args)
		self
	end
	alias_method :close, :receiver
	include Sink
end


class CoroutineError < StandardError
end

# :call-seq:
#   await -> obj
#
# Evaluates to the next input value from the associated consumption context. In
# order to create a consumption context, you have to use Object#consum_for or
# Object#trans_for on the method calling await.
#
# The behavior of await is undefined if the method using it is called without
# being wrapped by consum_for or trans_for. It should be an error to do so, as
# it is an error to use yield without an associated block; however, since await
# is not a language primitive (like yield), it is not always possible to
# enforce this. This is likely to change in a future version if a better
# solution can be found.
def await
	yielder = Fiber.current.instance_variable_get(:@yielder)
	raise CoroutineError, "you can't call a consumer" if yielder.nil?
	yielder.await
end

class Object
	# :call-seq:
	#   consum_for(method, *args) -> consumer
	#
	# Creates a new Consumer coroutine from the given method. This is analogous
	# to using Kernel#enum_for to create an Enumerator instance. The method is
	# called immediately (with the given +args+). It executes until the first
	# call to #await, at which point consum_for returns the Consumer
	# instance. Calling consumer << obj resumes the consumer at the point where
	# it last executed #await, which evaluates to +obj+.
	#
	# Calling consumer.close raises StopIteration at the point where the
	# consumer last executed #await; it is expected that it will
	# terminate without executing #await again. Consumer#close evaluates
	# to the return
	# value of the method.
	#
	# Example:
	#
	#   def counter(start)
	#	 result = start
	#	 loop { result += await }
	#	 "Final value: #{result}"
	#   end
	#
	#   co = consum_for :counter, 10  #=> #<Consumer: main:counter (running)>
	#   co << 10 << 1000 << 10000
	#   co.close  #=> "Final value: 11020"
	#
	def consum_for(meth, *args)
		cons = Consumer.new do |y|
			Fiber.current.instance_variable_set(:@yielder, y)
			send(meth, *args)
		end
		description = "#{inspect}:#{meth}"
		cons.define_singleton_method :inspect do
			state = if @fiber.alive? then "running" else @result.inspect end
			"#<Consumer: #{description} (#{state})>"
		end
		cons
	end

	# :call-seq:
	#   trans_for(method, *args) -> transformer
	#
	# Creates a new Transformer instance that wraps the given method. This is
	# analogous to using Kernel#enum_for to create an Enumerator instance, or
	# using Object#consum_for to create a Consumer instance. The method is not
	# executed immediately. The resulting Transformer can be connected to an
	# enumerable (using transformer <= enum) or to a sink (using
	# transformer >= sink). The point at which the transformer method gets
	# started depends on how it is connected; in any case however, the method
	# will be called with the +args+ given to trans_for. See Transformer
	# for details.
	#
	# Within the transformer method, #await can be used to read the next
	# input value (as in a Consumer, compare Object#consum_for), and yield can
	# be used to produce an output value (i.e., when it is called, the method
	# is given a block which accepts its output).
	#
	# Example:
	#
	#   def running_sum(start)
	#     result = start
	#     loop { result += await; yield result }
	#   end
	#
	#   tr = trans_for :running_sum, 3  #=> #<Transformer: main:running_sum>
	#   sums = (1..10) >= tr  #=> #<Enumerator: #<Transformer: main:running_sum> <= 1..10>
	#   sums.to_a  #=> [4, 6, 9, 13, 18, 24, 31, 39, 48, 58]
	#
	def trans_for(meth, *args)
		trans = Transformer.new do |y|
			Fiber.current.instance_variable_set(:@yielder, y)
			send(meth, *args, &y.method(:yield))
		end
		description ="#{inspect}:#{meth}"
		trans.define_singleton_method :inspect do
			"#<Transformer: #{description}>"
		end
		trans
	end
end

class Symbol
	# :call-seq:
	#   sym.to_trans -> transformer
	#
	# Allows implicit conversion of Symbol to Transformer. The transformer
	# accepts any objects as input, calls the method given by +sym+ on each and
	# outputs all non-nil results of the method. See Proc#to_trans for details.
	#
	# example:
	#
	#   collector = [] <= :to_s
	#   collector << 1 << 4 << 9
	#   collector.close # => ["1", "4", "9"]
	#
	def to_trans
		Transformer.new do |y|
			loop do
				value = y.await.send self
				y.yield value unless value.nil?
			end
		end
	end

	# :call-seq:
	#   sym <= trans  -> new_trans
	#   sym <= enum   -> new_enum
	#
	# Equivalent to sym.to_trans <= trans/enum, except that it uses a more
	# efficient implementation.
	def <=(source)
		to_proc <= source
	end

	# :call-seq:
	#   sym >= trans  -> new_trans
	#   sym >= sink   -> new_consumer
	#
	# Equivalent to sym.to_trans >= trans/sink, except that it uses a more
	# efficient implementation.
	def >=(sink)
		to_proc >= sink
	end
end

# Define a poor man's Enumerator::Lazy for Ruby < 2.0
if defined? Enumerator::Lazy
	LazyEnumerator = Enumerator::Lazy
else
	class LazyEnumerator
		def initialize(obj, &block)
			@obj = obj; @block = block
		end

		class Yielder
			def initialize(iter_block)
				@iter_block = iter_block
			end
			def yield(*values)
				@iter_block.call(*values)
			end
			alias_method :<<, :yield
		end

		def each(&iter_block)
			yielder = Yielder.new(iter_block)
			@obj.each do |*args|
				@block.call(yielder, *args)
			end
		end
		include Enumerable
	end
end

class Proc
	# :call-seq:
	#   proc.to_trans -> transformer
	#
	# Allows implicit conversion of Proc to Transformer. The transformer is a
	# combination of map and filter over its input values: For each input
	# value, +proc+ is called with the input value as parameter. Every non-nil
	# value returned by +proc+ is yielded as an output value.
	#
	# This is similar to Enumerable#map followed by Array#compact, but without
	# constructing the intermediate Array (so it's even more similar to
	# something like enum.lazy.map(&proc).reject(&:nil?), using the lazy
	# enumerator introduced in Ruby 2.0).
	#
	# Example:
	#
	#   (1..10) >= proc{|x| x.to_s + ", " if x.even? } >= ""
	#   # => "2, 4, 6, 8, 10, "
	#
	def to_trans
		Transformer.new do |y|
			loop do
				value = self.call(y.await)
				y.yield value unless value.nil?
			end
		end
	end

	# :call-seq:
	#   proc <= trans  -> new_trans
	#   proc <= enum   -> new_enum
	#
	# Equivalent to proc.to_trans <= trans/enum, except that it uses a more
	# efficient implementation.
	def <=(source)
		if source.respond_to? :each
			LazyEnumerator.new(source) do |y, *args|
				value = call(*args)
				y << value unless value.nil?
			end
		elsif source.respond_to? :to_proc
			sp = source.to_proc
			proc do |*args|
				value = sp.call(*args)
				if value.nil? then nil else self.call value end
			end
		elsif source.respond_to? :to_trans
			# FIXME: this could be implemented more efficiently; proc doesn't
			#        need to run in a separate Fiber
			self.to_trans <= source.to_trans
		else
			raise ArgumentError, "#{source.inspect} is neither an enumerable nor a transformer"
		end
	end

	# :call-seq:
	#   proc >= trans  -> new_trans
	#   proc >= sink   -> new_consumer
	#
	# Equivalent to proc.to_trans >= trans/sink, except that it uses a more
	# efficient implementation.
	def >=(sink)
		if sink.respond_to? :input_map
			sink.input_reject(&:nil?).input_map(&self)
		elsif sink.respond_to? :to_proc
			sp = sink.to_proc
			proc do |*args|
				value = self.call(*args)
				if value.nil? then nil else sp.call value end
			end
		elsif sink.respond_to? :to_trans
			# FIXME: this could be implemented more efficiently; proc doesn't
			#        need to run in a separate Fiber
			self.to_trans >= sink.to_trans
		else
			raise ArgumentError, "#{sink.inspect} is neither a sink nor a transformer"
		end
	end
end
