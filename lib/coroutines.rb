require 'coroutines/base'
require 'coroutines/operators' # deprecated

#--
# Most of the Sink methods mirror Enumerable, except for #in_connect
# for symmetry, also add an #out_connect method to Enumerable
#++
module Enumerable
	# :call-seq:
	#   enum.out_connect(sink)  -> obj
	#   enum.out_connect(trans) -> new_enum
	#
	# In the first form, iterate over +enum+ and write each result to +sink+
	# using <<; then return the result of sink.close.
	#
	# In the second form, create a new Enumerator by connecting the output of
	# +enum+ to the input of +trans+ (which must be convertible to a
	# Transformer using the to_trans method).
	def out_connect(other)
		if other.respond_to? :<<
			begin
				each { |x| other << x }
			rescue StopIteration
			end
			other.close
		elsif other.respond_to? :to_trans
			other.to_trans.in_connect(self)
		end
	end

	# :call-seq:
	#   enum.filter_map {|obj| block }  -> array
	#
	# For each +obj+ in in +enum+, calls +block+, and collects its non-nil
	# return values into a new +array+.
	#--
	# taken from the API doc of Enumerator::Lazy.new
	def filter_map(&block)
		map(&block).compact
	end
end

class Enumerator::Lazy
	# :call-seq:
	#   enum.filter_map {|obj| block }  -> an_enumerator
	#
	# Returns a new lazy Enumerator which iterates over all non-nil values
	# returned by +block+ while +obj+ iterates over +enum+.
	#--
	# taken from the API doc of Enumerator::Lazy.new
	def filter_map
		Enumerator.new do |yielder|
			each do |*values|
				result = yield *values
				yielder << result if result
			end
		end.lazy
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
	# enumerable (using transformer.in_connect(enum)) or to a sink (using
	# transformer.out_connect(sink)). The point at which the transformer method
	# gets started depends on how it is connected; in any case however, the
	# method will be called with the +args+ given to trans_for. See Transformer
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
	#   sums = (1..10).out_connect(tr)  #=> #<Enumerator: #<Transformer: main:running_sum> <= 1..10>
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

